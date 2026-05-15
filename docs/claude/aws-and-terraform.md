# AWS account hygiene + Terraform safety

Detail backing the AWS / Terraform rules in `CLAUDE.md`.

## Two-IAM-user actor model

Two distinct IAM users with different blast radii — never combine into one:

1. **Terraform user** (e.g. `terraform-demo`) with `AmazonEC2FullAccess` PLUS a scoped inline IAM policy `graphwise-stack-iam` (see SETUP §4a "Attach scoped IAM permissions for the EC2 instance role"). Holds infrastructure-provisioning credentials. Lives only on the operator's laptop. Used by `terraform apply`, `aws configure`'s default profile, `aws ec2-instance-connect ssh`, and every laptop-side AWS CLI invocation.
2. **Bedrock user** (e.g. `graphrag-bedrock`) with a narrow inline policy granting `bedrock:InvokeModel` + `bedrock:InvokeModelWithResponseStream` on `cohere.embed-english-v3` only. Holds runtime credentials baked into a Helm Secret on the EC2 (`graphrag-components-aws-credentials` in `graphrag` ns) and read by the `graphrag-components` pod every embedding call.

**Critical actor rule:** all IAM user/policy/access-key creation in §4 of SETUP.md is performed by the **root user** OR an existing **IAM admin user** (carrying `AdministratorAccess` or `IAMFullAccess`). NEVER by `terraform-demo` itself — `terraform-demo` lacks `iam:*` on its own user resource and attempting to grant itself perms returns `AccessDenied: iam:PutUserPolicy on resource: user terraform-demo`. SETUP §4 opens with an actor table to make this unmistakable; if SSM-style features are added that require additional IAM permissions, those grants are also performed by root/IAM-admin (same pattern).

**`graphwise-stack-iam` inline policy** (mandatory): Terraform's `infra/terraform/main.tf` creates an `aws_iam_role` + `aws_iam_role_policy` + `aws_iam_instance_profile` so the EC2 host can talk to Route 53 (cert-manager DNS-01 wildcard cert issuance — see `tls-and-ingress.md`). `AmazonEC2FullAccess` does NOT include `iam:*`, so without the scoped inline policy attached to `terraform-demo`, both `terraform apply` and `terraform destroy` fail with `AccessDenied: iam:CreateRole` / `iam:ListInstanceProfilesForRole`. Policy is scoped to role + instance-profile names matching `graphwise-stack-*` — `terraform-demo` still can't touch any other IAM resources in the account. Full JSON in SETUP §4a.

**EC2 Instance Connect special case:** `aws ec2-instance-connect ssh` requires `ec2-instance-connect:SendSSHPublicKey` which is NOT in `AmazonEC2FullAccess`. Operators who use this path attach a small inline policy `ec2-instance-connect-send-key` to `terraform-demo` once (Console-only step, root/IAM-admin performs it). The browser-based "Connect" tab is documented as not working out of the box — its source IP is AWS's service prefix list, blocked by the strict `admin_cidr` SG rule. Manual SG rule add per SETUP §9.

## EIP pre-allocation (required, not optional)

`existing_eip_allocation_id` in `terraform.tfvars` is a **required** field (sits in the REQUIRED block of `terraform.tfvars.example`, not optional). Why: Terraform's default behavior when this is empty is to allocate a fresh EIP each apply AND release it on each `terraform destroy` — so every rebuild gets a different IP and DNS records become stale.

The architecture is: operator allocates the EIP outside Terraform (Console or `aws ec2 allocate-address --domain vpc`), captures the Allocation ID (`eipalloc-...`) AND Public IPv4. The Allocation ID goes in `terraform.tfvars`; the Public IPv4 goes in the two DNS A records (`<sub>.<base>` apex + `*.<sub>.<base>` wildcard). Terraform creates only the `aws_eip_association` (binding the existing EIP to the EC2) — destroy detaches but never releases. EIP + DNS are set-and-forget across destroy/apply cycles.

The Terraform `eip_mode` output reports which path is active (`existing (allocation_id=...)` or `fresh (allocated this apply)`). Walkthrough in SETUP.md §6 (Console + CLI paths to allocate). Lost an entire validated demo deployment to a fresh-EIP rebuild once before promoting this to required; the workflow doesn't recover gracefully when DNS goes stale mid-deployment.

## AMI lock pattern (two layers)

`data "aws_ami" "al2023_arm64"` uses `most_recent = true` because we want fresh deployments to land on the latest AL2023. But every subsequent `terraform plan` re-resolves to a potentially-different AMI ID — and `ami` is a force-replace attribute, so an unscoped `terraform apply` after AWS publishes any AL2023 refresh **destroys the EC2** (root EBS, every PVC) just to "update" the AMI. Lost a fully-validated demo deployment to this exact bug; the rule is now hard-enforced.

Two-layer protection:

1. **Belt — `lifecycle.ignore_changes = [user_data_base64, ami]` on `aws_instance.stack`** (in `infra/terraform/main.tf`). Once provisioned, Terraform never marks the instance for replacement on AMI grounds even if the data-source resolution drifts. Protects every deployment automatically; no operator action required.
2. **Braces — the `ami_override` variable.** After first apply, operator runs `terraform output -raw ami_id` and pastes the resulting `ami-...` into `terraform.tfvars` as `ami_override = "ami-..."`. Re-running `terraform plan` MUST print "No changes." This makes plan output clean (no spurious AMI diffs) and makes intentional AMI upgrades an explicit `terraform.tfvars` edit rather than a side-effect. Documented as DEPLOY.md §1.5 — a required post-first-apply step.

The Safety section in `infra/README.md` is the canonical operator-facing reference. Anything that wants to `terraform apply` after first provision uses scoped `-target=` syntax, and `terraform plan` output is read character-by-character before applying.
