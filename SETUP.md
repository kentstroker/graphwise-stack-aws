# Graphwise Stack — Laptop Setup Guide

**Maintainer:** Kent Stroker
**Audience:** Anyone standing up the Graphwise Stack on a fresh
laptop, from scratch.

This document covers everything that happens **on your laptop and in
third-party accounts** before the first `terraform apply`. By the end
you will have:

- A working terminal with Homebrew (macOS) or Chocolatey (Windows).
- AWS CLI installed and authenticated as an IAM user with EC2 +
  Bedrock permissions.
- AWS Bedrock available in your region (no per-model approval
  needed — AWS now grants foundation-model access by default), plus
  a least-privilege IAM user with `bedrock:InvokeModel` on
  `cohere.embed-english-v3` for the GraphRAG pod.
- Terraform installed and on `PATH`.
- An EC2 key pair downloaded and `chmod 400`'d.
- A GoDaddy (or other DNS-provider) plan for two A-records
  (`<sub>.<base>` + wildcard).
- Graphwise Maven registry credentials and license files in hand.

When you're done here, jump to [infra/README.md](infra/README.md)
for `terraform init` / `plan` / `apply`.

> **Time investment.** Allow 60–90 minutes the first time, less if
> you already have AWS / Homebrew / Terraform set up.

---

## 0. Open the default terminal

You'll need a terminal to run **anything** in this guide. The OS
default works fine for now — we'll install a nicer one in step 2 once
the package manager is in place.

- **macOS:** open **Terminal** (Spotlight → "Terminal").
- **Windows:** open **PowerShell** as **Administrator** (Start →
  type "PowerShell" → right-click "Run as administrator"). Steps 1
  and 2 below need elevated rights to install system-wide tools.

---

## 1. Install a package manager

Everything else in this guide installs via the package manager. Do
this first.

### macOS — Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

When the installer finishes, follow the printed instructions to add
Homebrew to your shell `PATH` (typically two `eval` lines appended to
`~/.zprofile`). Open a new Terminal tab so the `PATH` change takes
effect, then verify:

```bash
brew --version
```

### Windows — Chocolatey

In your Administrator PowerShell:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

Close and reopen the Administrator PowerShell so the `PATH` picks up
`choco`, then verify:

```powershell
choco --version
```

Subsequent `choco install …` commands all need that Administrator
PowerShell.

---

## 2. (Optional) Install a nicer terminal

Apple Terminal and PowerShell work, but a modern terminal makes the
rest of this guide nicer (tabs, split panes, search-as-you-type,
better copy/paste). Skip if you don't care.

**macOS — iTerm2:**

```bash
brew install --cask iterm2
```

Then quit Terminal and open iTerm2 — run the rest of the guide
there.

**Windows — Windows Terminal:**

```powershell
choco install microsoft-windows-terminal -y
```

(Or [Hyper](https://hyper.is/): `choco install hyper -y`.) Pin it to
the taskbar, then open a new Administrator session in the new
terminal for the next steps.

---

## 3. Install required CLIs

### git

**macOS:**

```bash
brew install git
git --version
```

**Windows:**

```powershell
choco install git -y
git --version
```

If `git --version` already works, skip — many systems have it
preinstalled.

#### Set your identity (one-time)

Commits use these two values; without them, `git commit` won't even
fire. Set them globally:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

#### Credential storage — only matters if you push

The public stack repo (`https://github.com/kentstroker/graphwise-stack-aws.git`)
is **read-only without auth**. If all you do is `git clone` and
`git pull`, you don't need credentials at all.

You only need to set up credential storage if you're going to:

- Push to your own fork.
- Open issues or PRs from the CLI (`gh` works too — separate auth).
- Pull from a private fork later.

Pick **one** of two approaches:

**Option A — HTTPS + Personal Access Token (simplest)**

1. GitHub → Settings → Developer settings → **Personal access
   tokens** → Tokens (classic) → Generate new token.
2. Give it `repo` scope (and `workflow` if you'll touch GitHub
   Actions). 90-day expiry is fine for demo work.
3. Save the token somewhere like 1Password — GitHub only shows it
   once.
4. Configure git to remember it via the OS-native keychain:

   **macOS** (uses Apple Keychain — Apple's git ships with this
   helper, brew git includes it too):

   ```bash
   git config --global credential.helper osxkeychain
   ```

   **Windows** (Git for Windows ships **Git Credential Manager**
   already — verify):

   ```powershell
   git config --global credential.helper manager
   ```

5. The next `git push` prompts for username (your GitHub username)
   and password (paste the **token**, not your account password).
   The credential helper writes it to the OS keychain and the
   subsequent pushes don't prompt again.

**Option B — SSH keys (more setup, fewer expirations)**

Tokens expire and have to be rotated; SSH keys don't (until you
revoke them). One-time setup:

```bash
ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/id_github
cat ~/.ssh/id_github.pub
```

Copy the printed public key into GitHub → Settings → SSH and GPG
keys → New SSH key. Then tell git to use SSH instead of HTTPS for
GitHub:

```bash
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

Verify:

```bash
ssh -T git@github.com
# "Hi <username>! You've successfully authenticated..."
```

Pushes from any clone of any GitHub repo now go over SSH using that
key — no token, no prompt.

> **The instance you'll deploy onto** clones this repo via cloud-init
> over **read-only HTTPS** — that flow needs no credentials. You'd
> only need to configure `git` credentials on the EC2 host if you
> want to push commits back from there. SSH-key approach is the
> least painful for that — generate a separate `id_github` on the
> instance and add it to your GitHub account.

### jq (JSON processor — used by AWS CLI examples below)

**macOS:**

```bash
brew install jq
jq --version
```

**Windows:**

```powershell
choco install jq -y
jq --version
```

### AWS CLI

**macOS:**

```bash
brew install awscli
aws --version
```

**Windows:**

```powershell
choco install awscli -y
aws --version
```

Want at least AWS CLI v2 (`aws-cli/2.x.x`).

### Terraform

**macOS:**

```bash
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version
```

**Windows:**

```powershell
choco install terraform -y
terraform version
```

Want at least 1.5.0.

### SSH client

**macOS:** included with the OS; no install needed. `ssh -V`
verifies.

**Windows 10/11:** OpenSSH client is an optional Windows feature —
usually already enabled. Verify:

```powershell
ssh -V
```

If "command not found", install via Settings → Apps → Optional
features → Add a feature → "OpenSSH Client". (Or
`choco install openssh -y`.)

### dig (DNS troubleshooting)

**macOS:** included.

```bash
dig -v
```

**Windows:** not included by default. Install BIND tools via
Chocolatey:

```powershell
choco install bind-toolsonly -y
dig -v
```

If you'd rather not, `nslookup` is an OK fallback for the few times
this guide uses `dig`.

---

## 4. AWS account setup

Skip this section if you already have an AWS account.

### Sign up

Go to https://aws.amazon.com/ → "Create an AWS account". You'll
need a credit card (you'll be charged for the EC2 instance — see
the README cost notes).

### Create an IAM user (don't use root for terraform)

The root account is the email you signed up with. **Do not use it
for day-to-day work** — create an IAM user with just the
permissions you need.

1. AWS Console → IAM → Users → Create user.
2. Name it something like `graphwise-stack-admin`.
3. Skip "Provide user access to the AWS Management Console" (we only
   need API access).
4. Attach policies directly → search for and attach
   **`AmazonEC2FullAccess`** (Terraform needs this for the EC2
   instance, security group, EIP). Don't attach `AdministratorAccess`.
5. Create user.
6. Open the user → Security credentials → Create access key →
   choose "Application running outside AWS" → Save the **Access Key
   ID** and **Secret Access Key** somewhere you can find them in 5
   minutes (you'll paste them into `aws configure` next).

### Set a billing alarm (optional but recommended)

A `r6g.2xlarge` runs ~$300/month if left on 24/7. AWS Console →
Billing → Budgets → Create budget → "Monthly cost" → set a threshold
and an email destination. One-time setup, prevents surprises.

### Auto-shutdown the EC2 instance overnight (strongly recommended)

The single biggest source of accidental AWS charges with this stack
is leaving the instance running while you're not using it. The
demo doesn't need to be on outside business hours — the cluster
restarts cleanly with `./scripts/cluster-resume.sh` after a stop, so
shutting down at end of day costs nothing operationally and saves
roughly two-thirds of the monthly bill.

Pick whichever fits your workflow:

- **Manual stop when you're done:** AWS Console → EC2 → Instances →
  select instance → Instance state → **Stop instance** (not
  Terminate — that destroys the EBS volume). To resume:
  Instance state → Start. EIP and DNS records survive a stop.
- **Scheduled stop via AWS Instance Scheduler:** AWS Console → EC2
  → Instance Scheduler. Apply tag-based schedules (e.g.,
  `Schedule = office-hours`) and the Scheduler stops/starts your
  instance on a cron. Free Lambda + DynamoDB usage stays within the
  AWS Free Tier for a single instance. Setup walkthrough:
  https://docs.aws.amazon.com/solutions/latest/instance-scheduler-on-aws/
- **Quick-and-dirty cron on your laptop:** add a daily cron entry
  on your laptop that runs
  `aws ec2 stop-instances --instance-ids i-xxxxx` at 6 PM. Crude
  but works.

If you go the Scheduler route, allow it from the start — adding it
later requires either tagging the instance after `terraform apply`
or wiring `extra_tags` in `terraform.tfvars` to set the schedule
tag at provision time:

```hcl
extra_tags = {
  Schedule = "office-hours"
}
```

The instance can be Stopped indefinitely without losing data — only
the compute clock pauses. Storage (EBS volume + EIP allocation)
keeps billing at a tiny fraction (~$30/month for 300 GB gp3 + EIP)
even while stopped.

---

## 5. Configure the AWS CLI

### Standard credentials (`aws configure`)

```bash
aws configure
```

Paste the Access Key ID + Secret Access Key from the previous step.
For region, pick one with current Amazon Linux 2023 ARM64 AMIs (every major
ones — `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`,
`eu-central-1` all work). Output format: `json`.

Verify:

```bash
aws sts get-caller-identity
```

You should see your account number and the ARN of the
`graphwise-stack-admin` IAM user. If you see `arn:aws:iam::...:root`,
you're authenticated as root — go back and create the IAM user.

### SSO instead (if your org uses it)

```bash
aws configure sso
```

Walks you through a browser login. End result: same as `aws
configure` but with rotating tokens. `aws sts get-caller-identity`
still verifies.

---

## 6. Create the Bedrock IAM user and verify access

GraphRAG's `graphrag-components` pod calls Bedrock for embeddings at
runtime. Bedrock foundation models are now accessible by default in
supported regions — AWS dropped the per-model "Modify model access"
approval flow that used to gate this. The only thing that matters
now is **which IAM identity has `bedrock:InvokeModel` on the
model**. We give that permission to a dedicated, narrow-scope user
(not your `terraform-demo` / `graphwise-stack-admin` user) so the
runtime credentials baked into the chart are least-privilege.

### Pick the Bedrock region

The `graphrag-secrets.awsCredentials.region` value defaults to
`us-east-1` in `charts/graphwise-stack/values.yaml`. `us-east-1` and
`us-west-2` have the broadest model catalog. If you change the
region here, change it in the chart values too — the EC2 instance
region (`terraform.tfvars`) and the Bedrock region don't have to
match, but both must be valid.

### Create the IAM user

1. AWS Console → IAM → Users → **Create user**.
2. Name it `graphrag-bedrock` (or per-deployment, e.g.
   `graphrag-bedrock-stroker`).
3. **Skip "Provide user access to the AWS Management Console"** —
   API-only.
4. **Don't attach a managed policy.** `AmazonBedrockFullAccess`
   would work but it grants more than we need; the inline policy
   below is narrower.
5. Create the user.

### Attach an inline policy scoped to the embedding model

Open the new user → **Add permissions** → **Create inline policy**
→ JSON tab → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:us-west-2::foundation-model/cohere.embed-english-v3"
    }
  ]
}
```

If you picked a region other than `us-west-2`, change it in the
`Resource` ARN. The empty segment between the two `::` is correct —
foundation-model ARNs have no account-id component. Save the policy
as `bedrock-cohere-invoke`.

### Create an access key for the new user

User → Security credentials → **Create access key** → "Application
running outside AWS" → save the **Access Key ID** and **Secret
Access Key**. AWS only shows the secret once — drop it in your
password manager now.

**Save these somewhere you can paste from later** (password manager
preferred). You'll edit them into the umbrella chart's values file
on the EC2 instance — but only **after** cloning the repo there
during the deploy flow. They go here:

```
file: charts/graphwise-stack/values.yaml   (edit on the EC2 host, NOT on your laptop)
```

```yaml
graphrag-secrets:
  awsCredentials:
    region: "us-west-2"
    accessKeyId: "AKIA<your access key id>"
    secretAccessKey: "<your secret access key>"
```

> **Don't edit the values.yaml on your laptop and commit it.** That
> file ships in git with placeholder values
> (`REPLACE_WITH_REAL_AWS_ACCESS_KEY_ID`); committing your real
> credentials publishes them. Keep the edit local to the EC2 host.

The umbrella chart materializes the values into a Kubernetes Secret
named `graphrag-components-aws-credentials` in the `graphrag`
namespace, which the `graphrag-components` pod mounts at runtime.

The exact step that does the editing is in the
[DEPLOY.md "Deploy from zero" walk-through](DEPLOY.md#deploy-from-zero)
(the "Configure GraphRAG runtime credentials" step, just before
`reset-helm.sh`). It's listed there so you don't forget — without
the real credentials, `graphrag-components` will deploy but the
chatbot will return Bedrock `AccessDeniedException` on every prompt.

### Verify the new user can invoke the model

Use the new user's credentials directly via env-vars — no profile
setup needed for a one-shot test, and your default profile keeps
pointing at the EC2-driving identity:

```bash
AWS_ACCESS_KEY_ID='<paste-access-key-id>' AWS_SECRET_ACCESS_KEY='<paste-secret-access-key>' AWS_DEFAULT_REGION=us-west-2 aws bedrock-runtime invoke-model --model-id cohere.embed-english-v3 --content-type application/json --accept '*/*' --cli-binary-format raw-in-base64-out --body '{"texts":["hello"],"input_type":"search_document"}' /tmp/embed-test.json && jq '.embeddings[0] | length' /tmp/embed-test.json
```

`--cli-binary-format raw-in-base64-out` is required because AWS
CLI v2 expects `--body` to be base64-encoded by default and
otherwise rejects the literal JSON with `Invalid base64`.

Expected output: a number around `1024` (the embedding dimension).

Common failures:

- **`AccessDeniedException ... is not authorized to perform:
  bedrock:InvokeModel`** → the inline policy didn't attach to the
  user, or the `Resource` ARN doesn't match the region you're
  invoking against. Re-open the user in IAM, confirm the policy
  is listed, and re-check the region in both the policy ARN and the
  CLI flag.
- **`SignatureDoesNotMatch`** → wrong Access Key ID / Secret pair.
  Re-paste from the IAM "Retrieve access keys" download (or
  generate a new key if you've lost the secret).
- **Empty model list / `ValidationException` mentioning region** →
  Bedrock isn't offered in the region you picked. Switch to
  `us-east-1` or `us-west-2`.

If you'd rather set up a named profile instead of pasting env-vars
each test, that works too:

```bash
aws configure --profile graphrag-bedrock
# paste Access Key ID + Secret + region (e.g. us-west-2) + json
aws --profile graphrag-bedrock bedrock-runtime invoke-model --region us-west-2 --model-id cohere.embed-english-v3 --content-type application/json --accept '*/*' --cli-binary-format raw-in-base64-out --body '{"texts":["hello"],"input_type":"search_document"}' /tmp/embed-test.json && jq '.embeddings[0] | length' /tmp/embed-test.json
```

---

## 7. Domain and DNS setup

The stack needs a base domain you control, plus the ability to add
two A-records under it (one apex, one wildcard).

### Pick a base domain

- **Graphwise field SEs:** Kent owns `semantic-proof.com` — email
  him with the subdomain you want and the EIP from `terraform apply`,
  he adds the records via the GoDaddy console. You don't need a
  GoDaddy account.
- **Everyone else:** any domain you control with any DNS provider.
  This guide uses GoDaddy because that's what Graphwise uses; the
  steps are equivalent on Route53 / Cloudflare / Namecheap.

If you don't have a domain yet, GoDaddy or any registrar works. Pick
something short — every per-app subdomain is `<app>.<sub>.<base>`,
so a long base domain becomes painful.

### Pick a subdomain

Convention: lowercase, no dots, hyphens OK. Examples: `scott`,
`acme-corp`, `myname-demo`. The full apex becomes
`<sub>.<base>`, e.g. `myname-demo.example.com`.

### Sketch the DNS plan (don't add records yet)

You'll need two A-records, both pointing at the EC2 Elastic IP that
Terraform allocates:

| Name | Type | Points to | TTL |
|---|---|---|---|
| `<sub>.<base>` | A | `<EIP from terraform apply>` | 5 min |
| `*.<sub>.<base>` | A | `<same EIP>` | 5 min |

The wildcard is critical — without it, only the apex resolves and
every per-app subdomain (`poolparty`, `auth`, `graphrag`, …)
returns NXDOMAIN.

You add the records **after** `terraform apply` (you don't have the
EIP yet). The post-apply runbook in
[infra/README.md](infra/README.md) walks the GoDaddy steps.

---

## 8. EC2 key pair

You need an SSH key pair to log into the deployed instance.
Terraform references it by name; AWS holds the public half, you
hold the private `.pem`.

1. AWS Console → EC2 → Network & Security → **Key Pairs** → Create
   key pair.
2. Name it something memorable (e.g. `graphwise-stack`).
3. Type: **RSA** or **ED25519** — both work. Format: **`.pem`**.
4. Save the downloaded file somewhere safe — you can never download
   it again.

Lock it down:

**macOS / Linux:**

```bash
mv ~/Downloads/graphwise-stack.pem ~/.ssh/
chmod 400 ~/.ssh/graphwise-stack.pem
```

**Windows:** PowerShell:

```powershell
Move-Item ~\Downloads\graphwise-stack.pem ~\.ssh\
icacls ~\.ssh\graphwise-stack.pem /inheritance:r
icacls ~\.ssh\graphwise-stack.pem /grant:r "$($env:USERNAME):(R)"
```

The path you note here is what you'll paste into
`terraform.tfvars` as `key_pair_name` (the name only, not the
path), and into the `ssh -i <path>` commands later.

### Export the key path so SSH/SCP commands stay short

The deploy walkthrough has a lot of `ssh -i …` and the
`scripts/laptop/{push,pull}-*.sh` helpers take `--key`. Export
once in your shell rc so you don't paste the path every time:

**macOS / Linux** (`~/.zshrc` or `~/.bashrc`):

```bash
export GRAPHWISE_KEY=~/.ssh/graphwise-stack.pem
# Optional -- once Terraform is applied, set this to your EIP or
# subdomain so the laptop helpers can drop --host too.
# export GRAPHWISE_HOST=stroker.semantic-proof.com
```

**Windows** (PowerShell profile, `$PROFILE`):

```powershell
$env:GRAPHWISE_KEY = "$HOME\.ssh\graphwise-stack.pem"
# $env:GRAPHWISE_HOST = "stroker.semantic-proof.com"
```

After reloading the shell, `scripts/laptop/push-to-ec2.sh` and
`pull-from-ec2.sh` honor `GRAPHWISE_KEY` and `GRAPHWISE_HOST` as
defaults, so you can run them with just the operation-specific
flags. SSH/SCP itself doesn't read these env vars — for those, an
`~/.ssh/config` entry is the cleaner pattern:

```
Host graphwise
    HostName stroker.semantic-proof.com
    User graphwise
    IdentityFile ~/.ssh/graphwise-stack.pem
```

Then `ssh graphwise` and `scp foo graphwise:bar` Just Work.

---

## 9. Find your laptop's public IP

Terraform restricts SSH ingress to the IP you're connecting from
(prevents anyone-on-the-internet from probing port 22).

```bash
curl -4 https://icanhazip.com
```

Note that value — you'll write it into `terraform.tfvars` as
`admin_cidr = "<your.public.ip>/32"`.

Caveats:

- If your IP changes (Wi-Fi roaming, ISP rotation), SSH will start
  failing. Re-run the curl, edit `terraform.tfvars`, run
  `terraform apply` to update the security group rule.
- If you're on a corporate VPN, the IP is the VPN egress, which is
  shared. That's usually fine for a demo.

---

## 10. Optional — local Podman

You **don't** need Podman on your laptop. The EC2 instance does the
container work. Install it only if you want to:

- Pull `ontotext/poolparty-keycloak` locally to inspect or extract a
  realm export before you've got an EC2 instance.
- Build / test container images against the same engine the cluster
  uses.

**macOS:**

```bash
brew install podman
podman machine init
podman machine start
podman info
```

**Windows:**

```powershell
choco install podman-cli -y
podman machine init
podman machine start
```

If you're not sure you need it, skip — you can always come back.

### Podman remote access (advanced, optional)

Podman supports running its CLI locally while the actual containers
run on a remote host over SSH. Useful for browsing the EC2 instance's
containers without SSHing in interactively. Sketch:

```bash
podman system connection add graphwise-ec2 --identity ~/.ssh/graphwise-stack.pem ssh://ec2-user@<eip>
podman --connection graphwise-ec2 ps
```

Skip unless you have a specific reason — `ssh ec2-user@<eip>
'podman ps'` is simpler.

---

## 11. Graphwise registry credentials and license files

The GraphRAG container images live behind `maven.ontotext.com`
(private). License files for PoolParty, GraphDB, and UnifiedViews
are not in this repo. You need both before the stack can come up,
and you need to get both from Graphwise.

> **Set expectations: these are not free downloads.** Graphwise
> registry credentials and license keys are gated commercial
> assets. They are issued to:
>
> - **Paying customers** with an active Graphwise subscription —
>   creds and licenses come bundled with your contract; your
>   account manager or the customer portal is the source.
> - **Vetted evaluation engagements** — typically scoped to a
>   named customer or partner project, with a time-bounded
>   evaluation license. Expect a sales conversation, not a sign-up
>   form.
> - **Internal Graphwise field use** (presales SEs, demo
>   environments) — provisioned through internal channels.
>
> If you don't fit one of those categories, this stack will not
> deploy in a working state — you'll get `ImagePullBackOff` on
> every GraphRAG pod and `License invalid` on every PoolParty /
> GraphDB / UnifiedViews container. Open-source alternatives
> exist for some pieces (RDF4J, GraphDB Free) but the chart isn't
> wired for that path.
>
> Start the conversation early — turnaround for evaluation
> licenses is typically days, not minutes.

### Who to contact

- **Existing Graphwise customer:** your account manager / customer
  success contact.
- **Prospective customer (evaluation):** Graphwise Sales —
  https://graphwise.ai/contact/ or whoever's been emailing you about
  the trial.
- **Graphwise field SE / partner:** internal channel (Slack /
  Teams), or `support@graphwise.ai` with your role context.

### Maven registry credentials

Once provisioned, you'll get a username and password for
`maven.ontotext.com`. You'll write these to two files **on the EC2
instance** later:

```
~/.ontotext/maven-user
~/.ontotext/maven-pass
```

The `cluster-bootstrap.sh` script reads them and creates the
`graphwise` Kubernetes image-pull Secret in the `graphwise` and
`graphrag` namespaces. For now, just keep the values somewhere
you'll find when you SSH in.

> **Don't confuse this with the n8n credentials.** Graphwise issues
> at least three separate credential strings: the **Maven user/pass**
> here (pulls private container images), an **n8n Enterprise
> license activation key** that activates the n8n workflow engine
> inside the chart, and an **n8n encryption key** that n8n uses
> internally to encrypt stored connections in its DB. The Maven
> creds are the only ones you write to `~/.ontotext/`; the n8n
> license goes into `charts/graphwise-stack/values.yaml` later
> (see [DEPLOY "Configure GraphRAG runtime credentials"](DEPLOY.md#7-configure-graphrag-runtime-credentials));
> and the n8n encryption key is **auto-generated by Terraform** —
> you don't have to do anything for that one.

### License files

You'll be sent three vendor-specific files: **PoolParty**,
**GraphDB**, and **UnifiedViews**. They're typically tied to your
account / engagement and include an expiration date — note when
yours expire so the stack doesn't silently fall over weeks later.

Standard filenames the chart expects:

```
files/licenses/poolparty.key
files/licenses/graphdb.license
files/licenses/uv-license.key
```

You'll `scp` these into place on the EC2 instance later. Keep them
on your laptop for now in a folder you remember.

---

## 12. You're done — what's next

At this point you have:

- Terraform on `PATH`, AWS CLI authenticated as a non-root IAM user.
- Bedrock available in your region (`cohere.embed-english-v3`
  reachable — no per-model approval needed), plus a least-privilege
  IAM user `graphrag-bedrock` with its access key in your password
  manager / scratch file.
- An EC2 key pair `.pem` `chmod 400`'d.
- A subdomain plan (`<sub>.<base>` apex + `*.<sub>.<base>` wildcard
  records) you'll add to GoDaddy after `terraform apply`.
- Your laptop's public IP for `admin_cidr`.
- Maven creds and three license files on hand.

Continue with:

- **[infra/README.md](infra/README.md)** — `terraform init`, `plan`,
  `apply`. Provisions the EC2 instance, SG, and EIP. Cloud-init
  finishes the OS bootstrap and brings up the KIND cluster.
- **[DEPLOY.md §Deploy from zero](DEPLOY.md#deploy-from-zero)** —
  the post-Terraform steps: DNS records, SSH in, drop creds and
  licenses, run `cluster-bootstrap.sh` and `reset-helm.sh`.

If something on this page didn't work, the typical failure modes
are:

- `aws sts get-caller-identity` returns root → IAM user not created
  / wrong profile selected.
- Bedrock invoke returns `AccessDeniedException` → IAM user is
  missing `bedrock:InvokeModel` on the model, or you're hitting the
  wrong region.
- `dig` not on Windows → install `bind-toolsonly` or use
  `nslookup`.
- Homebrew install hangs → corporate firewall or VPN; try off-VPN.
