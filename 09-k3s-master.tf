locals {
  cluster_name = "petercloud-k3s"
}

# Ubuntu 24.04 LTS (Canonical)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---- Master node ----
resource "aws_instance" "ec2_master_instance" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.master_instance_type
  subnet_id              = aws_subnet.public_subnet_01.id
  key_name               = aws_key_pair.ec2_key.key_name
  vpc_security_group_ids = [aws_security_group.sec_group.id, aws_security_group.k3s.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "master-node"
  }

  # The master needs its network path to stay open for as long as it exists:
  # on create, Terraform provisions it over SSH and k3s downloads from the internet;
  # on destroy, Terraform must still reach the k3s API (6443) to remove the Helm
  # releases and labels. Security group rules are separate resources, so without
  # these depends_on Terraform would delete the route/rules first and hang.
  depends_on = [
    aws_route.route,
    aws_route_table_association.route_assocate_01,
    aws_vpc_security_group_ingress_rule.allow_ssh_ipv4,
    aws_vpc_security_group_ingress_rule.k3s_api,
    aws_vpc_security_group_ingress_rule.k3s_self,
    aws_vpc_security_group_egress_rule.allow_all_traffic_ipv4,
    aws_vpc_security_group_egress_rule.k3s_all_out,
  ]

  # SSH settings used by the provisioners below
  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ubuntu"
    private_key = tls_private_key.ssh_key.private_key_pem
  }

  # Step 1: copy the install script to the master
  provisioner "file" {
    source      = "${path.module}/scripts/k3s-master.sh"
    destination = "/tmp/k3s-master.sh"
  }

  # Step 2: install k3s server, passing in the master's public IP
  provisioner "remote-exec" {
    inline = ["sudo bash /tmp/k3s-master.sh ${self.public_ip} ${self.tags["Name"]}"]
  }

  # Step 3: extract the master node token with scp into ./node-token on this machine
  provisioner "local-exec" {
    working_dir = path.module
    command     = "scp -o StrictHostKeyChecking=no -i ${local_sensitive_file.ec2_private_key.filename} ubuntu@${self.public_ip}:/home/ubuntu/node-token node-token"
  }

  # Step 4: download the kubeconfig with scp into ./kubeconfig so kubectl works from this machine
  provisioner "local-exec" {
    working_dir = path.module
    command     = "scp -o StrictHostKeyChecking=no -i ${local_sensitive_file.ec2_private_key.filename} ubuntu@${self.public_ip}:/home/ubuntu/kubeconfig kubeconfig"
  }
}

