# Input variables for the Graphwise Stack AWS module.
#
# Copy terraform.tfvars.example to terraform.tfvars, fill in the
# per-deployment values, and `terraform apply`. Defaults are the
# recommended shipping values — only change them if you have a reason.

variable "region" {
  description = "AWS region to deploy into. Any region that offers r6g-family instances works. Pick one close to you (lower SSH RTT) and to your customer's expected-demo-audience."
  type        = string
  default     = "us-west-2"
}

variable "subdomain" {
  description = "Your subdomain path under base_domain. Single-level (\"scott\") or multi-level (\"demo.stroker\") both work. All app hostnames live one level deeper: poolparty.<subdomain>.<base_domain>, auth.<subdomain>.<base_domain>, graphrag.<subdomain>.<base_domain>, etc. Multi-level lets one teammate run multiple deployments under their own slot (e.g. \"demo.stroker\" + \"prod.stroker\") without colliding. The teammate adds two A records in Route 53 (<subdomain> + *.<subdomain>) pointing at the EIP."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.subdomain))
    error_message = "Subdomain must be lowercase, start/end with a letter or digit, and contain only letters, digits, dots, or hyphens. Multi-level (e.g. \"demo.stroker\") is supported."
  }
}

variable "base_domain" {
  description = "Parent domain that hosts the per-teammate subdomain. Must be a domain whose DNS is hosted in Route 53 in this same AWS account (the EC2 instance role gets scoped Route 53 permissions to the zone via route53_zone_id). Defaults to the Graphwise presales domain registered through Route 53. Override only if you're using your own."
  type        = string
  default     = "semantic-demo.com"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.base_domain))
    error_message = "Base domain must be lowercase, start/end with a letter or digit, and contain only letters, digits, dots, or hyphens."
  }
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for base_domain (e.g. \"Z01234567ABCDEFGHIJK\"). Get it once with: aws route53 list-hosted-zones --query 'HostedZones[?Name==`<base_domain>.`].Id' --output text | sed 's|/hostedzone/||'. Used to scope the EC2 instance role's Route 53 permissions so cert-manager can write _acme-challenge TXT records for DNS-01 wildcard cert issuance, and only on this zone."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must look like a Route 53 hosted zone ID, e.g. Z01234567ABCDEFGHIJK."
  }
}

variable "le_email" {
  description = "Email address for the Let's Encrypt ACME account. LE rejects empty / malformed values AND rejects the RFC 2606 reserved domains (example.com / example.org / example.net). Used by scripts/cluster-bootstrap.sh when it creates the cert-manager ClusterIssuer for DNS-01 wildcard cert issuance. cloud-init writes this to /etc/profile.d/graphwise.sh so the script picks it up automatically -- no manual export needed."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.le_email))
    error_message = "le_email must look like an email address (e.g. you@example.com)."
  }

  # LE explicitly bounces example.com / example.org / example.net per RFC 2606
  # with `urn:ietf:params:acme:error:invalidContact: forbidden domain`. Catching
  # the placeholder here saves the operator 5-10 minutes of wedged cert-manager
  # debugging. Also bans the literal CHANGEME guard string from terraform.tfvars.example.
  validation {
    condition     = !can(regex("@(example\\.(com|org|net))$", lower(var.le_email))) && !can(regex("CHANGEME", var.le_email))
    error_message = "le_email cannot use RFC 2606 reserved domains (@example.com / .org / .net) or the literal 'CHANGEME' placeholder -- Let's Encrypt rejects these with 'forbidden domain' at ACME account registration. Set le_email in terraform.tfvars to a real address (e.g. your-handle@gmail.com)."
  }
}

variable "instance_type" {
  description = "EC2 instance type. r6g.2xlarge (8 vCPU / 64 GB, Graviton ARM64) is the tested minimum for the KIND-on-Docker stack: KIND control plane (~1.5 GB) + ingress-nginx + cert-manager + CNPG + Keycloak operator + Keycloak + 2 Postgres clusters + 2 GraphDB instances + Elasticsearch (8 GB heap) + PoolParty (8 GB heap) + 5 add-ons + 4 GraphRAG services adds up to ~50–55 GB working set. Down-shift only if you're pruning the stack."
  type        = string
  default     = "r6g.2xlarge"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GiB. 300 GiB gives headroom for the KIND containerd image cache (every Helm chart pulls fresh into the node container), local-path-provisioner PVCs (GraphDB data, Postgres clusters, ES indices), and log growth. Can be grown later; can't be shrunk."
  type        = number
  default     = 300
}

variable "key_pair_name" {
  description = "Name of an EXISTING EC2 key pair in the target region (EC2 → Key Pairs). Terraform references it — it does not create it. You keep the matching .pem locally; the instance's ec2-user account will accept logins signed by it."
  type        = string
}

variable "admin_cidr" {
  description = "CIDR block(s) allowed to SSH into the instance on port 22. Use your current public IP + /32 (e.g., \"203.0.113.42/32\"). Never 0.0.0.0/0 — this is the shell on a box that also hosts Keycloak. If you work from multiple networks, list them each in a list-typed wrapper or re-run apply when the IP changes."
  type        = string
}

# Note: there is no `named_user` variable. Amazon Linux 2023 ships with
# `ec2-user`, AWS pre-injects the SSH key into ~ec2-user/.ssh/authorized_keys,
# and the wheel group provides sudo. Creating a separate named user added
# steps with no benefit, so the AL2023 migration dropped it.

variable "github_repo_url" {
  description = "HTTPS URL of the repo to clone onto the instance during bootstrap. Defaults to the public graphwise-stack-aws repo. Override only if you've forked."
  type        = string
  default     = "https://github.com/kentstroker/graphwise-stack-aws.git"
}

variable "github_branch" {
  description = "Branch of github_repo_url that cloud-init clones onto the EC2. Default \"main\" matches the canonical deploy path. Set to a feature branch (e.g. \"refine-rc3\") when running destroy/apply to test in-flight chart changes that haven't been merged yet -- otherwise the new EC2 boots with the GitHub default-branch state and any local-only edits get clobbered."
  type        = string
  default     = "main"
}

variable "availability_zone" {
  description = "Availability zone to place the instance in (e.g. \"us-west-2a\"). Must be in the chosen region. When unset, Terraform picks whichever default-VPC subnet AWS lists first — which may not match your admin_cidr subnet."
  type        = string
}

variable "instance_name_prefix" {
  description = "Prefix for the Name tag on EC2 + SG + EIP. Final tag is \"<prefix>-<subdomain>\". Keep short — some AWS dashboards truncate."
  type        = string
  default     = "graphwise-stack"
}

variable "creator" {
  description = "Name (or email) of the operator running this deployment. Surfaced as the Creator tag on every AWS resource Terraform creates -- shows up in Billing/Cost Explorer, AWS Config, and Resource Groups so shared-account spend can be attributed and orphaned resources can be traced back to their owner. Required: empty string fails the validation below to prevent unattributed deploys from landing in the account."
  type        = string

  validation {
    condition     = length(trimspace(var.creator)) > 0
    error_message = "creator must be set to a name or email so AWS resources are attributable. Add `creator = \"Your Name\"` to terraform.tfvars."
  }
}

variable "purpose" {
  description = "Short free-text label describing what this deployment is FOR (e.g. \"Chevron presales demo\", \"RC3 internal validation\", \"customer X workshop 2026-06\"). Surfaced as the Purpose tag on every AWS resource. Helps shared-account cleanup -- you can scan tags later and tell which EC2s are still load-bearing for a live engagement vs. someone's forgotten test rig. Optional but strongly recommended; defaults to the literal string \"unspecified\"."
  type        = string
  default     = "unspecified"
}

variable "extra_tags" {
  description = "Additional tags applied to every resource Terraform creates. Useful for org-specific cost allocation or compliance tagging beyond the Creator/Purpose pair. Merged AFTER local.base_tags, so an extra_tags entry with the same key overrides the module default (escape hatch for orgs whose tagging policy expects, say, `Owner` instead of `Creator`)."
  type        = map(string)
  default     = {}
}

variable "ami_override" {
  description = "Specific AMI ID to launch the instance with. When empty (default), the module uses data.aws_ami.al2023_arm64 to look up the latest published AL2023 ARM64 AMI -- correct for first apply, but unsafe afterwards because most_recent = true means AWS publishing a refreshed AMI will mark the EC2 for force-replace (destroying all data on the root EBS volume). After the first successful apply, capture `terraform output -raw ami_id` and set this variable to the resulting `ami-...` ID, then re-run `terraform plan` -- you should see no changes. From then on the module ignores AWS AMI publishes entirely. To upgrade later, look up the desired AMI with `aws ec2 describe-images --owners amazon --filters 'Name=name,Values=al2023-ami-*-arm64'` and bump this value (will trigger a controlled replace; snapshot EBS first if you care). Belt-and-braces: aws_instance.stack also ignores ami changes via lifecycle.ignore_changes, so even an unlocked deployment is protected once provisioned."
  type        = string
  default     = ""

  validation {
    condition     = var.ami_override == "" || can(regex("^ami-[a-f0-9]+$", var.ami_override))
    error_message = "ami_override must be empty or a valid AMI ID (e.g. ami-0123456789abcdef0)."
  }
}

variable "existing_eip_allocation_id" {
  description = "Allocation ID (eipalloc-...) of a pre-allocated Elastic IP to attach to this instance. When set, Terraform will NOT create a fresh EIP each apply — it associates the existing one and leaves it untouched on destroy, so the Route 53 DNS records stay valid across rebuilds. Allocate the EIP once in the AWS Console (EC2 → Elastic IPs → Allocate) or via `aws ec2 allocate-address --domain vpc --region us-west-2`. Leave empty to keep the original behaviour (allocate a fresh EIP each apply)."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_eip_allocation_id == "" || can(regex("^eipalloc-[a-f0-9]+$", var.existing_eip_allocation_id))
    error_message = "existing_eip_allocation_id must be empty or a valid EIP allocation ID (e.g. eipalloc-0123456789abcdef0)."
  }
}

variable "adeptnova_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDR ranges allowed to reach the AdeptNova GraphDB on host port
    17200 (the third, publicly-exposed GraphDB instance added in RC2).

    Empty list (default) = no SG rule is created; the instance still
    runs and listens on :31720 inside KIND, but the EC2 security group
    won't admit external traffic to host :17200.

    Example for a single laptop + a customer office:
      adeptnova_cidrs = ["198.51.100.42/32", "203.0.113.0/24"]

    NOTE: the SG rule is created as a standalone
    aws_security_group_rule resource, NOT as an inline ingress block
    on aws_security_group.stack -- that SG has lifecycle.ignore_changes
    = [ingress] to preserve operator-added Console rules.
  EOT
}
