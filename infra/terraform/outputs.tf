# Outputs — printed after `terraform apply` completes.
#
# Cover the four things a teammate acts on immediately after provisioning:
#   1. The Elastic IP (so the teammate adds the GoDaddy A records)
#   2. The two GoDaddy DNS records to create (host + value, ready to paste)
#   3. SSH commands (once keys are valid)
#   4. The expected final public URL (once DNS is up and LE certs issued)

output "elastic_ip" {
  description = "Public Elastic IP. Add this as the value for both GoDaddy A records (see godaddy_dns_records). When existing_eip_allocation_id is set, this stays stable across rebuilds — DNS is set-and-forget. When unset, a fresh EIP is allocated each apply and DNS must be updated."
  value       = local.public_ip
}

output "eip_mode" {
  description = "Which EIP mode is active: 'existing' (persistent across rebuilds, set-and-forget DNS) or 'fresh' (new EIP each apply, update DNS each time)."
  value       = local.use_existing_eip ? "existing (allocation_id=${var.existing_eip_allocation_id})" : "fresh (allocated this apply)"
}

output "godaddy_dns_records" {
  description = "Two A records to add in the GoDaddy DNS console for the base domain. Wait 5-30 minutes for propagation. The output value renders the exact host/value pairs; copy-paste them into GoDaddy."
  value       = <<-EOT
    Add these two A records in GoDaddy DNS for ${var.base_domain}:

      Host: ${var.subdomain}        Type: A    Value: ${local.public_ip}    TTL: 600
      Host: *.${var.subdomain}      Type: A    Value: ${local.public_ip}    TTL: 600

    Verify with:
      dig +short ${var.subdomain}.${var.base_domain}
      dig +short poolparty.${var.subdomain}.${var.base_domain}

    Both should return ${local.public_ip} once DNS has propagated.
  EOT
}

output "instance_id" {
  description = "EC2 instance ID, for AWS Console deep links and `aws` CLI commands."
  value       = aws_instance.stack.id
}

output "instance_public_dns" {
  description = "AWS-assigned public DNS. Useful only for the first SSH login, before your real subdomain is wired up. After DNS is in place, prefer the subdomain-based hostname."
  value       = aws_instance.stack.public_dns
}

output "ssh" {
  description = "SSH command for the instance. AL2023's ec2-user is pre-provisioned with your SSH key, has wheel-group sudo, and is the runtime account for KIND/Docker/kubectl. No separate named user is created."
  value       = "ssh -i <path-to-your-keypair.pem> ec2-user@${local.public_ip}"
}

output "expected_urls" {
  description = "Where each app lands once DNS + LE certs are in place. The GraphRAG chatbot is the headline endpoint."
  value = {
    chatbot          = "https://graphrag.${var.subdomain}.${var.base_domain}/"
    poolparty        = "https://poolparty.${var.subdomain}.${var.base_domain}/PoolParty/"
    keycloak         = "https://auth.${var.subdomain}.${var.base_domain}/"
    graphdb          = "https://graphdb.${var.subdomain}.${var.base_domain}/"
    graphdb_projects = "https://graphdb-projects.${var.subdomain}.${var.base_domain}/"
    n8n_workflows    = "https://graphrag.${var.subdomain}.${var.base_domain}/workflows/"
  }
}

output "bootstrap_log_hint" {
  description = "Path on the instance where the cloud-init bootstrap script writes its log. The KIND cluster bring-up runs in this script and adds ~3-5 minutes to the usual provisioning time. Tail this on first SSH to confirm the install finished cleanly."
  value       = "ssh -i <path-to-your-keypair.pem> ec2-user@${local.public_ip} 'sudo tail -f /var/log/bootstrap.log'"
}
