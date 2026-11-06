data "ec_stack" "latest" {
  version_regex = var.elastic_stack_version_regex
  region        = var.elastic_region
}

resource "ec_deployment" "main" {
  name                   = "${var.prefix}-${local.suffix}"
  region                 = var.elastic_region
  version                = data.ec_stack.latest.version
  deployment_template_id = var.elastic_deployment_template_id
  tags                   = local.tags

  elasticsearch = {
    hot = {
      size        = "1g"
      zone_count  = 1
      autoscaling = {}
    }
  }

  kibana = {
    size       = var.kibana_size
    zone_count = 1
  }

  integrations_server = {
    size       = "1g"
    zone_count = 1
  }
}
