#prefix to be used in naming for uniqueness (only lowercase numbers and letters)
variable "prefix" {
  default = "fam"
}

#VM image
variable "OS" {
  type = map
  default = {
        publisher = "RedHat"
        offer     = "RHEL"
        sku       = "8_3"
        version   = "8.3.2020111905"
  }
}

# network address space for the vnet
variable "network-address-space" {
    default = "10.0.0.0/16"
}

# subnets for Firewall and Bastion
variable "AzureFirewallSubnet" {
        default = "10.0.254.0/26"
}

variable "AzureBastionSubnet" {
        default = "10.0.254.64/26"
}

# all other subnets we need
variable "subnets" {
  type = map
  default = {
      virtual-machines = {
        cidr = "10.0.1.0/24"
        enforce-private-link-endpoint-policies = false
      }
      storageaccount-endpoint = {
        cidr = "10.0.2.0/24"
        enforce-private-link-endpoint-policies = true
      }
      keyvault-endpoint = {
        cidr = "10.0.3.0/24"
        enforce-private-link-endpoint-policies = true
      }
  }
}

# public ip addresses - Name = SKU
variable public_ips {
    type = map
    default = {
           firewall = "Standard"
           bastion = "Standard"
    }
}

