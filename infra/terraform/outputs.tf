# Outputs — printed after `terraform apply` completes.
#
# Cover the four things a teammate acts on immediately after provisioning:
#   1. The Elastic IP (so the teammate adds the Route 53 A records)
#   2. The two Route 53 DNS records to create (single AWS CLI command)
#   3. SSH commands (once keys are valid)
#   4. The expected final public URL (once DNS is up and LE certs issued)

output "elastic_ip" {
  description = "Public Elastic IP. Add this as the value for both Route 53 A records (see route53_dns_records). When existing_eip_allocation_id is set, this stays stable across rebuilds — DNS is set-and-forget. When unset, a fresh EIP is allocated each apply and DNS must be updated."
  value       = local.public_ip
}

output "eip_mode" {
  description = "Which EIP mode is active: 'existing' (persistent across rebuilds, set-and-forget DNS) or 'fresh' (new EIP each apply, update DNS each time)."
  value       = local.use_existing_eip ? "existing (allocation_id=${var.existing_eip_allocation_id})" : "fresh (allocated this apply)"
}

output "route53_dns_records" {
  description = "Single AWS CLI command to UPSERT the two A records in the Route 53 hosted zone. Idempotent (UPSERT) -- safe to re-run after EIP changes. Requires the operator's laptop AWS profile to have route53:ChangeResourceRecordSets on the zone."
  value       = <<-EOT
    Run this once on your laptop to set / refresh the two A records:

      aws route53 change-resource-record-sets --hosted-zone-id ${var.route53_zone_id} --change-batch '{
        "Changes":[
          {"Action":"UPSERT","ResourceRecordSet":{"Name":"${var.subdomain}.${var.base_domain}","Type":"A","TTL":300,"ResourceRecords":[{"Value":"${local.public_ip}"}]}},
          {"Action":"UPSERT","ResourceRecordSet":{"Name":"*.${var.subdomain}.${var.base_domain}","Type":"A","TTL":300,"ResourceRecords":[{"Value":"${local.public_ip}"}]}}
        ]
      }'

    Verify with:
      dig +short ${var.subdomain}.${var.base_domain}
      dig +short poolparty.${var.subdomain}.${var.base_domain}

    Both should return ${local.public_ip} (Route 53 propagation is near-instant).
  EOT
}

output "ami_id" {
  description = "AMI ID the instance was launched from. After first successful apply, copy this value into terraform.tfvars as `ami_override = \"ami-...\"` to lock the deployment against AWS publishing AMI refreshes (which would otherwise force-replace the EC2 and destroy all data). One-shot: `terraform output -raw ami_id` then paste. See infra/README.md → Safety section."
  value       = aws_instance.stack.ami
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
  description = "SSH command for the instance. AL2023's ec2-user is pre-provisioned with your SSH key, has wheel-group sudo, and is the runtime account for KIND/Docker/kubectl. No separate named user is created. Set GRAPHWISE_KEY / GRAPHWISE_HOST / GRAPHWISE_USER per SETUP §7 -- the literal IP form (ssh -i <path-to-keypair.pem> ec2-user@<elastic-ip>) also works."
  value       = "ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST   # GRAPHWISE_HOST=${local.public_ip} or your subdomain"
}

output "expected_urls" {
  description = "Where each app lands once DNS + LE certs are in place. The GraphRAG chatbot is the headline endpoint; the observability triplet (dashboard / prometheus / grafana) is provisioned by scripts/cluster-bootstrap.sh."
  value = {
    chatbot          = "https://graphrag.${var.subdomain}.${var.base_domain}/"
    poolparty        = "https://poolparty.${var.subdomain}.${var.base_domain}/PoolParty/"
    keycloak         = "https://auth.${var.subdomain}.${var.base_domain}/"
    graphdb          = "https://graphdb.${var.subdomain}.${var.base_domain}/"
    graphdb_projects = "https://graphdb-projects.${var.subdomain}.${var.base_domain}/"
    n8n_workflows    = "https://graphrag.${var.subdomain}.${var.base_domain}/workflows/"
    dashboard        = "https://dashboard.${var.subdomain}.${var.base_domain}/"
    prometheus       = "https://prometheus.${var.subdomain}.${var.base_domain}/"
    grafana          = "https://grafana.${var.subdomain}.${var.base_domain}/"
  }
}

output "bootstrap_log_hint" {
  description = "Path on the instance where the cloud-init bootstrap script writes its log. The KIND cluster bring-up runs in this script and adds ~3-5 minutes to the usual provisioning time. Tail this on first SSH to confirm the install finished cleanly."
  value       = "ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST 'sudo tail -f /var/log/bootstrap.log'   # GRAPHWISE_HOST=${local.public_ip} or your subdomain"
}
