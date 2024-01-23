#-----outputs.tf-----
#====================
output "Docker-Swarm-nodes-IPs" {
  value = module.compute.docker_swarm_nodes
}

