provider "azurerm" {
  features {}
}

resource "random_string" "random" {
  length = 4
  special = false
  min_lower = 4
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = "West US 2"
}

resource "azurerm_virtual_network" "vnet" {
    name                = "${var.prefix}-vnet"
    address_space       = [ var.network-address-space ]
    location            = azurerm_resource_group.main.location
    resource_group_name = azurerm_resource_group.main.name
}

# create subnets
resource "azurerm_subnet" "subnet" {
  for_each = var.subnets
  name = each.key
  address_prefixes = [ lookup(var.subnets[each.key],"cidr") ]
  resource_group_name = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  enforce_private_link_endpoint_network_policies = lookup(var.subnets[each.key],"enforce-private-link-endpoint-policies")
}

# create nsgs
resource "azurerm_network_security_group" "network_security_groups" {
  for_each = var.subnets
  name = each.key
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

#
# route all traffic to keyvault and storage account endpoints through azure firewall, 
# route all Internet bound traffic through azure firewall
#

resource "azurerm_route_table" "route-table" {
  name                = "${var.prefix}-route-table"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_route" "keyvault-route" {
  name = "keyvault-route"
  resource_group_name = azurerm_resource_group.main.name
  route_table_name = azurerm_route_table.route-table.name
  address_prefix = lookup(var.subnets["keyvault-endpoint"],"cidr")
  next_hop_type = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.firewall.ip_configuration[0].private_ip_address
}

resource "azurerm_route" "storage-account-route" {
  name = "storag-account-route"
  resource_group_name = azurerm_resource_group.main.name
  route_table_name = azurerm_route_table.route-table.name
  address_prefix = lookup(var.subnets["storageaccount-endpoint"],"cidr")
  next_hop_type = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.firewall.ip_configuration[0].private_ip_address
}

resource "azurerm_route" "default-route" {
  name = "default"
  resource_group_name = azurerm_resource_group.main.name
  route_table_name = azurerm_route_table.route-table.name
  address_prefix = "0.0.0.0/0"
  next_hop_type = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.firewall.ip_configuration[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "subnet-rt-associations" {
  for_each = var.subnets
  subnet_id = azurerm_subnet.subnet[each.key].id
  route_table_id = azurerm_route_table.route-table.id
}


# create an association of each nsg to each subnet, using the key names in the subnets variable map 
resource "azurerm_subnet_network_security_group_association" "nsg_associations" {
  for_each = var.subnets 
  subnet_id = azurerm_subnet.subnet[ each.key ].id
  network_security_group_id = azurerm_network_security_group.network_security_groups[ each.key ].id
}

# create public IP addresses
resource "azurerm_public_ip" "publicIPaddresses" {
  for_each = var.public_ips
  name                = "${var.prefix}-${each.key}-publicIP"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = each.value
}

# we need a special subnet for azure firewall - must be named AzureFirewallSubnet
resource "azurerm_subnet" "firewall_subnet" {
  name = "AzureFirewallSubnet"
  address_prefixes = [ var.AzureFirewallSubnet ]    
  resource_group_name = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
}

resource "azurerm_firewall" "firewall" {
  name = "${var.prefix}-firewall"
  resource_group_name = azurerm_resource_group.main.name
  location = azurerm_resource_group.main.location
  ip_configuration {
    name = "${var.prefix}-firewall-config"
    subnet_id = azurerm_subnet.firewall_subnet.id
    public_ip_address_id = azurerm_public_ip.publicIPaddresses["firewall"].id
  }
}

# we need to create some network rules for the firewall to be allow traffic to pass. 
# here, we allow HTTP & HTTPS from our vnet address space to anywhere.

resource "azurerm_firewall_network_rule_collection" "firewall-default-rule-collection" {
  name = "azure-firewall-default-rule-collection"
  azure_firewall_name = azurerm_firewall.firewall.name
  resource_group_name = azurerm_resource_group.main.name
  priority = 100
  action = "Allow"

  rule {
    name = "internal"   
    source_addresses = [ var.network-address-space ]    
    destination_ports = ["443", "80"]
    destination_addresses = [ var.network-address-space ]
    protocols = ["TCP"]
  }
  rule {
    name = "anywhere"
    source_addresses = [ var.network-address-space ]    
    destination_ports = ["443", "80"]
    destination_addresses = [ "*" ]
    protocols = ["TCP","UDP"]
  }
}

# create a storage account
resource "azurerm_storage_account" "storageaccount" {
  name =  "${var.prefix}${random_string.random.result}stgacct"
  resource_group_name = azurerm_resource_group.main.name
  location = azurerm_resource_group.main.location
  account_tier = "Standard"
  account_kind = "StorageV2"
  account_replication_type = "LRS"
  enable_https_traffic_only = true
  network_rules {
    default_action             = "Deny"
  }
}

# get the current azurerm provider configuration so we can use the current tenant id
data "azurerm_client_config" "current" {}

# create a keyvault resource
resource "azurerm_key_vault" "keyvault" {
  name =  "${var.prefix}${random_string.random.result}keyvault"
  resource_group_name = azurerm_resource_group.main.name
  location = azurerm_resource_group.main.location
  enabled_for_disk_encryption = true
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name = "standard"
  tenant_id = data.azurerm_client_config.current.tenant_id

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = azurerm_user_assigned_identity.vm_identity.principal_id // data.azurerm_client_config.current.object_id

    key_permissions = [
      "get",
    ]

    secret_permissions = [
      "get",
    ]

    storage_permissions = [
      "get",
    ]
  }
}

###### Private Endpoints

# storage account private endpoint and private dns resources

resource "azurerm_private_dns_zone" "storage_dns_zone" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_endpoint" "storage_endpoint" {
  name                = "${var.prefix}-storage-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.subnet["storageaccount-endpoint"].id

  private_service_connection {
    name                           = "storage-privateserviceconnection"
    private_connection_resource_id = azurerm_storage_account.storageaccount.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }
  
  private_dns_zone_group {
    name              = "${var.prefix}-storageaccount-endpoint-dns"
    private_dns_zone_ids = [ azurerm_private_dns_zone.storage_dns_zone.id ]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_account" {
  name                  = "storage_dns_zone_link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_dns_zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# keyvault private endpoint and private dns resources

resource "azurerm_private_dns_zone" "keyvault_dns_zone" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_endpoint" "keyvault_endpoint" {
  name                = "${var.prefix}-keyvault-endpoint"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.subnet["keyvault-endpoint"].id

  private_service_connection {
    name                           = "keyvault-privateserviceconnection"
    private_connection_resource_id = azurerm_key_vault.keyvault.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name              = "${var.prefix}-keyvault-endpoint-dns"
    private_dns_zone_ids = [ azurerm_private_dns_zone.keyvault_dns_zone.id ]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  name                  = "keyvault_dns_zone_link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault_dns_zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}


resource "azurerm_network_interface" "vnic" {
    name                      = "vnic1"
    location            = azurerm_resource_group.main.location
    resource_group_name = azurerm_resource_group.main.name

    ip_configuration {
        name                          = "myNicConfiguration"
        subnet_id                     = azurerm_subnet.subnet["virtual-machines"].id
        private_ip_address_allocation = "Dynamic"
    }
}

resource "tls_private_key" "example_ssh" {
  algorithm = "RSA"
  rsa_bits = 4096
}
output "tls_private_key" { value = tls_private_key.example_ssh.private_key_pem }

resource "azurerm_linux_virtual_machine" "vm" {
    name                  = "vm01"
    location            = azurerm_resource_group.main.location
    resource_group_name = azurerm_resource_group.main.name
    network_interface_ids = [azurerm_network_interface.vnic.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "os_disk"
        caching           = "ReadWrite" 
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = var.OS.publisher
        offer     = var.OS.offer 
        sku       = var.OS.sku 
        version   = var.OS.version
    }

    computer_name  = "vm01"
    admin_username = "azureuser"
    disable_password_authentication = true

    admin_ssh_key {
        username       = "azureuser"
        public_key     = tls_private_key.example_ssh.public_key_openssh
    }

    identity {
      type = "UserAssigned"
      identity_ids = [ azurerm_user_assigned_identity.vm_identity.id ]
    }


}

data "azurerm_subscription" "current" {}

data "azurerm_role_definition" "storage_blob_data_contributor" {
  name = "Storage Blob Data Contributor"
}

data "azurerm_role_definition" "reader" {
  name = "Reader"
}

resource "azurerm_user_assigned_identity" "vm_identity" {
  name                = "${var.prefix}-vm-user-identity"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_role_assignment" "storage_blob_data_contributor_assignment" {
  scope              = azurerm_storage_account.storageaccount.id
  role_definition_id = data.azurerm_role_definition.storage_blob_data_contributor.role_definition_id
  principal_id       = azurerm_user_assigned_identity.vm_identity.principal_id
}

resource "azurerm_role_assignment" "storage_reader_assignment" {
  scope              = azurerm_storage_account.storageaccount.id
  role_definition_id = data.azurerm_role_definition.reader.role_definition_id
  principal_id       = azurerm_user_assigned_identity.vm_identity.principal_id
}

resource "azurerm_role_assignment" "keyvault_reader_assignment" {
  scope              = azurerm_key_vault.keyvault.id
  role_definition_id = data.azurerm_role_definition.reader.role_definition_id
  principal_id       = azurerm_user_assigned_identity.vm_identity.principal_id
}

# let's use a bastion service to gain safe ssh access to our VM

resource "azurerm_subnet" "bastion_subnet" {
  name = "AzureBastionSubnet"
  address_prefixes = [ var.AzureBastionSubnet ]    
  resource_group_name = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
}

resource "azurerm_bastion_host" "bastion" {
  name = "bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name = "bastion_config"
    subnet_id = azurerm_subnet.bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.publicIPaddresses["bastion"].id
  }
}