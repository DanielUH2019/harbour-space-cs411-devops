# =============================================================================
# outputs.tf — what you need after `terraform apply`.
# =============================================================================

output "public_ip" {
  description = "Public IPv4 of the instance. Paste THIS into the dashboard."
  value       = aws_instance.app.public_ip
}

output "public_dns" {
  description = "Public DNS name of the instance."
  value       = aws_instance.app.public_dns
}

output "app_url" {
  description = "Where the deployed service answers once the pipeline runs."
  value       = "http://${aws_instance.app.public_ip}:4444/"
}

output "ssh_command" {
  description = "Convenience SSH command (uses the private half of your key pair)."
  value       = "ssh -i <path-to-private-key> ubuntu@${aws_instance.app.public_ip}"
}
