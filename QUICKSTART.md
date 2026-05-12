# QUICKSTART — Graphwise Stack on EC2

Fast path for operators who've done this before (or want to fail fast
and look up details only when stuck). Every command marked with where
it runs (`# laptop` or `# EC2`). For full context on any step, see
[SETUP.md](SETUP.md) and [DEPLOY.md](DEPLOY.md).

**Placeholders used throughout:**

| Placeholder | Example |
|---|---|
| `<your-subdomain>` | `scott` |
| `<your-base-domain>` | `semantic-proof.com` |
| `<your-region>` | `us-west-2` |
| `<your-az>` | `us-west-2a` |
| `<your-laptop-ip>` | result of `curl -4 icanhazip.com` |
| `<your-eip-allocation-id>` | `eipalloc-0123abc...` |
| `<your-eip>` | `54.149.12.34` |
| `<your-instance-id>` | `i-0abcdef0123456789` |
| `<your-key.pem>` | path to your EC2 key pair `.pem` |

---

## 0. Prereqs check (laptop)

```bash
# laptop
git --version && aws --version && terraform version && ssh -V && dig -v && jq --version
```

If any are missing, see [SETUP.md §1-§3](SETUP.md#1-install-a-package-manager).

---

## 1. Clone repo (laptop)

```bash
# laptop
mkdir -p ~/code && cd ~/code
git clone https://github.com/kentstroker/graphwise-stack-aws.git
cd graphwise-stack-aws
```

Details: [SETUP §3 → Clone the repo](SETUP.md#clone-the-graphwise-stack-aws-repo-to-your-laptop).

---

## 2. AWS Console: create IAM users (one-time per AWS account)

Performed by **root or IAM admin** (not by the users you're creating). Web UI only.

1. **Terraform user** — `terraform-demo` → API access only → attach `AmazonEC2FullAccess` → also attach a scoped inline IAM policy `graphwise-stack-iam` so Terraform can manage the EC2 instance role for cert-manager → create access key (Application running outside AWS) → save Access Key ID + Secret. Inline-policy JSON in [SETUP §4a "Attach scoped IAM permissions"](SETUP.md#attach-scoped-iam-permissions-for-the-ec2-instance-role) — without it `terraform apply` / `destroy` fail with `AccessDenied: iam:CreateRole`.
2. **Bedrock user** — `graphrag-bedrock` → API access only → inline policy `bedrock-cohere-invoke` (`bedrock:InvokeModel` + `bedrock:InvokeModelWithResponseStream` on `arn:aws:bedrock:<your-region>::foundation-model/cohere.embed-english-v3`) → create access key → save.

Details: [SETUP §4a](SETUP.md#4a-create-the-terraform-iam-user) + [§4b](SETUP.md#4b-create-the-bedrock-iam-user).

---

## 3. Configure AWS CLI + verify (laptop)

```bash
# laptop
aws configure                                                # paste terraform-demo key + secret + region + json
aws sts get-caller-identity                                  # must show user/terraform-demo
aws ec2 describe-vpcs --max-items 1 --region <your-region>   # must NOT return UnauthorizedOperation

# Bedrock verify (env-vars; default profile stays terraform-demo)
AWS_ACCESS_KEY_ID='<bedrock-access-key-id>' AWS_SECRET_ACCESS_KEY='<bedrock-secret-access-key>' AWS_DEFAULT_REGION=<your-region> aws bedrock-runtime invoke-model --model-id cohere.embed-english-v3 --content-type application/json --accept '*/*' --cli-binary-format raw-in-base64-out --body '{"texts":["hello"],"input_type":"search_document"}' /tmp/embed-test.json && jq '.embeddings[0] | length' /tmp/embed-test.json
# Expected output: number around 1024
```

Details: [SETUP §5](SETUP.md#5-configure-the-aws-cli).

---

## 4. Pre-allocate Elastic IP (laptop)

```bash
# laptop
aws ec2 allocate-address --domain vpc --region <your-region>
# Output JSON includes "AllocationId" (eipalloc-...) and "PublicIp" -- save BOTH
```

Details: [SETUP §6 → Pre-allocate the Elastic IP](SETUP.md#pre-allocate-the-elastic-ip-strongly-recommended).

---

## 5. Add DNS records

Two A records, both pointing at the Public IP from step 4:

| Name | Type | Value | TTL |
|---|---|---|---|
| `<your-subdomain>.<your-base-domain>` | A | `<your-eip>` | 300 |
| `*.<your-subdomain>.<your-base-domain>` | A | `<your-eip>` | 300 |

Verify propagation:

```bash
# laptop
dig +short <your-subdomain>.<your-base-domain> poolparty.<your-subdomain>.<your-base-domain>
# Both lines should print <your-eip>
```

Details: [SETUP §6 → Add the DNS records](SETUP.md#add-the-dns-records-now-that-you-have-the-ip).

---

## 6. EC2 key pair (Console)

AWS Console → EC2 → Network & Security → Key Pairs → Create key pair → name it (e.g. `graphwise-stack`) → RSA or ED25519, `.pem` format → download.

```bash
# laptop
mv ~/Downloads/graphwise-stack.pem ~/.ssh/
chmod 400 ~/.ssh/graphwise-stack.pem
export GRAPHWISE_KEY=~/.ssh/graphwise-stack.pem
export GRAPHWISE_HOST=<your-subdomain>.<your-base-domain>   # or your EIP
export GRAPHWISE_USER=ec2-user
```

Add the three exports to `~/.zshrc` / `~/.bashrc` (or PowerShell `$PROFILE`) so every subsequent terminal already has them. Every `ssh` / `scp` / `rsync` command below references these three vars.

Details: [SETUP §7](SETUP.md#7-ec2-key-pair).

---

## 7. (Optional) Attach `ec2-instance-connect` IAM policy

Skip if you don't plan to use `aws ec2-instance-connect ssh ...`. Done as root or IAM admin in the Console.

IAM → Users → `terraform-demo` → Permissions → Add permissions → Create inline policy → JSON:

```json
{ "Version": "2012-10-17", "Statement": [ { "Effect": "Allow", "Action": "ec2-instance-connect:SendSSHPublicKey", "Resource": "arn:aws:ec2:*:*:instance/*", "Condition": { "StringEquals": { "ec2:osuser": "ec2-user" } } } ] }
```

Name it `ec2-instance-connect-send-key` → Create.

Details: [SETUP §9 Method 1](SETUP.md#method-1-recommended-aws-cli--aws-ec2-instance-connect-ssh).

---

## 8. Edit `terraform.tfvars` (laptop)

```bash
# laptop
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Required fields to set:

```hcl
region                     = "<your-region>"
base_domain                = "<your-base-domain>"
subdomain                  = "<your-subdomain>"
key_pair_name              = "graphwise-stack"
admin_cidr                 = "<your-laptop-ip>/32"
availability_zone          = "<your-az>"
existing_eip_allocation_id = "<your-eip-allocation-id>"
```

Details: [DEPLOY §1 tfvars table](DEPLOY.md#what-to-put-in-terraformtfvars).

---

## 9. `terraform apply` (laptop)

```bash
# laptop
terraform init
terraform plan         # READ this. Should show ~5 resources to create.
terraform apply        # ~3-5 min
```

After apply finishes, cloud-init keeps running for 2-3 more minutes:

```bash
# laptop
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST 'sudo tail -f /var/log/bootstrap.log'
# Wait for "=== Bootstrap complete ===", then Ctrl-C
```

Details: [DEPLOY §1](DEPLOY.md#1-provision-the-ec2-instance).

---

## 10. Lock the AMI (laptop)

```bash
# laptop -- Terraform never runs on EC2
terraform output -raw ami_id        # prints ami-...
$EDITOR terraform.tfvars            # set: ami_override = "ami-..."
terraform plan                      # MUST show "No changes"
```

Protects against AWS-published AMI refreshes triggering an EC2 force-replace on future applies. Details: [DEPLOY §1.5](DEPLOY.md#15-lock-the-ami-one-time-immediately-after-first-apply).

---

## 11. Connect to EC2 (laptop)

```bash
# laptop -- the ssh command lands you on EC2 as ec2-user
ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST
# Or, if you set up step 7:
aws ec2-instance-connect ssh --instance-id <your-instance-id> --private-key-file $GRAPHWISE_KEY
```

---

## 12. Drop creds + licenses

Operator-supplied secrets live in `~/graphwise-secrets.yaml` — auto-created by Terraform cloud-init with empty placeholder blocks, gitignored, never tracked. `reset-helm.sh` auto-includes it via `-f`. Editing this file (instead of the chart's `values.yaml`) means `git pull` is always a clean fast-forward — no merge conflict against your real keys.

```bash
# EC2
cd ~/graphwise-stack-aws
mkdir -p files/licenses
$EDITOR ~/graphwise-secrets.yaml
```

Fill in the empty `""` values across both blocks (leave `n8nEncryption.key` alone — auto-generated by Terraform):

```yaml
maven:
  user:               "<your-graphwise-maven-user>"
  pass:               "<your-graphwise-maven-pass>"

graphrag-secrets:
  awsCredentials:
    region:           "<your-region>"
    accessKeyId:      "AKIA<bedrock-access-key-id>"
    secretAccessKey:  "<bedrock-secret-access-key>"
  n8nLicense:
    activationKey:    "<your-n8n-license-key>"
  n8nEncryption:
    key:              "<auto-generated-by-terraform-DO-NOT-EDIT>"
```

`reset-helm.sh` reads `maven.user` / `maven.pass` to create the `graphwise` image-pull Secret in both the `graphwise` and `graphrag` namespaces; without them, graphrag pods (chatbot, conversation, components, workflows) will `ImagePullBackOff`. The umbrella still installs cleanly without graphrag creds, so you can run `reset-helm.sh --skip-graphrag` now and fill in the `graphrag-secrets` blocks later.

> Legacy fallback: `~/.ontotext/maven-user` + `~/.ontotext/maven-pass` plain-text files still work, but the YAML block is the canonical location.

In another terminal on your laptop:

```bash
# laptop
scp -i $GRAPHWISE_KEY ~/path/to/poolparty.key   $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/files/licenses/poolparty.key
scp -i $GRAPHWISE_KEY ~/path/to/graphdb.license $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/files/licenses/graphdb.license
scp -i $GRAPHWISE_KEY ~/path/to/uv-license.key  $GRAPHWISE_USER@$GRAPHWISE_HOST:~/graphwise-stack-aws/files/licenses/uv-license.key
```

Confirm on EC2:

```bash
# EC2
ls -la files/licenses/
# Should list: poolparty.key, graphdb.license, uv-license.key
```

Details: [DEPLOY §3](DEPLOY.md#3-connect-and-prepare-creds) and [DEPLOY §7](DEPLOY.md#7-configure-graphrag-runtime-credentials).

---

## 13. Cluster operators (EC2)

```bash
# EC2
export LE_EMAIL=you@example.com
./scripts/cluster-bootstrap.sh
# ~5-6 min: ingress-nginx, cert-manager, CNPG, Keycloak operator,
# metrics-server, Kubernetes Dashboard, kube-prometheus-stack.
# Idempotent.
```

Details: [DEPLOY §4](DEPLOY.md#4-install-cluster-operators).

---

## 14. Extract PoolParty realm (EC2)

```bash
# EC2
./scripts/extract-poolparty-realm.sh
```

---

## 15. Install license Secrets (EC2)

```bash
# EC2
./scripts/install-licenses.sh
```

---

## 16. Deploy both Helm releases (EC2)

```bash
# EC2
./scripts/reset-helm.sh --yes <your-subdomain>
# ~10-15 min first time (image pulls, Keycloak realm imports,
# Spring init, LE cert issuance).
```

Watch progress in another SSH session:

```bash
# EC2 (second session)
kubectl get pods -A -w
```

Details: [DEPLOY §8](DEPLOY.md#8-deploy-the-stack).

---

## 17. Verify

```bash
# laptop or EC2 -- HTTPS reachability test
APEX=<your-subdomain>.<your-base-domain>
for h in $APEX poolparty.$APEX auth.$APEX graphdb.$APEX graphrag.$APEX; do
  printf '%-50s ' "$h"
  curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$h/" --max-time 10
done
```

Browser:

- `https://<your-subdomain>.<your-base-domain>/` — Console landing.
- `https://poolparty.<your-subdomain>.<your-base-domain>/PoolParty/` — login `superadmin / poolparty`.
- `https://graphrag.<your-subdomain>.<your-base-domain>/` — chatbot.

Full URL + credentials list: [CONSOLE-GUIDE.md](CONSOLE-GUIDE.md).

---

## Day-2 lifecycle (one-liners)

```bash
# EC2 -- politely quiesce app workloads before stopping the EC2
./scripts/cluster-stop.sh

# laptop -- stop the EC2 (saves ~$0.34/hr; EBS + EIP keep ~$30/mo)
aws ec2 stop-instances --instance-ids <your-instance-id> --region <your-region>

# laptop -- start it back up
aws ec2 start-instances --instance-ids <your-instance-id> --region <your-region>

# EC2 -- after EC2 start, restart the KIND node containers
./scripts/cluster-resume.sh

# EC2 -- wipe and reinstall both Helm releases (DATA LOSS)
./scripts/reset-helm.sh --yes <your-subdomain>
```

Details: [DEPLOY → Day-2 lifecycle](DEPLOY.md#day-2-lifecycle).

---

## Optional: Upload ingest data

Standardized landing pad at `~/staging-data/` on the EC2 (created by
cloud-init). For multi-GB uploads use rsync (resumes interrupted
transfers, compresses on the wire). If rsync is missing, install
once on the laptop: `brew install rsync` (macOS — Apple ships
openrsync since Ventura which has compat quirks) or
`choco install rsync -y` (Windows).

```bash
# laptop -- recommended
rsync -azP -e "ssh -i $GRAPHWISE_KEY" ~/path/to/local-pdfs/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

Fallback (no install needed, but no resume):

```bash
# laptop -- scp recursive copy
scp -r -i $GRAPHWISE_KEY ~/path/to/local-pdfs/ $GRAPHWISE_USER@$GRAPHWISE_HOST:~/staging-data/
```

Persists across EC2 stop/start and reset-helm but NOT
`terraform destroy`. Cluster-side PV/PVC pair already wired in for
graphwise + graphrag namespaces (default-on); pods mount PVC
`staging-data` to read.

Details: [DEPLOY §3.5](DEPLOY.md#35-upload-ingest-data-optional).
