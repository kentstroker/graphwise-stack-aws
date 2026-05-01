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
  description = "Your subdomain path under base_domain. Single-level (\"scott\") or multi-level (\"demo.stroker\") both work. All app hostnames live one level deeper: poolparty.<subdomain>.<base_domain>, auth.<subdomain>.<base_domain>, graphrag.<subdomain>.<base_domain>, etc. Multi-level lets one teammate run multiple deployments under their own slot (e.g. \"demo.stroker\" + \"prod.stroker\") without colliding. The teammate adds two A records in GoDaddy (<subdomain> + *.<subdomain>) pointing at the EIP."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.subdomain))
    error_message = "Subdomain must be lowercase, start/end with a letter or digit, and contain only letters, digits, dots, or hyphens. Multi-level (e.g. \"demo.stroker\") is supported."
  }
}

variable "base_domain" {
  description = "Parent domain that hosts the per-teammate subdomain. Defaults to the Graphwise presales domain. Override only if you've forked the project for a different parent domain."
  type        = string
  default     = "semantic-proof.com"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.base_domain))
    error_message = "Base domain must be lowercase, start/end with a letter or digit, and contain only letters, digits, dots, or hyphens."
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

variable "availability_zone" {
  description = "Availability zone to place the instance in (e.g. \"us-west-2a\"). Must be in the chosen region. When unset, Terraform picks whichever default-VPC subnet AWS lists first — which may not match your admin_cidr subnet."
  type        = string
}

variable "instance_name_prefix" {
  description = "Prefix for the Name tag on EC2 + SG + EIP. Final tag is \"<prefix>-<subdomain>\". Keep short — some AWS dashboards truncate."
  type        = string
  default     = "graphwise-stack"
}

variable "extra_tags" {
  description = "Additional tags applied to every resource Terraform creates. Useful for your org's cost allocation or owner tagging. Merged with the module's own tags (Name, Subdomain, ManagedBy)."
  type        = map(string)
  default     = {}
}

variable "existing_eip_allocation_id" {
  description = "Allocation ID (eipalloc-...) of a pre-allocated Elastic IP to attach to this instance. When set, Terraform will NOT create a fresh EIP each apply — it associates the existing one and leaves it untouched on destroy, so the GoDaddy DNS records stay valid across rebuilds. Allocate the EIP once in the AWS Console (EC2 → Elastic IPs → Allocate) or via `aws ec2 allocate-address --domain vpc --region us-west-2`. Leave empty to keep the original behaviour (allocate a fresh EIP each apply)."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_eip_allocation_id == "" || can(regex("^eipalloc-[a-f0-9]+$", var.existing_eip_allocation_id))
    error_message = "existing_eip_allocation_id must be empty or a valid EIP allocation ID (e.g. eipalloc-0123456789abcdef0)."
  }
}
