#-----compute/outputs.tf-----
#=============================

output "docker_swarm_nodes" {
  value = aws_instance.docker_swarm[*].public_ip
}

output "ssh_key_public" {
  value = var.ssh_key_public
}