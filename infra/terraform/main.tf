# Graphwise Stack — AWS infrastructure for a single-node demo deployment.
#
# Creates: one Security Group, one EC2 instance (Debian 13 ARM64 on
# r6g-family Graviton), one Elastic IP associated to the instance, and
# a cloud-init bootstrap script that preps the OS, installs podman +
# kind + kubectl + helm, creates the named user, clones the stack repo,
# and brings up a single-node KIND Kubernetes cluster.
#
# Uses the default VPC + default subnet in the chosen region. This is
# deliberate — a presales demo doesn't need a custom VPC, and keeping
# the module scope tight lets each teammate `terraform apply` in their
# own AWS account without having to reason about networking layout.

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

# Default VPC in the chosen region. Every AWS account has one unless it's
# been explicitly deleted; if yours has been, this module won't work
# without adjustment (either re-create the default VPC or point this at
# an existing custom VPC by swapping the data source for a hardcoded ID).
data "aws_vpc" "default" {
  default = true
}

# Pick the default-VPC subnet in the specified AZ.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }
}

# Latest official Debian 13 ("Trixie") ARM64 AMI. Debian publishes
# images under AWS account 136693071363 with a predictable naming pattern.
# most_recent=true gets you whatever they've published most recently.
data "aws_ami" "debian13_arm64" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-13-arm64-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
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

# n8n encryption key for the graphrag-workflows pod. Generated once
# by Terraform (48 hex chars = 24 bytes of entropy, equivalent to
# `openssl rand -hex 24`) and persisted in state. The key MUST NOT
# change after first n8n boot -- n8n encrypts every stored credential
# with it, so rotating breaks every saved connection.
#
# Empty `keepers` block keeps the value stable across re-applies; it
# only regenerates if you `terraform destroy` and re-`apply` (which
# is also when the n8n DB gets wiped, so the new key is fine).
resource "random_id" "n8n_encryption_key" {
  byte_length = 24
  keepers     = {}
}

# Render the user-data cloud-init script with the per-deployment variables
# inlined as template substitutions. hostname_fqdn is the full
# <subdomain>.<base_domain> — surfaced to NEXT_STEPS.txt and used by the
# teammate when they later run scripts/cluster-bootstrap.sh.
data "cloudinit_config" "bootstrap" {
  gzip          = false
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    filename     = "bootstrap.sh"
    content = templatefile("${path.module}/user-data.sh.tpl", {
      named_user         = var.named_user
      github_repo_url    = var.github_repo_url
      hostname_fqdn      = "${var.subdomain}.${var.base_domain}"
      n8n_encryption_key = random_id.n8n_encryption_key.hex
    })
  }
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

locals {
  name_tag = "${var.instance_name_prefix}-${var.subdomain}"

  # Sanitized subdomain for AWS resource names: dots → hyphens. Lets
  # multi-level subdomains (e.g. "demo.stroker") become "demo-stroker"
  # in resource names, which reads cleaner in the AWS Console and
  # avoids the few dashboards that get fussy about dotted names.
  subdomain_slug = replace(var.subdomain, ".", "-")

  # Explicit, role-suffixed names so each resource is instantly
  # recognisable in the AWS Console search/filter UI rather than
  # showing up as launch-wizard-N or relying on the Name tag alone.
  sg_name       = "${var.instance_name_prefix}-${local.subdomain_slug}-sg"
  instance_name = "${var.instance_name_prefix}-${local.subdomain_slug}-ec2"
  eip_name      = "${var.instance_name_prefix}-${local.subdomain_slug}-eip"

  base_tags = {
    Name      = local.name_tag
    Subdomain = var.subdomain
    ManagedBy = "terraform"
    Project   = "graphwise-stack-aws"
  }

  tags = merge(local.base_tags, var.extra_tags)
}

# ---------------------------------------------------------------------------
# Security group — the ONLY public-facing ports on the stack
# ---------------------------------------------------------------------------

resource "aws_security_group" "stack" {
  # Explicit, dot-free name so the SG is easy to spot in the EC2 Console
  # filter (e.g. "graphwise-stack-demo-stroker-sg" rather than the
  # auto-assigned launch-wizard-N).
  name        = local.sg_name
  description = "Graphwise Stack KIND demo - HTTPS only + SSH-from-admin (${var.subdomain})"
  vpc_id      = data.aws_vpc.default.id
  tags = merge(local.tags, {
    Name = local.sg_name
  })

  # SSH is restricted to the admin CIDR. Every direct-port service
  # (Keycloak :8080, PoolParty :8081, GraphDB :7200/7201, etc.) is
  # bound to 127.0.0.1 inside the instance, so the only admin path
  # to those raw ports is an SSH tunnel.
  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Port 80 is open for two reasons: Let's Encrypt HTTP-01 challenge
  # validation, and the 80 → 443 redirect in proxy-demo.conf.
  ingress {
    description = "HTTP (redirects to 443 + ACME challenge)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Port 443 is the only public entry point for actual stack traffic.
  ingress {
    description = "HTTPS (public entry for every app)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Unrestricted outbound — the instance needs to reach Docker Hub for
  # image pulls, Let's Encrypt for cert issuance, and GitHub for the
  # repo clone. Narrowing outbound hasn't been worth the maintenance
  # cost for a demo stack.
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

resource "aws_instance" "stack" {
  ami                    = data.aws_ami.debian13_arm64.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.stack.id]
  user_data_base64       = data.cloudinit_config.bootstrap.rendered
  tags = merge(local.tags, {
    Name = local.instance_name
  })

  # IMDSv2 required — closes the SSRF-to-credentials hole that IMDSv1
  # leaves open. Modern AWS SDKs speak v2 by default.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags = merge(local.tags, {
      Name = "${local.instance_name}-root"
    })
  }

  # user-data changes require tainting + re-apply, which means a full
  # instance rebuild. Treat user-data as fire-once: any runtime config
  # changes happen on-instance, not via Terraform.
  lifecycle {
    ignore_changes = [user_data_base64]
  }
}

# ---------------------------------------------------------------------------
# Elastic IP — two modes:
#   - `use_existing` mode (existing_eip_allocation_id != ""): look up a
#     pre-allocated EIP by allocation ID and associate it with this
#     instance. Terraform does NOT manage the EIP itself, so destroy
#     leaves it intact and the GoDaddy DNS records stay valid for the
#     next apply. The teammate owns the EIP lifecycle outside Terraform.
#   - `fresh` mode (default): allocate a brand-new EIP each apply. The
#     EIP is destroyed on `terraform destroy`, so DNS must be re-pointed
#     after every rebuild. Simpler, no AWS-side prep, but tedious.
# ---------------------------------------------------------------------------

locals {
  use_existing_eip = var.existing_eip_allocation_id != ""

  # Single source of truth for the public IP, regardless of mode.
  # Outputs and downstream interpolations read this so they don't need
  # to know which path produced it.
  public_ip = local.use_existing_eip ? data.aws_eip.existing[0].public_ip : aws_eip.stack[0].public_ip
}

# Look up the pre-allocated EIP when in use_existing mode. Skipped
# entirely otherwise — `count = 0` keeps the data source out of the plan.
data "aws_eip" "existing" {
  count = local.use_existing_eip ? 1 : 0
  id    = var.existing_eip_allocation_id
}

# Fresh-mode EIP. Created+destroyed alongside the instance.
resource "aws_eip" "stack" {
  count    = local.use_existing_eip ? 0 : 1
  domain   = "vpc"
  instance = aws_instance.stack.id
  tags = merge(local.tags, {
    Name = local.eip_name
  })

  depends_on = [aws_instance.stack]
}

# Use_existing-mode association. Pre-allocated EIP is referenced by
# allocation ID; Terraform creates only the association, so a destroy
# detaches the EIP without releasing it.
resource "aws_eip_association" "existing" {
  count         = local.use_existing_eip ? 1 : 0
  instance_id   = aws_instance.stack.id
  allocation_id = var.existing_eip_allocation_id
}
