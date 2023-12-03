resource "aws_security_group" "ec2_sg" {
  name        = "tailscale-ec2"
  description = "Allow tailscale ec2 instance to talk to others"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    description = "Allow all traffic within itself"
    protocol    = -1
    self        = true
    from_port   = 0
    to_port     = 0
  }

  egress {
    description = "Allow all external traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tailscale-ec2-sg"
  }
}

resource "tls_private_key" "rsa_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "ec2_key" {
  key_name   = "tailscale-ec2-key"
  public_key = tls_private_key.rsa_key.public_key_openssh
}

resource "aws_iam_role" "ec2_service_role" {
  name = "tailscale-ec2-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "tailscale-ec2-service-role-instance-profile"
  role = aws_iam_role.ec2_service_role.name
}

resource "tailscale_tailnet_key" "ec2-tailscale-key" {
  reusable      = false
  ephemeral     = true
  preauthorized = true
  expiry        = 3600
  description   = "aws-ec2-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  tags = [
    "tag:aws-ec2"
  ]
}

resource "aws_instance" "this" {
  ami                                  = data.aws_ami.amz_linux.id
  instance_type                        = "t2.micro"
  key_name                             = aws_key_pair.ec2_key.key_name
  subnet_id                            = data.aws_subnets.public-subnets.ids[0]
  instance_initiated_shutdown_behavior = "terminate"
  iam_instance_profile                 = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address          = true
  user_data_replace_on_change          = true

  user_data = <<-EOF
    #!/bin/bash
    curl -fsSL https://tailscale.com/install.sh | sh

    tailscale up \
      --auth-key ${tailscale_tailnet_key.ec2-tailscale-key.key} \
      --advertise-exit-node \
      --advertise-routes "${data.aws_vpc.this.cidr_block}" \
      --hostname "aws-ec2" \
      --ssh

    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf
  EOF

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  vpc_security_group_ids = [
    aws_security_group.ec2_sg.id
  ]

  tags = {
    Name = "tailscale-ec2"
  }
}
