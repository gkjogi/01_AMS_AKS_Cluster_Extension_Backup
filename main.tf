# --- Providers ---
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    #aws = {}
    #gcp = {}
    #oci = {}
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

# --- Variables ---
variable "resource_group_name" { default = "rg-aks-backup-prod" }
variable "location"            { default = "East US" }
variable "cluster_name"        { default = "aks-cluster-main" }
variable "storage_account_name"{ default = "staksbackupprod001" }

# --- Infrastructure ---
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "backups" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "backups" {
  name                  = "aks-backups"
  storage_account_name  = azurerm_storage_account.backups.name
  container_access_type = "private"
}

# --- AKS Cluster ---
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-backup-dns"

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_D2s_v3"
  }

  identity { type = "SystemAssigned" }
}

# --- Backup Vault & Policy ---
resource "azurerm_data_protection_backup_vault" "vault" {
  name                = "aks-backup-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  datastore_type      = "VaultStore"
  redundancy          = "LocallyRedundant"
  identity { type = "SystemAssigned" }
}

resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "policy" {
  name                = "aks-backup-policy"
  resource_group_name = azurerm_resource_group.main.name
  vault_name          = azurerm_data_protection_backup_vault.vault.name

  backup_repeating_time_intervals = ["R/2024-01-01T02:00:00+00:00/PT4H"]
  default_retention_rule {
    life_cycle {
      duration        = "P14D"
      data_store_type = "OperationalStore"
    }
  }

   retention_rule {
    name     = "Daily"
    priority = 25
    life_cycle {
      duration        = "P30D"
      data_store_type = "OperationalStore"
    }
    criteria {
      absolute_criteria = "FirstOfDay"
    }
  }
}


# --- Extension & Integration ---
resource "azurerm_kubernetes_cluster_extension" "aks_backup" {
  name           = "azure-aks-backupextension"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "Microsoft.DataProtection.Kubernetes"

  configuration_settings = {
    "configuration.backupStorageLocation.bucket"                = azurerm_storage_container.backups.name
    "configuration.backupStorageLocation.config.resourceGroup"  = azurerm_resource_group.main.name
    "configuration.backupStorageLocation.config.storageAccount" = azurerm_storage_account.backups.name
    "configuration.backupStorageLocation.config.subscriptionId" = data.azurerm_subscription.current.subscription_id
    "configuration.backupStorageLocation.config.tenantId"       = data.azurerm_subscription.current.tenant_id
    "credentials.tenantId"                                      = data.azurerm_subscription.current.tenant_id
    "credentials.subscriptionId"                                = data.azurerm_subscription.current.subscription_id
  }
}

resource "azurerm_kubernetes_cluster_trusted_access_role_binding" "aks_backup_binding" {
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  #name                  = "aks-backup-trusted-access"  # Error - 25 characters 
  name                  = "aks-backup-binding" 
  roles                 = ["Microsoft.DataProtection/backupVaults/backup-operator"]
  source_resource_id    = azurerm_data_protection_backup_vault.vault.id
}

resource "azurerm_role_assignment" "vault_storage_access" {
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  #principal_id         = azurerm_data_protection_backup_vault.vault.identity.principal_id
  principal_id         = azurerm_data_protection_backup_vault.vault.identity[0].principal_id
}

# --- Backup Instance (The link that enables the backup) ---
resource "azurerm_data_protection_backup_instance_kubernetes_cluster" "main" {
  name                         = "aks-backup-instance"
  location                     = azurerm_resource_group.main.location
  vault_id                     = azurerm_data_protection_backup_vault.vault.id
  kubernetes_cluster_id        = azurerm_kubernetes_cluster.main.id
  backup_policy_id             = azurerm_data_protection_backup_policy_kubernetes_cluster.policy.id
  snapshot_resource_group_name = "${var.resource_group_name}-snapshots"

  backup_datasource_parameters {
    #include_cluster_scope_resources = true
    cluster_scoped_resources_enabled = true
    # Ensure volume snapshots are enabled if you have PVCs
    volume_snapshot_enabled          = true
    
    # Use specific namespaces or leave empty to include all
    # Note: Terraform does not currently support "*" for all namespaces here
    included_namespaces              = ["default"]
  }

  depends_on = [
    azurerm_kubernetes_cluster_extension.aks_backup,
    azurerm_kubernetes_cluster_trusted_access_role_binding.aks_backup_binding,
    azurerm_role_assignment.vault_storage_access
  ]
}

# --- Outputs ---
output "kube_config" {
  value     = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive = true
}


# 1. Get the current Terraform Service Principal configuration
data "azurerm_client_config" "current" {}

# 2. Get the current subscription details
data "azurerm_subscription" "primary" {}

# 3. Create the Custom Role (Least Privilege)
resource "azurerm_role_definition" "terraform_rbac_admin" {
  name        = "Terraform-RBAC-Administrator"  #Terraform-Contributor
  scope       = data.azurerm_subscription.primary.id
  description = "Grants Terraform the ability to assign RBAC roles."

  permissions {
    actions = ["Microsoft.Authorization/roleAssignments/write"]
  }

  assignable_scopes = [data.azurerm_subscription.primary.id]
}


# 4. Assign the Custom Role to the Terraform Service Principal itself
#resource "azurerm_role_assignment" "terraform_self_assignment" {
#  scope              = data.azurerm_subscription.primary.id
#  role_definition_id = azurerm_role_definition.terraform_rbac_admin.role_definition_resource_id
#  principal_id       = data.azurerm_client_config.current.object_id
#}


#Assign Reader role to the managed identity of the Backup Vault on the Kubernetes cluster.
# Assign Reader role to the Backup Vault's Managed Identity on the AKS Cluster scope
#resource "azurerm_role_assignment" "vault_msi_read_on_cluster" {
#  scope                = azurerm_kubernetes_cluster.aks.id
#  role_definition_name = "Reader"
#  principal_id         = azurerm_data_protection_backup_vault.velero_vault.identity[0].principal_id
  
  # Recommended to avoid AAD replication lag issues
#  skip_service_principal_aad_check = true
#}
