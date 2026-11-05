resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Written outside terraform/ and matched by the *.pem gitignore pattern.
resource "local_sensitive_file" "vm_private_key" {
  content              = tls_private_key.vm.private_key_pem
  filename             = "${path.module}/../.ssh/sentinel-demo.pem"
  file_permission      = "0600"
  directory_permission = "0700"
}

locals {
  elastic_version = data.ec_stack.latest.version
  fleet_url       = ec_deployment.main.integrations_server.endpoints.fleet
  enrollment_token = one([
    for t in data.elasticstack_fleet_enrollment_tokens.vm.tokens : t.api_key if t.active
  ])
}

resource "azurerm_linux_virtual_machine" "main" {
  #checkov:skip=CKV_AZURE_50:Azure Monitor Agent extension is required for Syslog collection
  name                = "${var.prefix}-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.vm_admin_username
  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]
  tags = local.tags

  # Spot: cheap, may be evicted (deallocated, disk kept).
  priority        = "Spot"
  eviction_policy = "Deallocate"
  max_bid_price   = -1

  disable_password_authentication = true
  encryption_at_host_enabled      = var.vm_encryption_at_host

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = tls_private_key.vm.public_key_openssh
  }

  # Needed by the Azure Monitor Agent to authenticate to the DCR.
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Must stay well under 16KB.
  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    elastic_version  = local.elastic_version
    fleet_url        = local.fleet_url
    enrollment_token = local.enrollment_token
  }))
}

resource "azurerm_virtual_machine_extension" "ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.main.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = local.tags
}
