# =============================================================================
# main.tf — provision the cloud deployment target for the MyApp Go HTTP service.
#
# This declares the three resources the challenge asks for:
#   * aws_key_pair       — the SSH public key Jenkins (and you) use to log in
#   * aws_security_group — inbound rules: tcp/4444 (the app) and tcp/22 (SSH)
#   * aws_instance       — a free-tier t2.micro running Ubuntu 22.04
#
# Terraform ONLY provisions the box. It deliberately does NOT install the app:
# the Jenkins pipeline (scripts/deploy.sh + scripts/remote-install.sh) ships the
# binary and sets up the systemd unit, exactly like first-deployment-pipeline.
# Keeping "infra" and "deploy" in separate tools is the whole point.
#
# State lives in S3 (see the backend block below) so the laptop and the Jenkins
# pipeline share one source of truth. Create the bucket ONCE before the first
# init (see README "Bootstrap the state bucket").
#
# Usage (laptop):
#   cd terraform
#   cp terraform.tfvars.example terraform.tfvars   # then edit it
#   terraform init                                  # connects to the S3 backend
#   terraform plan
#   terraform apply
#   terraform output public_ip                      # paste this into the dashboard
# =============================================================================

terraform {
  required_version = ">= 1.10"

  # Remote state in S3 so the state survives between Jenkins builds (the
  # pipeline wipes its workspace) and is shared no matter which agent runs.
  # Without this, a lost local state file would orphan the instance and a
  # re-run would create a SECOND one — the free-tier trap we want to avoid.
  #
  # The bucket must already exist (Terraform can't create its own state store).
  # Bootstrap it ONCE — see terraform/README.md:
  #   aws s3api create-bucket --bucket danielc-cs411-tfstate --region us-east-1
  #   aws s3api put-bucket-versioning --bucket danielc-cs411-tfstate \
  #     --versioning-configuration Status=Enabled
  #
  # use_lockfile = native S3 state locking (Terraform >= 1.10), so no DynamoDB
  # table is needed.
  backend "s3" {
    bucket       = "danielc-cs411-tfstate"
    key          = "deployment-to-cloud/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Region/credentials come from the standard AWS chain: env vars
# (AWS_ACCESS_KEY_ID/...), `aws configure` profiles, or SSO. Nothing secret
# lives in this repo. The region is a variable so the AMI lookup follows it.
provider "aws" {
  region = var.aws_region
}

# --- The default VPC ---------------------------------------------------------
# The challenge says "default VPC". We look it up rather than hard-code an ID so
# this config is portable across accounts/regions. The security group is scoped
# to this VPC, and the instance lands in its default subnet automatically.
data "aws_vpc" "default" {
  default = true
}

# --- Latest Ubuntu 22.04 LTS AMI (Canonical) ---------------------------------
# AMI IDs are region-specific, so we resolve the newest official Ubuntu image
# instead of pinning a stale ID. Owner 099720109477 is Canonical's account.
# Default SSH user for these images is "ubuntu" (see variables / Jenkins creds).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# --- SSH key pair ------------------------------------------------------------
# We register the PUBLIC half of an existing key pair. You generate the pair
# locally (ssh-keygen) and keep the private .pem yourself — Terraform never
# sees or stores a private key. The same private key goes into Jenkins
# Credentials ("SSH Username with private key"), so the pipeline can log in to
# the box this key pair authorizes.
resource "aws_key_pair" "deploy" {
  key_name   = var.key_name
  public_key = trimspace(file(pathexpand(var.public_key_path)))

  tags = local.tags
}

# --- Security group ----------------------------------------------------------
# IMPORTANT: a Terraform-managed security group starts with NO egress rules
# (unlike the console, which auto-adds allow-all outbound). We must declare
# egress explicitly or the box loses all outbound traffic.
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-sg"
  description = "Allow app (4444) and SSH (22) inbound for MyApp"
  vpc_id      = data.aws_vpc.default.id

  # The application port. Must be open to the world (0.0.0.0/0) so the dashboard
  # can curl the public IP from the playground's jenkins machine.
  ingress {
    description = "MyApp HTTP service"
    from_port   = 4444
    to_port     = 4444
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH for your laptop and for Jenkins. Narrow this via var.ssh_ingress_cidrs
  # (e.g. ["<your-ip>/32", "<jenkins-ip>/32"]) — see the Stretch note.
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_ingress_cidrs
  }

  # Re-create the allow-all outbound rule the console would have added for us.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# --- The instance ------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type # t2.micro = free-tier
  key_name               = aws_key_pair.deploy.key_name
  vpc_security_group_ids = [aws_security_group.app.id]

  # Default subnets auto-assign a public IP, but we make it explicit so a
  # tightened-down account still yields a reachable box.
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_size # <= 30 GiB (validated) keeps EBS free-tier
    volume_type = "gp3"                # gp3 is covered by the General Purpose SSD allowance
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-target" })
}

# --- Billing budget + alert --------------------------------------------------
# The real free-tier safety net. A monthly COST budget that EMAILS you as spend
# approaches the limit — it does NOT cap or stop anything (that needs a budget
# action + IAM role), it just warns you fast if something starts costing money.
# Budgets are an account-global resource; the first two per account are free.
# The credentials running Terraform need budgets:* and a confirmed SNS/email.
# Skipped entirely when budget_alert_email is left empty.
resource "aws_budgets_budget" "monthly" {
  count = var.budget_alert_email == "" ? 0 : 1

  name         = "${var.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Warn once actual spend crosses 80% of the limit...
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # ...and as soon as the forecast says you'll exceed it this month.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

locals {
  tags = {
    Project   = "harbour-space-cs411-devops"
    Challenge = "deployment-to-cloud"
    ManagedBy = "terraform"
  }
}
