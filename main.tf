resource azurerm_network_security_group NSG {
  name                = "${var.name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  dynamic "security_rule" {
    for_each = [for s in var.security_rules : {
      name                       = s.name
      priority                   = s.priority
      direction                  = s.direction
      access                     = s.access
      protocol                   = s.protocol
      source_port_ranges         = split(",", replace(s.source_port_ranges, "*", "0-65535"))
      destination_port_ranges    = split(",", replace(s.destination_port_ranges, "*", "0-65535"))
      source_address_prefix      = s.source_address_prefix
      destination_address_prefix = s.destination_address_prefix
      description                = s.description
    }]
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_ranges         = security_rule.value.source_port_ranges
      destination_port_ranges    = security_rule.value.destination_port_ranges
      source_address_prefix      = security_rule.value.source_address_prefix
      destination_address_prefix = security_rule.value.destination_address_prefix
      description                = security_rule.value.description
    }
  }
  tags = var.tags
}

resource "azurerm_storage_account" "boot_diagnostic" {
  count                    = var.boot_diagnostic ? 1 : 0
  name                     = local.storageName
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# If public_ip is true then create resource. If not then do not create any
resource azurerm_public_ip VM-EXT-PubIP {
  count               = var.public_ip ? length(var.nic_ip_configuration.private_ip_address_allocation) : 0
  name                = "${var.name}-pip${count.index + 1}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  allocation_method   = "Static"
  tags                = var.tags
}

resource azurerm_network_interface NIC {
  name                          = "${var.name}-nic1"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  enable_ip_forwarding          = var.nic_enable_ip_forwarding
  enable_accelerated_networking = var.nic_enable_accelerated_networking
  dns_servers                   = var.dnsServers
  dynamic "ip_configuration" {
    for_each = var.nic_ip_configuration.private_ip_address_allocation
    content {
      name                          = "ipconfig${ip_configuration.key + 1}"
      subnet_id                     = data.azurerm_subnet.subnet.id
      private_ip_address            = var.nic_ip_configuration.private_ip_address[ip_configuration.key]
      private_ip_address_allocation = var.nic_ip_configuration.private_ip_address_allocation[ip_configuration.key]
      public_ip_address_id          = var.public_ip ? azurerm_public_ip.VM-EXT-PubIP[ip_configuration.key].id : ""
      primary                       = ip_configuration.key == 0 ? true : false
    }
  }
  tags = var.tags
}

resource azurerm_network_interface_security_group_association nic-nsg {
  network_interface_id      = azurerm_network_interface.NIC.id
  network_security_group_id = azurerm_network_security_group.NSG.id
}

resource azurerm_windows_virtual_machine VM {
  name                             = var.name
  depends_on                       = [var.vm_depends_on]
  location                         = var.location
  resource_group_name              = var.resource_group_name
  size                             = var.vm_size #renamed from vm_size
  network_interface_ids            = [azurerm_network_interface.NIC.id]
  #primary_network_interface_id    = removed, now just the first NIC above
  availability_set_id              = var.availability_set_id
  #delete_data_disks_on_termination = "true" #removed as there is no way to add data disks directly
  #delete_os_disk_on_termination    = "true" #moved to provider settings - defaults to true
  license_type                     = var.license_type == null ? null : var.license_type
  computer_name                    = var.name #moved out of os_profile
  admin_username                   = var.admin_username #moved out of os_profile
  admin_password                   = var.admin_password #moved out of os_profile
  custom_data                      = var.custom_data #moved out of os_profile
  provision_vm_agent               = true #move out of os_profile_windows_config

  source_image_reference {
    publisher = var.storage_image_reference.publisher
    offer     = var.storage_image_reference.offer
    sku       = var.storage_image_reference.sku
    version   = var.storage_image_reference.version
  }
  dynamic "plan" {
    for_each = local.plan
    content {
      name      = local.plan[0].name
      product   = local.plan[0].product
      publisher = local.plan[0].publisher
    }
  }

  #storage_os_disk is changed to os_disk but some options are different
  #this resource is now always a managed disk
  os_disk {
    name              = "${var.name}-osdisk1"
    caching           = var.os_disk.caching
    storage_account_type = var.os_disk.storage_account_type #var should be renamed
    disk_size_gb      = var.os_disk.disk_size_gb
  }
  /*storage_os_disk #did not find a replace settings for these {
    create_option     = var.storage_os_disk.create_option #removed, possible braking change
    os_type           = var.storage_os_disk.os_type #removed, redundent
  }*/

  dynamic "boot_diagnostics" {
    for_each = local.boot_diagnostic
    content {
      #enabled     = true #removed
      storage_account_uri = azurerm_storage_account.boot_diagnostic[0].primary_blob_endpoint
    }
  }
  dynamic "identity" {
    for_each = local.assign-identity
    content {
      type = "SystemAssigned"
    }
  }
  tags = var.tags
}

# This is where the magic to dynamically create storage disk operate
# *** completly changes with windows_virtual_machine:
# *** is now in 2 seperate resources ***

resource azurerm_managed_disk DataDisk {
  count                 = length(var.data_disk_sizes_gb)

  name                  = "${var.name}-datadisk${count.index + 1}"
  location              = var.location
  resource_group_name   = var.resource_group_name
  storage_account_type  = var.data_managed_disk_type
  disk_size_gb          = var.data_disk_sizes_gb[count.index]
  create_option         = "Empty"
}

resource azurerm_virtual_machine_data_disk_attachment attached_data_disk {
  count               = length(var.data_disk_sizes_gb)

  managed_disk_id     = azurerm_managed_disk.DataDisk[count.index].id
  virtual_machine_id  = azurerm_windows_virtual_machine.VM.id
  lun                 = count.index + 1 
  caching             = "ReadWrite"
}
