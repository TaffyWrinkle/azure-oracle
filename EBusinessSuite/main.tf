# ebs/main.tf

locals {
    subnet_bits = 8   # want 256 entries per subnet.
    # determine difference between VNET CIDR bits and that size subnetBits.
    vnet_cidr_increase = "${32 - element(split("/",var.vnet_cidr),1) - local.subnet_bits}"
    subnetPrefixes = {
        application     = "${cidrsubnet(var.vnet_cidr, local.vnet_cidr_increase, 1)}"
        database        = "${cidrsubnet(var.vnet_cidr, local.vnet_cidr_increase, 2)}"
        bastion         = "${cidrsubnet(var.vnet_cidr, local.vnet_cidr_increase, 3)}"
    }

    #####################
    ## ASG Names
    asgNames = {
        prosched = "asg-prosched"
        compute = "asg-compute"
    }

    #####################
    ## NSG/ASG Rules
    bastion_sr_inbound = [
        {   # SSH from outside
            flavor = "SP-DP"
            source_port_ranges = "*" 
#TODO: Note that only one of prefix or prefixes is allowed and keywords can't be in the list.
            source_address_prefix = "Internet"
            destination_port_ranges =  "22" 
        },{ # SSH from within any of the servers
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "VirtualNetwork"
            destination_port_ranges =  "22" 
        } 
    ]

    bastion_sr_outbound = [
        {  # SSH to any of the servers
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "VirtualNetwork"
            destination_port_ranges =  "22" 
        }    
    ]
    application_sr_inbound = [
        {
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "AzureLoadBalancer"  # input from the Load Balancer only.             
            destination_port_ranges = "8000" 
            destination_address_prefix = "*"             
        },
        {   #TODO: Likely only one of 8000 or 8888 needed..
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "AzureLoadBalancer"  # input from the Load Balancer only.             
            destination_port_ranges = "8888" 
            destination_address_prefix = "*"             
        },
        {
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "${local.subnetPrefixes["bastion"]}"  # input from the Load Balancer only.               
            destination_port_ranges = "22" 
            destination_address_prefix = "*"             
        },
        {   # Special Test
            flavor = "SA-DP"
            source_port_ranges =  "*" 
            # source_address_prefix = "${local.subnetPrefixes["bastion"]}"  # input from the Load Balancer only.               
            source_application_security_group_id = "${module.create_asg.asg_id_ps}"
#            source_application_security_group_id = "${local.asgNames["prosched"]}" # ${module.create_asg.asg_id_ps}"
            destination_port_ranges = "22" 
            destination_address_prefix = "*"  
        }
    ]

    application_sr_outbound = [
        {
            flavor = "SA-DA"
            source_port_ranges =  "*" 
            source_address_prefix = "*" 
            destination_port_ranges =  "1521"            
            destination_address_prefix = "${local.subnetPrefixes["database"]}"  # out to DB
        }
        #TODO:
        # outbound to file service
    ]

    database_sr_inbound = [
        {
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "${local.subnetPrefixes["application"]}"                 
            destination_port_ranges =  "1521" 
            destination_address_prefix = "*"             
        },
        {
            flavor = "SP-DP"
            source_port_ranges =  "*" 
            source_address_prefix = "${local.subnetPrefixes["bastion"]}"  # input from the Load Balancer only.            
            destination_port_ranges =  "22" 
            destination_address_prefix = "*"                
        }
    ]
    database_sr_outbound = [
                {
            flavor = "SP-DP"                    
            source_port_ranges =  "*" 
            source_address_prefix = "${local.subnetPrefixes["bastion"]}"  # input from the Load Balancer only.            
            destination_port_ranges =  "22" 
            destination_address_prefix = "*"                
        }
    ]

    ##########################################
    ## VMs in these subnets will need Availability sets.
    ##########################################
  #  needAVSets = [ "presentation", "application" ]
}

############################################################################################
# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_group_name}"
  location = "${var.location}"
  tags     = "${var.tags}"     
}

############################################################################################
# Create the virtual network
module "create_vnet" {
    source = "./modules/network/vnet"

    resource_group_name = "${azurerm_resource_group.rg.name}"
    location            = "${var.location}"
    tags                = "${var.tags}"    
    vnet_cidr           = "${var.vnet_cidr}"
    vnet_name           = "${var.vnet_name}"
}

# Create Application Security Groups
module "create_asg" {
  source  = "./modules/network/asg"
  resource_group_name       = "${azurerm_resource_group.rg.name}"
  location                  = "${var.location}"
  tags                      = "${var.tags}"
}

###############################################################
# Create each of the Network Security Groups
###############################################################

module "create_networkSGsForBastion" {
    source = "./modules/network/nsgWithRules"

    nsg_name            = "${module.create_vnet.vnet_name}-nsg-bastion"
    resource_group_name = "${azurerm_resource_group.rg.name}"
    location            = "${var.location}"
    tags                = "${var.tags}"    
    subnet_id           = "${module.create_subnets.subnet_names["bastion"]}"
    inboundOverrides    = "${local.bastion_sr_inbound}"
    outboundOverrides   = "${local.bastion_sr_outbound}"
}

module "create_networkSGsForApplication" {
    source = "./modules/network/nsgWithRules"

    nsg_name = "${module.create_vnet.vnet_name}-nsg-application"    
    resource_group_name = "${azurerm_resource_group.rg.name}"
    location = "${var.location}"
    tags = "${var.tags}"    
    subnet_id = "${module.create_subnets.subnet_names["application"]}"
    inboundOverrides  = "${local.application_sr_inbound}"
    outboundOverrides = "${local.application_sr_outbound}"
}

module "create_networkSGsForDatabase" {
    source = "./modules/network/nsgWithRules"

    nsg_name            = "${module.create_vnet.vnet_name}-nsg-database"    
    resource_group_name = "${azurerm_resource_group.rg.name}"
    location            = "${var.location}"
    tags                = "${var.tags}"
    subnet_id           = "${module.create_subnets.subnet_names["database"]}"
    inboundOverrides    = "${local.database_sr_inbound}"
    outboundOverrides   = "${local.database_sr_outbound}"
}

############################################################################################
# Create each of the subnets
module "create_subnets" {
    source = "./modules/network/subnets"

    subnet_cidr_map = "${local.subnetPrefixes}"
    resource_group_name = "${azurerm_resource_group.rg.name}"
    vnet_name = "${module.create_vnet.vnet_name}"
    nsg_ids = "${zipmap(
        list("bastion", "database", "application"),
        list(module.create_networkSGsForBastion.nsg_id,
             module.create_networkSGsForDatabase.nsg_id,
             module.create_networkSGsForApplication.nsg_id))}"
}


###################################################
# Create a Storage account ofr Boot diagnostics 
# information for all VMs.

module "create_boot_sa" {
  source  = "./modules/storage"

  resource_group_name       = "${azurerm_resource_group.rg.name}"
  location                  = "${var.location}"
  tags                      = "${var.tags}"
  compute_hostname_prefix   = "${var.compute_hostname_prefix_app}"
}

###################################################
# Create bastion host

module "create_bastion" {
  source  = "./modules/bastion"

  resource_group_name       = "${azurerm_resource_group.rg.name}"
  location                  = "${var.location}"
  tags                      = "${var.tags}"
  compute_hostname_prefix_bastion = "${var.compute_hostname_prefix_bastion}"
  bastion_instance_count    = "${var.bastion_instance_count}"
  vm_size                   = "${var.vm_size}"
  os_publisher              = "${var.os_publisher}"   
  os_offer                  = "${var.os_offer}"
  os_sku                    = "${var.os_sku}"
  os_version                = "${var.os_version}"
  storage_account_type      = "${var.storage_account_type}"
  bastion_boot_volume_size_in_gb    = "${var.bastion_boot_volume_size_in_gb}"
  admin_username            = "${var.admin_username}"
  admin_password            = "${var.admin_password}"
  custom_data               = "${var.custom_data}"
  bastion_ssh_public_key    = "${var.bastion_ssh_public_key}"
  enable_accelerated_networking     = "${var.enable_accelerated_networking}"
  vnet_subnet_id            = "${module.create_subnets.subnet_ids["bastion"]}"
  boot_diag_SA_endpoint     = "${module.create_boot_sa.boot_diagnostics_account_endpoint}"
}

###################################################
# Create Application server
module "create_app" {
  source  = "./modules/compute"

  resource_group_name       = "${azurerm_resource_group.rg.name}"
  location                  = "${var.location}"
  tags                      = "${var.tags}"
  compute_hostname_prefix_app = "${var.compute_hostname_prefix_app}"
  compute_instance_count    = "${var.compute_instance_count}"
  vm_size                   = "${var.vm_size}"
  os_publisher              = "${var.os_publisher}"   
  os_offer                  = "${var.os_offer}"
  os_sku                    = "${var.os_sku}"
  os_version                = "${var.os_version}"
  storage_account_type      = "${var.storage_account_type}"
  compute_boot_volume_size_in_gb    = "${var.compute_boot_volume_size_in_gb}"
  data_disk_size_gb         = "${var.data_disk_size_gb}"
  data_sa_type              = "${var.data_sa_type}"
  admin_username            = "${var.admin_username}"
  admin_password            = "${var.admin_password}"
  custom_data               = "${var.custom_data}"
  compute_ssh_public_key    = "${var.compute_ssh_public_key}"
  enable_accelerated_networking     = "${var.enable_accelerated_networking}"
  vnet_subnet_id            = "${module.create_subnets.subnet_ids["application"]}"
  backendpool_id            = "${module.lb.backendpool_id}"
  boot_diag_SA_endpoint     = "${module.create_boot_sa.boot_diagnostics_account_endpoint}"  
}

###################################################
# Create Load Balancer
module "lb" {
  source = "./modules/load_balancer"

  resource_group_name = "${azurerm_resource_group.rg.name}"
  location            = "${var.location}"
  tags                = "${var.tags}"  
  prefix              = "${var.compute_hostname_prefix_app}"
  lb_sku              = "${var.lb_sku}"
  frontend_subnet_id  = "${module.create_subnets.subnet_ids["application"]}"
  lb_port             = {
        http = ["8080", "Tcp", "8888"]
  }
}