// customize the simple VM by editing the following local variables
locals {
  // the region of the deployment
  location = "eastus"
  
  vm_admin_password = "ReplacePassword$"
  // if you use SSH key, ensure you have ~/.ssh/id_rsa with permission 600
  // populated where you are running terraform
  vm_ssh_key_data = null //"ssh-rsa AAAAB3...."

  // vfxt details
  vfxt_cluster_name = "vfxt"
  vfxt_cluster_password = "VFXT_PASSWORD"

  // vfxt cache polies
  //  "Clients Bypassing the Cluster"
  //  "Read Caching"
  //  "Read and Write Caching"
  //  "Full Caching"
  //  "Transitioning Clients Before or After a Migration"
  cache_policy = "Clients Bypassing the Cluster"

  // paste the values below from the output of setting up network and filer
  filer_address = ""
  filer_export = ""
  vfxt_cache_subnet_name = ""
  vfxt_render_subnet_name = ""
  
  // paste the values from the values from the controller creation
  controller_address = ""
  controller_username = ""
  vfxt_resource_group_name = ""
}

provider "azurerm" {
    version = "~>2.12.0"
    features {}
}

// the vfxt
resource "avere_vfxt" "vfxt" {
    controller_address = local.controller_address
    controller_admin_username = local.controller_username
    // ssh key takes precedence over controller password
    controller_admin_password = local.vm_ssh_key_data != null && local.vm_ssh_key_data != "" ? "" : local.vm_admin_password
    
    location = local.location
    azure_resource_group = local.vfxt_resource_group_name
    azure_network_resource_group = local.vfxt_network_resource_group_name
    azure_network_name = local.vfxt_network_name
    azure_subnet_name = local.vfxt_cache_subnet_name
    vfxt_cluster_name = local.vfxt_cluster_name
    vfxt_admin_password = local.vfxt_cluster_password
    vfxt_node_count = 3
    global_custom_settings = [
      "cluster.ctcConnMult CE 25"
    ]
    
    core_filer {
        name = "nfs1"
        fqdn_or_primary_ip = local.filer_address
        cache_policy = local.cache_policy
        custom_settings = [
          "always_forward OZ 1", // only a single copy, ensures cluster capacity is the cache capacity
          "autoWanOptimize YF 2", // over WAN (via VPN or express route)
          "nfsConnMult YW 16", // put against heavy duty nfs
        ]
        junction {
            namespace_path = local.filer_export
            core_filer_export = local.filer_export
        }
    }
}

module "cachewarmer_build" {
  source = "github.com/Azure/Avere/src/terraform/modules/cachewarmer_build"

  // authentication with controller
  node_address = local.controller_address
  admin_username = local.controller_username
  admin_password = local.vm_admin_password
  ssh_key_data = local.vm_ssh_key_data
  
  // bootstrap directory to store the cache manager binaries and install scripts
  bootstrap_mount_address = tolist(avere_vfxt.vfxt.vserver_ip_addresses)[0]
  bootstrap_export_path = local.filer_export

  module_depends_on = [avere_vfxt.vfxt.vserver_ip_addresses]
}

module "cachewarmer_manager_install" {
  source = "github.com/Azure/Avere/src/terraform/modules/cachewarmer_manager_install"

  // authentication with controller
  node_address = local.controller_address
  admin_username = local.controller_username
  admin_password = local.vm_admin_password
  ssh_key_data = local.vm_ssh_key_data
  
  // bootstrap directory to install the cache manager service
  bootstrap_mount_address = module.cachewarmer_build.bootstrap_mount_address
  bootstrap_export_path = module.cachewarmer_build.bootstrap_export_path
  bootstrap_manager_script_path = module.cachewarmer_build.cachewarmer_manager_bootstrap_script_path
  bootstrap_worker_script_path = module.cachewarmer_build.cachewarmer_worker_bootstrap_script_path
    
  // the job path
  jobMount_address = tolist(avere_vfxt.vfxt.vserver_ip_addresses)[0]
  job_export_path = local.filer_export
  job_base_path = "/"

  // the cachewarmer VMSS auth details
  vmss_user_name = local.controller_username
  vmss_password = local.vm_admin_password
  vmss_ssh_public_key = local.vm_ssh_key_data
  vmss_subnet_name = local.vfxt_render_subnet_name

  module_depends_on = [module.cachewarmer_build.module_depends_on_id]
}

module "cachewarmer_submitjob" {
  source = "github.com/Azure/Avere/src/terraform/modules/cachewarmer_submitjob"

  // authentication with controller
  node_address = local.controller_address
  admin_username = local.controller_username
  admin_password = local.vm_admin_password
  ssh_key_data = local.vm_ssh_key_data
  
  // the job path
  jobMount_address = module.cachewarmer_manager_install.job_mount_address
  job_export_path = module.cachewarmer_manager_install.job_export_path
  job_base_path = module.cachewarmer_manager_install.job_path

  // the path to warm
  warm_mount_addresses = join(",", tolist(avere_vfxt.vfxt.vserver_ip_addresses))
  warm_target_export_path = local.filer_export
  warm_target_path = "/island"

  module_depends_on = [module.cachewarmer_manager_install.module_depends_on_id]
}

output "bootstrap_mount_address" {
  value = module.cachewarmer_build.bootstrap_mount_address
}

output "bootstrap_export_path" {
  value = module.cachewarmer_build.bootstrap_export_path
}

output "cachewarmer_worker_bootstrap_script_path" {
  value = module.cachewarmer_build.cachewarmer_worker_bootstrap_script_path
}

output "cachewarmer_manager_bootstrap_script_path" {
  value = module.cachewarmer_build.cachewarmer_manager_bootstrap_script_path
}

output "controller_username" {
  value = local.controller_username
}

output "controller_address" {
  value = local.controller_address
}

output "ssh_command_with_avere_tunnel" {
    value = "ssh -L8443:${avere_vfxt.vfxt.vfxt_management_ip}:443 ${local.controller_username}@${local.controller_address}"
}

output "management_ip" {
    value = avere_vfxt.vfxt.vfxt_management_ip
}

output "mount_addresses" {
    value = tolist(avere_vfxt.vfxt.vserver_ip_addresses)
}