**docker-swarm-ec2-provisioner** — Terraform and Ansible pipeline that provisions a three-node Docker Swarm cluster on AWS EC2, with all Swarm networking ports pre-configured and Docker installed on every node automatically.

---

## Project at a Glance

| | |
|---|---|
| **Tools Used** | Terraform, Ansible, AWS EC2, AWS VPC, AWS SSM Parameter Store |
| **Platform** | Amazon Web Services (us-east-1) |
| **Languages** | HCL (Terraform), YAML (Ansible) |
| **What It Does** | Provisions a custom VPC and spins up three EC2 instances — one designated Swarm manager and two workers — each bootstrapped with Docker Engine via Ansible, ready to form a Docker Swarm cluster |

---

## The Problem This Project Solves

Docker Swarm provides container orchestration without the operational overhead of Kubernetes, making it an appropriate choice for teams that need multi-node workload distribution, rolling updates, and service-level redundancy without managing a full control plane. The challenge is that standing up a properly networked Swarm cluster involves configuring a non-trivial set of ports across all nodes: TCP 2377 for cluster management, TCP/UDP 7946 for inter-node gossip, and UDP 4789 for the overlay network data plane.

This project automates the full cluster provisioning lifecycle. Terraform creates the VPC, routing, and security group with all required Swarm ports, then uses a `count` meta-argument to provision three identically configured EC2 instances simultaneously. Naming logic built into the `tags` block automatically labels index 0 as the Swarm manager and indices 1 and 2 as workers — providing a clear operational topology without any manual tagging. Each instance is then bootstrapped via Ansible to install Docker, create the `docker` group, add `ec2-user` to it, start and enable the Docker service, and set the correct socket permissions.

For engineering teams evaluating this project: the separation of concerns between the `vpc` and `compute` modules means the network configuration can be updated and re-applied independently of the compute layer. The output block exports all three node public IPs as a list, making it straightforward to feed those addresses into subsequent automation — such as running `docker swarm init` on the manager and `docker swarm join` on the workers.

---

## Architecture

```
Local Machine
     |
     | terraform apply
     v
+-----------------------------+
|  ROOT MODULE (main.tf)      |
|  - Provider: AWS us-east-1  |
+----+----------------+-------+
     |                |
     v                v
+----------+   +----------------------------+
| modules/ |   | modules/compute            |
|   vpc    |   | count = 3 EC2 instances    |
+----------+   +----------------------------+
     |                |
     v                v
AWS VPC (10.0.0.0/16)     [0] swarm_manager_0  (t3.micro)
     |                    [1] swarm_worker_1    (t3.micro)
     +--> Public Subnet   [2] swarm_worker_2    (t3.micro)
          10.0.1.0/24          |
     |                         v
     +--> IGW              Per-node bootstrap (remote-exec):
     |                      1. yum update
     +--> Route Table       2. install ansible2 via amazon-linux-extras
     |                      3. ansible-playbook install_docker.yaml
     +--> Security Group         - Install Docker
          TCP 22                 - Create docker group
          TCP/UDP 80             - Add ec2-user to docker group
          TCP 8080               - Start + enable Docker service
          TCP 1233               - Set docker.sock permissions (777)
          TCP 2377  (Swarm mgmt)
          TCP/UDP 7946 (gossip)
          UDP 4789  (overlay)
          TCP 30000, 32100, 32200 (service ports)

Outputs:
  Docker-Swarm-nodes-IPs = [<manager-ip>, <worker1-ip>, <worker2-ip>]
```

---

## Repository Structure

```
docker-swarm-ec2-provisioner/
├── main.tf                  # Root module: wires vpc and compute modules
├── variables.tf             # Root-level variables (AWS region)
├── outputs.tf               # Outputs: list of all Swarm node public IPs
├── install_docker.yaml      # Ansible playbook: Docker installation and configuration
├── modules/
│   ├── vpc/
│   │   ├── main.tf          # VPC, IGW, subnet, route table, Swarm-aware security group
│   │   ├── variables.tf     # Region variable
│   │   └── outputs.tf       # Exports: subnet ID, security group ID, subnet CIDR
│   └── compute/
│       ├── main.tf          # 3x EC2 instances, key pair, SSM AMI lookup, provisioners
│       ├── variables.tf     # Region, SSH key paths, subnet, security group inputs
│       └── outputs.tf       # Exports: all node public IPs (splat expression)
└── .gitignore
```

---

## How It Works

The `vpc` module provisions a `/16` VPC in `us-east-1` with a single public subnet (`10.0.1.0/24`) in the first available availability zone. The security group created by this module is specifically configured for Docker Swarm communication: in addition to the standard SSH (22), HTTP (80), and application ports (8080, 1233), it opens TCP 2377 for Swarm cluster management traffic, TCP and UDP 7946 for container network discovery gossip, UDP 4789 for the VXLAN overlay network data plane, and TCP ports 30000, 32100, and 32200 for deployed service access.

The `compute` module uses Terraform's `count` parameter set to `3` to create three identical `t3.micro` Amazon Linux 2 instances in a single resource block. A conditional tag expression (`count.index == 0 ? "swarm_manager_0" : "swarm_worker_${count.index}"`) automatically assigns the correct role label to each instance without requiring separate resource blocks. All three instances resolve their AMI dynamically via AWS SSM Parameter Store.

Each instance runs the same bootstrap sequence through Terraform provisioners: the `install_docker.yaml` Ansible playbook is copied to the remote host, then Ansible 2 is installed via `amazon-linux-extras` and the playbook is executed. The playbook installs Docker, ensures the `docker` system group exists, appends `ec2-user` to that group, starts and enables the Docker daemon, and sets the socket permissions to allow non-root access.

After `terraform apply` completes, the operator connects to the manager node to initialize the Swarm, then uses the join token to connect the worker nodes — a two-command operation made possible because all infrastructure is already in place.

---

## Walkthrough

**1. Initialize and preview**
```bash
terraform init
terraform plan
```

**2. Apply — provisions all three nodes simultaneously**
```bash
terraform apply
```

**3. Retrieve all node IPs**
```bash
terraform output Docker-Swarm-nodes-IPs
# Example output:
# [
#   "54.12.34.100",   <- manager
#   "54.12.34.101",   <- worker 1
#   "54.12.34.102",   <- worker 2
# ]
```

**4. Initialize the Swarm on the manager node**
```bash
ssh -i ~/.ssh/id_ed25519 ec2-user@<manager-ip>
docker swarm init --advertise-addr <manager-private-ip>
# Copy the join token from the output
```

**5. Join worker nodes to the Swarm**
```bash
ssh -i ~/.ssh/id_ed25519 ec2-user@<worker1-ip>
docker swarm join --token <token> <manager-ip>:2377

ssh -i ~/.ssh/id_ed25519 ec2-user@<worker2-ip>
docker swarm join --token <token> <manager-ip>:2377
```

**6. Verify cluster state from the manager**
```bash
docker node ls
```

**7. Destroy all resources**
```bash
terraform destroy
```

---

## How to Reproduce

**Prerequisites**
- Terraform >= 0.15.5
- AWS credentials configured
- SSH key pair at `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`

```bash
# Clone the repository
git clone https://github.com/<your-username>/docker-swarm-ec2-provisioner.git
cd docker-swarm-ec2-provisioner

# Review and update SSH key paths if needed (modules/compute/variables.tf)

# Deploy the three-node cluster
terraform init
terraform apply -auto-approve

# Get all node IPs
terraform output Docker-Swarm-nodes-IPs

# Clean up
terraform destroy -auto-approve
```

---

*Oluwaseyi Michael Falode · Cybersecurity & Cloud Security Engineer · Toronto, ON*
