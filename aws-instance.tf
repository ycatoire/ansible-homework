variable "access_key" {}
variable "secret_key" {}
variable "route53_zone_id" {}
variable "route53_frontend_fqdn" {}
variable "ssh_pubkey_path" {}
variable "ssh_seckey_path" {}
variable "ami" {
  default = "ami-059eeca93cf09eebd"
}
variable "region" {
  default = "us-east-1"
}

provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${var.region}"
}


## Import the public key
# https://www.terraform.io/docs/providers/aws/r/key_pair.html
resource "aws_key_pair" "raccoon" {
  key_name   = "raccoon"
  public_key = "${file(var.ssh_pubkey_path)}"
}


## Define security groups
# https://www.terraform.io/docs/providers/aws/r/security_group.html
resource "aws_security_group" "backend" {
  name = "backend"
  vpc_id = "${aws_vpc.raccoonvpc.id}"

  # Inbound SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Inbound API
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["${aws_instance.frontend.private_ip}/32"]
    ipv6_cidr_blocks = ["${formatlist("%s/128", aws_instance.frontend.ipv6_addresses)}"]
    # cidr_blocks = ["0.0.0.0/0"]
    # ipv6_cidr_blocks = ["::/0"]
  }

  # Outbound
  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  depends_on = ["aws_instance.frontend"]
}

resource "aws_security_group" "frontend" {
  name = "frontend"
  vpc_id = "${aws_vpc.raccoonvpc.id}"

  # Inbound SSH
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Inbound HTTP
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Inbound HTTPS
  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Outbound
  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

## Create a VPC
# https://www.terraform.io/docs/providers/aws/r/vpc.html
resource "aws_vpc" "raccoonvpc" {
  cidr_block = "10.0.0.0/24"
  enable_dns_support = true
  assign_generated_ipv6_cidr_block = true
}

## Create a gateway
# https://www.terraform.io/docs/providers/aws/r/internet_gateway.html
resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.raccoonvpc.id}"
}

## Create a route table
# https://www.terraform.io/docs/providers/aws/r/route_table.html
resource "aws_default_route_table" "rt" {
  default_route_table_id = "${aws_vpc.raccoonvpc.default_route_table_id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }
}

## Create a subnet
# https://www.terraform.io/docs/providers/aws/r/subnet.html
resource "aws_subnet" "calcapp_net" {
  cidr_block = "10.0.0.0/24"
  vpc_id = "${aws_vpc.raccoonvpc.id}"
  ipv6_cidr_block = "${cidrsubnet(aws_vpc.raccoonvpc.ipv6_cidr_block, 8, 2)}"
  map_public_ip_on_launch = false
  assign_ipv6_address_on_creation = true


  depends_on = ["aws_internet_gateway.gw"]
}


## Create EC2 instances
# https://www.terraform.io/docs/providers/aws/r/instance.html
resource "aws_instance" "backend" {
  count = 1
  ami = "${var.ami}"
  instance_type = "t2.micro"
  key_name = "raccoon"
  subnet_id = "${aws_subnet.calcapp_net.id}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.backend.id}"]
  tags {
    name = "backend"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/",
      "sudo apt-get update && sudo apt-get install -q -y python2.7-minimal && sudo update-alternatives --install /usr/bin/python python /usr/bin/python2.7 1"
    ]
    connection {
      type = "ssh"
      user = "ubuntu"
      private_key = "${file(var.ssh_seckey_path)}"
    }
  }
}

resource "aws_instance" "frontend" {
  count = 1
  ami = "${var.ami}"
  instance_type = "t2.micro"
  key_name = "raccoon"
  subnet_id = "${aws_subnet.calcapp_net.id}"
  associate_public_ip_address = true
  vpc_security_group_ids = ["${aws_security_group.frontend.id}"]
  tags {
    name = "frontend"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/",
      "sudo apt-get update && sudo apt-get install -q -y python2.7-minimal && sudo update-alternatives --install /usr/bin/python python /usr/bin/python2.7 1"
    ]
    connection {
      type = "ssh"
      user = "ubuntu"
      private_key = "${file(var.ssh_seckey_path)}"
    }
  }
}

## Create an Elastic IP
# https://www.terraform.io/docs/providers/aws/r/eip.html
resource "aws_eip" "frontend" {
  vpc = true
  instance = "${aws_instance.frontend.id}"
  associate_with_private_ip = "${aws_instance.frontend.private_ip}"
  depends_on = ["aws_internet_gateway.gw", "aws_instance.frontend"]
}

## Create DNS records
# https://www.terraform.io/docs/providers/aws/r/route53_record.html
resource "aws_route53_record" "domain_v4" {
  name = "${var.route53_frontend_fqdn}"
  type = "A"
  zone_id = "${var.route53_zone_id}"
  ttl = "300"
  records = ["${aws_eip.frontend.public_ip}"]
}

resource "aws_route53_record" "domain_v6" {
  name = "${var.route53_frontend_fqdn}"
  type = "AAAA"
  zone_id = "${var.route53_zone_id}"
  ttl = "300"
  records = ["${aws_instance.frontend.ipv6_addresses}"]
}

## Run ansible
resource "null_resource" "api_ansible_inventory" {
  provisioner "local-exec" {
    command = "echo \"[api]\n${aws_instance.backend.public_ip} ansible_ssh_user=root\n\" >> inventory/aws"
  }
  depends_on = ["aws_instance.backend"]
}

resource "null_resource" "web_ansible_inventory" {
  provisioner "local-exec" {
    command = "echo \"[web]\n${aws_eip.frontend.public_ip} ansible_ssh_user=root\n\" >> inventory/aws"
  }
  depends_on = ["aws_instance.frontend"]
}

resource "null_resource" "ansible-playbook" {
  provisioner "local-exec" {
    command = "sleep 10; ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory/aws calcapp.yml --extra-vars \"api_sum_host=${aws_instance.backend.private_ip} host=${var.route53_frontend_fqdn}\""
  }
  depends_on = ["null_resource.api_ansible_inventory", "null_resource.web_ansible_inventory", "aws_route53_record.domain_v4"]
}

