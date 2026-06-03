# =============================================================================
# variables.tf — inputs for the cloud target. Override in terraform.tfvars
# (copy terraform.tfvars.example) or with -var / TF_VAR_* env vars.
# =============================================================================

variable "aws_region" {
  description = "AWS region to deploy into (any free-tier region is fine)."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is free-tier on the credit-based plan."
  type        = string
  default     = "t3.micro"

  # Guardrail: refuse anything that isn't a free-tier micro type, so a typo
  # can't silently provision a billed instance. The newer credit-based Free
  # Tier lists t3.micro (x86_64); the legacy 12-month plan used t2.micro. Both
  # are x86_64 — do NOT switch to t4g.micro (ARM), the AMI/binary are amd64.
  validation {
    condition     = contains(["t3.micro", "t2.micro"], var.instance_type)
    error_message = "Only t3.micro/t2.micro are free-tier eligible (and x86_64). Change this deliberately if you mean to be billed."
  }
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. Free tier allows 30 GiB of gp2/gp3."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size <= 30
    error_message = "Free tier covers up to 30 GiB of EBS; keep root_volume_size <= 30."
  }
}

variable "name_prefix" {
  description = "Prefix for the names/tags of created resources."
  type        = string
  default     = "myapp"
}

variable "key_name" {
  description = "Name to register the AWS key pair under."
  type        = string
  default     = "myapp-deploy"
}

variable "public_key_path" {
  description = <<-EOT
    Path to the PUBLIC half of the SSH key pair to authorize on the instance.
    Generate one with:  ssh-keygen -t ed25519 -f ~/.ssh/myapp-deploy
    Then point this at ~/.ssh/myapp-deploy.pub and load the PRIVATE half
    (~/.ssh/myapp-deploy) into Jenkins Credentials. Terraform never reads the
    private key.
  EOT
  type        = string
}

variable "budget_alert_email" {
  description = <<-EOT
    Email address to receive billing-budget alerts. Leave empty ("") to skip
    creating the budget. AWS sends a one-time confirmation to this address the
    first time the budget fires.
  EOT
  type        = string
  default     = ""
}

variable "monthly_budget_limit" {
  description = "Monthly cost budget in USD. You get emailed as spend approaches it."
  type        = string
  default     = "1"
}

variable "ssh_ingress_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach SSH (tcp/22). Defaults to the whole internet
    for convenience; narrow to ["<your-ip>/32", "<jenkins-ip>/32"] for the
    Stretch goal. The app port (4444) is always open to 0.0.0.0/0 so the
    dashboard can reach it.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
