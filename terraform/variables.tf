variable "subscription_id" {
  description = "Azure subscription ID to deploy into"
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID of the subscription"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "elastic-sentinel"
}

variable "vm_size" {
  description = "VM size for the Elastic Agent / syslog host (Standard_B2s has no capacity in eastus)"
  type        = string
  default     = "Standard_B2als_v2"
}

variable "elastic_region" {
  description = "Elastic Cloud region (Azure). Check the list in the Elastic Cloud console."
  type        = string
  default     = "azure-eastus2"
}

variable "elastic_deployment_template_id" {
  description = "Elastic Cloud deployment template id. Verify with: GET /api/v1/deployments/templates?region=<elastic_region>"
  type        = string
  default     = "azure-general-purpose"
}

variable "elastic_stack_version_regex" {
  description = "ec_stack version_regex. 'latest' resolves the newest stack version available in the region."
  type        = string
  default     = "latest"
}

variable "vm_encryption_at_host" {
  description = "Enable encryption at host on the VM. Requires: az feature register --namespace Microsoft.Compute --name EncryptionAtHost, then re-register Microsoft.Compute. Set false to fall back to platform-managed disk encryption only."
  type        = bool
  default     = true
}

variable "vm_admin_username" {
  description = "Admin user on the VM"
  type        = string
  default     = "azureuser"
}

variable "event_hub_sku" {
  description = "Event Hubs namespace SKU. Log Analytics data export does not support Basic, so Standard is the cheapest usable tier."
  type        = string
  default     = "Standard"
}

variable "log_analytics_retention_days" {
  description = "Log Analytics workspace retention in days"
  type        = number
  default     = 30
}

variable "export_table_names" {
  description = "Log Analytics tables exported to Event Hubs (must be supported by data export)"
  type        = list(string)
  default     = ["Syslog", "SecurityAlert", "SecurityIncident"]
}

variable "fleet_system_package_version" {
  description = "Fleet System integration package version (check https://epr.elastic.co/search?package=system&kibana.version=<stack>)"
  type        = string
  default     = "3.5.0"
}

variable "fleet_azure_package_version" {
  description = "Fleet Azure Logs integration package version"
  type        = string
  default     = "1.40.3"
}

variable "tags" {
  description = "Organisation-mandated tags applied to all taggable resources (division, org, keep-until, team, project)"
  type        = map(string)
  default     = {}
}

variable "kibana_size" {
  description = "Kibana memory size. 1g runs out of heap on the Cases page and restarts (503 errors); 2g is stable."
  type        = string
  default     = "2g"
}
