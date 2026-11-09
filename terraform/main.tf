terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.11"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# Subscription and tenant are pinned explicitly (set in terraform.tfvars). The
# az CLI default may be a different account, so never rely on it.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Reads EC_API_KEY from the environment.
provider "ec" {}

# Used only to look up the "Azure Security Insights" service principal that Sentinel
# automation rules run playbooks as.
provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# The elasticstack provider is configured from the ec_deployment attributes, so
# its values are unknown until the deployment exists (resolved at apply time).
# The Fleet API is served by Kibana, so the fleet block is not needed.
provider "elasticstack" {
  elasticsearch {
    endpoints = [ec_deployment.main.elasticsearch.https_endpoint]
    username  = ec_deployment.main.elasticsearch_username
    password  = ec_deployment.main.elasticsearch_password
  }
  kibana {
    endpoints = [ec_deployment.main.kibana.https_endpoint]
    username  = ec_deployment.main.elasticsearch_username
    password  = ec_deployment.main.elasticsearch_password
  }
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result
  # Organisation-mandated tags (var.tags) plus ManagedBy. Applied explicitly to every
  # taggable resource because azurerm has no provider-level default_tags.
  tags = merge(var.tags, {
    ManagedBy = "terraform"
  })
}
