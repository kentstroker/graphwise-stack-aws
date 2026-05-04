# Graphwise Stack — Laptop Setup Guide

**Maintainer:** Kent Stroker
**Audience:** Anyone standing up the Graphwise Stack on a fresh
laptop, from scratch.

This document covers everything that happens **on your laptop and in
third-party accounts** before the first `terraform apply`. By the end
you will have:

- A working terminal with Homebrew (macOS) or Chocolatey (Windows).
- AWS CLI installed and authenticated.
- **Two IAM users** in your AWS account:
  - A **Terraform user** (e.g. `terraform-demo`) with
    `AmazonEC2FullAccess`, used from your laptop to run
    `terraform apply`.
  - A **Bedrock user** (e.g. `graphrag-bedrock`) with a narrow
    inline policy granting `bedrock:InvokeModel` on
    `cohere.embed-english-v3`, used at runtime by the
    `graphrag-components` pod on the EC2 host.
- AWS Bedrock available in your region (no per-model approval
  needed — AWS now grants foundation-model access by default).
- Terraform installed and on `PATH`.
- Python 3 + pip + PyYAML installed (used by the laptop-side
  push-config.sh / pull-config.sh helpers for YAML splicing
  and auto-migration).
- An EC2 key pair downloaded and `chmod 400`'d.
- A base domain whose DNS is hosted in Route 53 in this same AWS
  account (registered through Route 53 is simplest). cert-manager
  needs zone-write access for DNS-01 wildcard cert issuance.
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

### rsync (used for ingest-data uploads to the EC2)

Modern macOS may ship without GNU rsync (Apple replaced the bundled
one with `openrsync` in Ventura+, which has compatibility quirks).
Install GNU rsync via Homebrew so multi-GB ingest uploads work
cleanly with `-z` compression and `-P` resume:

**macOS:**

```bash
brew install rsync
rsync --version | head -1
```

**Windows:**

```powershell
choco install rsync -y
rsync --version
```

Want at least rsync 3.x. If you'd rather not install it, `scp` is
the documented fallback in DEPLOY §3.5 — fine for one-off file
drops, painful for multi-GB transfers (no resume, no compression).

### Python 3 + pip + PyYAML (laptop-side helper scripts)

`scripts/laptop/push-config.sh` and `scripts/laptop/pull-config.sh`
parse YAML on the laptop (n8n encryption-key splice, wildcard cert
summary, auto-migration of Bedrock + n8n license values from chart
values.yaml into the secrets overlay). They use Python 3 + the
`yaml` module (PyYAML). The scripts fail-fast at startup with a
clear remediation if PyYAML is missing.

**macOS:**

```bash
brew install python3
python3 --version
pip3 install --user pyyaml
python3 -c "import yaml; print('PyYAML', yaml.__version__)"
```

If `pip3 install --user` fails with "externally-managed-environment"
(PEP 668; some Homebrew setups since Python 3.12 disable user-site
pip installs), use one of:

```bash
# Recommended: Homebrew's pip with --break-system-packages (the
# package is small and PyYAML is heavily-tested -- low risk):
/opt/homebrew/bin/pip3 install --break-system-packages pyyaml

# Or: a per-user virtualenv (more hygienic but adds an activation step):
python3 -m venv ~/.venv-graphwise && source ~/.venv-graphwise/bin/activate
pip install pyyaml
# Then add `source ~/.venv-graphwise/bin/activate` to your shell rc
# so push-config.sh / pull-config.sh always run inside the venv.
```

**Windows:**

```powershell
choco install python -y
python --version
pip install pyyaml
python -c "import yaml; print('PyYAML', yaml.__version__)"
```

Want at least Python 3.9. The PyYAML version doesn't matter (any
release from the last decade works); the latest stable is fine.

### Clone the graphwise-stack-aws repo to your laptop

You need this repo on your laptop disk to run `terraform apply`,
edit `terraform.tfvars`, and use the laptop-side helper scripts.
Pick a folder you'll remember (`~/code/`, `~/work/`, wherever your
other projects live):

```bash
mkdir -p ~/code && cd ~/code
git clone https://github.com/kentstroker/graphwise-stack-aws.git
cd graphwise-stack-aws
```

Verify:

```bash
ls infra/terraform        # should list main.tf, variables.tf, outputs.tf, terraform.tfvars.example
```

> **The EC2 host gets its own copy.** Cloud-init clones the repo to
> `~/graphwise-stack-aws` on the EC2 instance during first boot
> (using the `github_repo_url` variable, which defaults to the
> public upstream). You don't need to scp the repo over — the EC2
> copy and the laptop copy are independent. The laptop copy is for
> running Terraform; the EC2 copy is for running the
> `cluster-bootstrap.sh` / `reset-helm.sh` / `install-licenses.sh`
> scripts.

Forks: if you've forked the repo for customization, clone YOUR fork
here, and set `github_repo_url` in `terraform.tfvars` to your
fork's HTTPS URL so cloud-init clones the same source on the EC2.

---

## 4. AWS account setup

Skip the "Sign up" subsection if you already have an AWS account.

> **⚠️ Who performs each step in this guide.** IAM operations (create
> users, attach policies, generate access keys) require IAM admin
> permissions that the users you're creating do **not** themselves
> hold — a brand-new IAM user can't grant itself permissions. Read
> the actor table below before clicking anything.
>
> | Step | Performed by | Why |
> |---|---|---|
> | §4 — create §4a Terraform user, §4b Bedrock user, attach **all** policies (managed `AmazonEC2FullAccess`, scoped inline `graphwise-stack-iam`, scoped inline Bedrock policy), generate access keys | **Root user** (the email you signed up with) **OR** an existing IAM admin user (`AdministratorAccess` or `IAMFullAccess`) | Only IAM admins can create users and attach policies. `terraform-demo` doesn't exist yet at this point, and after creation it has only `AmazonEC2FullAccess` — no IAM rights at all (so it can't grant itself the inline IAM policies it needs in §4a / §9). |
> | §5 verify steps (`aws sts get-caller-identity`, `aws ec2 describe-vpcs`, `aws bedrock-runtime invoke-model`) | The user whose creds are loaded — `terraform-demo` (default profile) for §4a verify, `graphrag-bedrock` (env-vars) for §4b verify | These are read-only / runtime-API checks that the freshly-created users *do* have permission to run. |
> | Everything else (Terraform applies, EIP allocation, key-pair creation, billing alarm, EC2 ops) | The IAM user whose creds you've loaded into `aws configure` (typically `terraform-demo`) — uses `AmazonEC2FullAccess` | Plain EC2 / general AWS work, scoped to what `terraform-demo` was granted. |
>
> **Best practice for new accounts:** sign in to the Console as root
> exactly **once** to do (a) §4a + §4b user creation, and (b) create
> a separate **IAM admin user** with `AdministratorAccess`. Then
> enable MFA on root, lock root credentials away, and never use
> root again. From then on every IAM-admin operation in this guide
> uses the IAM admin user (same Console clicks; just signed in
> differently). AWS docs walk the IAM-admin-user pattern in detail
> at https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started_create-admin-group.html.

### Sign up

Go to https://aws.amazon.com/ → "Create an AWS account". You'll
need a credit card (you'll be charged for the EC2 instance — see
the README cost notes).

### 4a. Create the Terraform IAM user

This is the IAM user that runs `terraform apply` from your laptop.
Two reasons it's not your root account:

- **Blast radius.** Root has unlimited power; if its credentials leak,
  the whole AWS account is compromised. A Terraform user can be
  scoped to just the EC2 / EIP / SG / IAM resources this stack needs,
  and revoked independently.
- **Auditability.** CloudTrail entries that show "user: root" are
  useless. "user: terraform-demo" tells you immediately which path
  produced the action.

The example name in this guide is **`terraform-demo`** — pick whatever
you like, but use a name that signals "this is the Terraform-driving
user" so you don't confuse it with the Bedrock user in §4b. Other
common conventions: `graphwise-stack-admin`, `iac-deploy`,
`terraform-<your-name>`.

> **Console-only walkthrough.** This entire section is click-through
> in the AWS Console — no CLI commands until §5 (which sets up the
> AWS CLI). If you'd rather script user creation, the
> CLI-equivalents and verify commands live in §5 → "CLI equivalents
> (optional, scripters only)" and "Verify your IAM users".

#### Create the user

1. Open IAM: https://console.aws.amazon.com/iamv2/home → **Users** in
   the left nav → **Create user** (top-right button).
2. **User name:** `terraform-demo` (or your chosen name).
3. **Provide user access to the AWS Management Console:** leave
   **unchecked**. This user is API-only — no console password, no
   MFA prompt to manage.
4. Click **Next**.
5. **Permissions options:** select **Attach policies directly**.
6. In the policy search box, type `AmazonEC2FullAccess`. Tick the
   checkbox next to it. **Do not attach `AdministratorAccess`** —
   over-permissive, defeats the point of a separate user.
7. Click **Next** → **Create user**.

#### Attach scoped IAM permissions for the EC2 instance role

Terraform creates a small IAM role + instance profile so the EC2
host can talk to Route 53 (cert-manager writes `_acme-challenge`
TXT records there for DNS-01 wildcard cert issuance — see
[CLAUDE.md "Why letsencrypt-prod only"](CLAUDE.md)).
`AmazonEC2FullAccess` does **not** include `iam:*`, so without this
extra inline policy `terraform apply` and `terraform destroy` both
fail with `AccessDenied: iam:CreateRole` /
`iam:ListInstanceProfilesForRole`.

Scoped to **only** role + instance-profile names matching
`graphwise-stack-*`. `terraform-demo` still can't touch any other
IAM resources in the account.

1. Same flow as the EC2 Instance Connect inline policy in §9 (root
   or IAM admin per §4 actor table). IAM Console → Users →
   `terraform-demo` → **Permissions** tab → **Add permissions** →
   **Create inline policy** → **JSON** tab.
2. Paste the policy below.
3. **Next** → **Policy name:** `graphwise-stack-iam` → **Create policy**.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageEC2InstanceRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:UpdateRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRoleTags",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::*:role/graphwise-stack-*",
        "arn:aws:iam::*:instance-profile/graphwise-stack-*"
      ]
    }
  ]
}
```

After this, `terraform-demo` can create / destroy the role +
instance profile that Terraform's `infra/terraform/main.tf` defines,
and can `iam:PassRole` it to `aws_instance.stack` at launch time.
Nothing more.

#### Create an access key

The Terraform user needs an access key for `aws configure` in §5 to
authenticate against.

1. Click into the new user → **Security credentials** tab → scroll to
   **Access keys** → **Create access key**.
2. **Use case:** select **Application running outside AWS** → Next.
3. (Optional) tag the key with a description like `terraform-laptop-2026-05`.
4. **Create access key.**
5. Save **both** the Access Key ID and Secret Access Key right now —
   AWS shows the secret exactly once. Drop them in 1Password / your
   password manager. You'll paste them into `aws configure` in §5.

#### Rotating the access key (later operation)

AWS recommends rotating access keys every 90 days. The two-active-key
swap pattern avoids downtime:

1. **Console:** Security credentials → Access keys → **Create access
   key** (a user can hold two simultaneously).
2. Update `aws configure` (or your `~/.aws/credentials` file) with
   the new pair.
3. Verify the new key with `aws sts get-caller-identity`.
4. Mark the old key **Inactive** in the Console (don't delete yet).
5. After 24-48 hours of normal use with no errors, **delete** the old
   key.

The Console shows last-used timestamps under Security credentials →
Access keys, so you can confirm an "inactive" key is genuinely unused
before deletion.

### 4b. Create the Bedrock IAM user

This is a **separate, dedicated IAM user** from §4a. The split exists
because the two users carry credentials with very different blast
radii:

- **§4a (Terraform user):** holds infrastructure-provisioning power
  (create/destroy EC2, IAM roles, SGs). Lives only on your laptop.
- **§4b (Bedrock user):** holds runtime credentials that get baked
  into a Helm Secret on the EC2 host and read by the
  `graphrag-components` pod every time it embeds a query. Lives on
  the EC2 instance.

Putting both in one user means Bedrock-pod credentials would also
let an attacker create EC2 instances. Splitting them caps blast
radius: leaked Bedrock creds can only invoke the embedding model on
your account; leaked Terraform creds can't be used for runtime
embedding.

#### Pick the Bedrock region

The `graphrag-secrets.awsCredentials.region` value defaults to
`us-east-1` in `charts/graphwise-stack/values.yaml`. `us-east-1` and
`us-west-2` have the broadest model catalog. If you change the region
here, change it in the chart values too — the EC2 instance region
(`terraform.tfvars`) and the Bedrock region don't have to match, but
both must be valid Bedrock regions.

> **Bedrock model access is now default-on.** AWS used to gate each
> foundation model behind a per-account "Modify model access" approval
> flow. That flow is gone — `cohere.embed-english-v3` is reachable in
> any Bedrock-enabled region as long as the IAM identity has
> `bedrock:InvokeModel` on its ARN. Nothing to request, nothing to
> wait for.

> **Console-only walkthrough.** Same as §4a — no CLI commands until
> §5. Verify and the optional CLI equivalents are in §5.

#### Create the user

1. IAM: https://console.aws.amazon.com/iamv2/home → **Users** →
   **Create user**.
2. **User name:** `graphrag-bedrock` (or per-deployment, e.g.
   `graphrag-bedrock-stroker`).
3. **Provide user access to the AWS Management Console:** leave
   **unchecked**. API-only.
4. Click **Next**.
5. **Permissions options:** select **Attach policies directly**.
6. **Don't attach a managed policy.** `AmazonBedrockFullAccess` would
   work but it grants more than we need; the inline policy below is
   narrower (one model, two actions).
7. Click **Next** → **Create user**.

#### Attach an inline policy scoped to the embedding model

1. Click into the new user → **Add permissions** → **Create inline
   policy**.
2. Switch to the **JSON** tab.
3. Paste:

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

4. If your Bedrock region isn't `us-west-2`, change it in the
   `Resource` ARN. The empty segment between the two `::` is correct
   — foundation-model ARNs have no account-id component.
5. Click **Next**.
6. **Policy name:** `bedrock-cohere-invoke`.
7. **Create policy.**

#### Create an access key

1. The new user's page → **Security credentials** tab → **Create
   access key**.
2. **Use case:** **Application running outside AWS** → Next.
3. **Create access key.**
4. Save **both** the Access Key ID and Secret Access Key into your
   password manager. AWS only shows the secret once.

#### Where these credentials get used

You'll edit them into the umbrella chart's values file **on the EC2
instance** later in [DEPLOY → Configure GraphRAG runtime credentials](DEPLOY.md#7-configure-graphrag-runtime-credentials):

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

> **Don't edit values.yaml on your laptop and commit it.** The shipped
> file holds placeholder values
> (`REPLACE_WITH_REAL_AWS_ACCESS_KEY_ID`); committing your real
> credentials publishes them to the public repo. Keep the edit local
> to the EC2 host.

The umbrella chart materializes the values into a Kubernetes Secret
named `graphrag-components-aws-credentials` in the `graphrag`
namespace, which the `graphrag-components` pod mounts at runtime.

#### Rotating the Bedrock access key (later operation)

Same two-key swap as §4a, but the rotation requires a Helm upgrade
because the credentials live in a Kubernetes Secret on the EC2:

1. Create a new access key for `graphrag-bedrock`.
2. SSH to the EC2 → edit `charts/graphwise-stack/values.yaml` →
   replace the `accessKeyId` / `secretAccessKey` under `graphrag-secrets.awsCredentials`.
3. `helm upgrade graphwise-stack ./charts/graphwise-stack -n graphwise -f ...` to roll the Secret.
4. Restart the `graphrag-components` pod so it picks up the new Secret:
   `kubectl rollout restart deploy/graphrag-components -n graphrag`.
5. Confirm with a chatbot prompt — if it returns embeddings, the new
   key is in use; if `AccessDenied`, the rollout didn't take.
6. Mark the old key Inactive, then delete after 24-48 hours of clean
   operation.

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

Paste the Access Key ID + Secret Access Key from §4a. For region,
pick one with current Amazon Linux 2023 ARM64 AMIs — every major
region (`us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`,
`eu-central-1`) works. Output format: `json`.

Verify:

```bash
aws sts get-caller-identity
```

You should see your account number and the ARN of the §4a Terraform
user (e.g. `terraform-demo`). If you see `arn:aws:iam::...:root`,
you're authenticated as root — go back and create the IAM user.

### SSO instead (if your org uses it)

```bash
aws configure sso
```

Walks you through a browser login. End result: same as `aws
configure` but with rotating tokens. `aws sts get-caller-identity`
still verifies.

### Verify your IAM users

Now that the AWS CLI is configured, run the two verify checks for the
users you created in §4. **Both must pass before §6.**

#### Verify §4a Terraform user

```bash
aws sts get-caller-identity
```

Expected: a JSON blob with `"Arn": "arn:aws:iam::<account>:user/terraform-demo"`.
If you see `:root`, you're authenticated as root — `aws configure`
picked up the wrong credentials.

```bash
aws ec2 describe-vpcs --max-items 1 --region <your-region>
```

Expected: a JSON blob describing one VPC. If you get
`UnauthorizedOperation`, the `AmazonEC2FullAccess` policy didn't
attach in §4a — re-check the user's Permissions tab in the Console.

#### Verify §4b Bedrock user

The Bedrock user is **not** your default profile (your default points
at the §4a Terraform user). Pass its credentials directly via env-vars
for this one-shot test:

```bash
AWS_ACCESS_KEY_ID='<paste-bedrock-access-key-id>' AWS_SECRET_ACCESS_KEY='<paste-bedrock-secret-access-key>' AWS_DEFAULT_REGION=us-west-2 aws bedrock-runtime invoke-model --model-id cohere.embed-english-v3 --content-type application/json --accept '*/*' --cli-binary-format raw-in-base64-out --body '{"texts":["hello"],"input_type":"search_document"}' /tmp/embed-test.json && jq '.embeddings[0] | length' /tmp/embed-test.json
```

`--cli-binary-format raw-in-base64-out` is required because AWS CLI
v2 expects `--body` to be base64-encoded by default and otherwise
rejects the literal JSON with `Invalid base64`.

Expected output: a number around `1024` (the embedding dimension).

Common failures:

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDeniedException ... is not authorized to perform: bedrock:InvokeModel` | Inline policy didn't attach in §4b, or the `Resource` ARN region doesn't match the region you're invoking against | Re-open the user → Permissions tab, confirm `bedrock-cohere-invoke` is listed. Re-check region in both the policy ARN and the CLI flag. |
| `SignatureDoesNotMatch` | Wrong Access Key ID / Secret pair | Re-paste from password manager, or generate a new key in the Console if you've lost the secret. |
| `ValidationException` mentioning region | Bedrock isn't offered in the region you picked | Switch to `us-east-1` or `us-west-2`. |
| `UnrecognizedClientException` | Access key was disabled or deleted in IAM | Re-check the user → Security credentials → Access keys is **Active**. |

If you'd rather set up a named profile for the Bedrock user instead of
pasting env-vars each test:

```bash
aws configure --profile graphrag-bedrock
# paste Access Key ID + Secret + region (e.g. us-west-2) + json
aws --profile graphrag-bedrock bedrock-runtime invoke-model --region us-west-2 --model-id cohere.embed-english-v3 --content-type application/json --accept '*/*' --cli-binary-format raw-in-base64-out --body '{"texts":["hello"],"input_type":"search_document"}' /tmp/embed-test.json && jq '.embeddings[0] | length' /tmp/embed-test.json
```

### A note on CLI alternatives for §4 IAM operations

§4 is **deliberately Web UI only**. CLI equivalents (`aws iam
create-user`, `aws iam put-user-policy`, etc.) require IAM admin
rights — `IAMFullAccess` or broader. The user whose credentials you
just loaded into `aws configure` is `terraform-demo`, which carries
only `AmazonEC2FullAccess` and **cannot** run those commands.
Attempting them produces `AccessDenied: ... not authorized to
perform: iam:CreateUser`.

If you have a separate AWS admin (or are willing to use root one
more time) and prefer to script user creation, the AWS CLI reference
documents the equivalent commands — but treat that as a parallel,
non-default workflow this guide doesn't walk through. The Web UI
path in §4 is the supported path.

### Quick reference — §5 commands in order

For convenience, here are the CLI commands from §5 in execution
order. Sanity-check that you have the expected access keys saved
before running them.

```bash
# 1. Configure default AWS CLI profile with §4a Terraform user creds
aws configure
# (paste §4a Access Key ID + Secret + region + json)

# 2. Verify §4a Terraform user (runs as terraform-demo via default profile)
aws sts get-caller-identity                                          # must show user/terraform-demo
aws ec2 describe-vpcs --max-items 1 --region <your-region>           # must NOT return UnauthorizedOperation

# 3. Verify §4b Bedrock user (env-vars; default profile stays §4a)
AWS_ACCESS_KEY_ID='<bedrock-access-key-id>' AWS_SECRET_ACCESS_KEY='<bedrock-secret-access-key>' AWS_DEFAULT_REGION=us-west-2 aws bedrock-runtime invoke-model --model-id cohere.embed-english-v3 --content-type application/json --accept '*/*' --cli-binary-format raw-in-base64-out --body '{"texts":["hello"],"input_type":"search_document"}' /tmp/embed-test.json && jq '.embeddings[0] | length' /tmp/embed-test.json
# Expected: number around 1024
```

If both verify steps pass, §4 + §5 are done — continue to §6
(domain + DNS). If either fails, see the failure-modes list at the
end of §11 and the §4 actor table for who needs to fix what.

---

## 6. Domain and DNS setup

The stack needs a base domain whose DNS is hosted in **Route 53 in this same AWS account**. cert-manager writes `_acme-challenge` TXT records into the hosted zone for DNS-01 wildcard cert issuance, authenticated via the EC2 instance role (Phase 2 wiring) — this only works if the zone lives in the same account.

### Pick a base domain

- **Graphwise field SEs:** Kent owns `semantic-demo.com` — registered through Route 53, hosted zone is in the Graphwise demo AWS account. Email him with the subdomain you want; he adds the records via the AWS Console. (`semantic-proof.com` was retired in May 2026; if you see references to it in older notes, that's why.)
- **Everyone else:** any domain you control whose DNS is hosted in Route 53 in the same AWS account that runs this stack. Two paths to get there:
  - **Register via Route 53.** Route 53 → Registered domains → Register domain. Hosted zone is auto-created on registration; nameservers are already authoritative on AWS, no delegation step.
  - **Use an existing domain.** Create a Route 53 hosted zone for it; copy the 4 NS records AWS assigns into your registrar's nameserver settings; wait 1-24 hours for NS propagation.

If you don't have a domain yet, registering through Route 53 is the simplest path (no NS-delegation step). Pick something short — every per-app subdomain is `<app>.<sub>.<base>`, so a long base domain becomes painful.

### Capture the hosted zone ID

`terraform.tfvars` needs the hosted zone ID (looks like `Z01234567ABCDEFGHIJK`). Get it once:

```bash
aws route53 list-hosted-zones --query 'HostedZones[?Name==`<your-base-domain>.`].Id' --output text | sed 's|/hostedzone/||'
```

The trailing dot in the query is required — Route 53 stores zone names with a trailing dot. Save the output for `route53_zone_id` in `terraform.tfvars`.

### Pick a subdomain

Convention: lowercase, no dots, hyphens OK. Examples: `scott`,
`acme-corp`, `myname-demo`. The full apex becomes
`<sub>.<base>`, e.g. `myname-demo.example.com`.

### Pre-allocate the Elastic IP (strongly recommended)

> **Why this matters.** Terraform's default behaviour is to allocate
> a fresh EIP every `terraform apply` — and **release it on every
> `terraform destroy`**. That means every rebuild gets a new IP, and
> every rebuild requires updating your DNS records to match. We
> learned this the painful way: a single accidental destroy/recreate
> invalidated every DNS record and forced a full DNS-update +
> propagation wait before the stack could come back up.
>
> The fix is to allocate the EIP **outside Terraform** and pass its
> Allocation ID to the module via `existing_eip_allocation_id`.
> Terraform then only **associates** the existing EIP with the
> instance — destroy detaches but does not release. The IP stays
> stable across destroy/apply cycles, your DNS records are
> set-and-forget, and cert-manager's DNS-01 wildcard challenge succeeds on
> the very first apply because DNS already resolves.

You need to capture **two values** from this step:

- **Allocation ID** (`eipalloc-...`) — goes in `terraform.tfvars` as
  `existing_eip_allocation_id`.
- **Public IPv4 address** (e.g. `54.218.123.45`) — goes in your DNS
  A records (next subsection).

> **Allocation ID vs ARN.** The AWS Console also shows an ARN
> (`arn:aws:ec2:...:elastic-ip/eipalloc-...`) for the EIP. Terraform
> uses the **Allocation ID** (`eipalloc-...` only). Ignore the ARN.

#### Console path

1. AWS Console → EC2 → **Network & Security** → **Elastic IPs** →
   **Allocate Elastic IP address** (top-right button).
2. **Network Border Group:** leave at the default region (e.g.
   `us-west-2`).
3. **Public IPv4 address pool:** **Amazon's pool of IPv4 addresses**.
4. (Optional) Add a tag: `Key=Name, Value=graphwise-stack-<your-subdomain>-eip`
   so it's findable later.
5. **Allocate.**
6. From the resulting Elastic IPs list, **copy two values:**
   - **Allocated IPv4 address** — the public IP (save for DNS).
   - **Allocation ID** — `eipalloc-...` (save for `terraform.tfvars`).

#### CLI path (optional)

```bash
aws ec2 allocate-address --domain vpc --region <your-region>
```

Output JSON includes both `PublicIp` and `AllocationId`. Save both.

To tag for later findability:

```bash
aws ec2 create-tags --region <your-region> --resources eipalloc-0123abc... --tags Key=Name,Value=graphwise-stack-<your-subdomain>-eip
```

#### Cost note

Elastic IPs cost **~$3.60/month while not associated** with a
running instance, and **$0/month while associated**. So during
normal operation (instance running, EIP attached) it's free; if you
`terraform destroy` and leave the EIP allocated for a long time
without re-applying, you'll pay the idle rate until you re-attach
or release it.

To release later (when you're truly done with this deployment):

```bash
aws ec2 release-address --allocation-id eipalloc-0123abc... --region <your-region>
```

### Add the DNS records (now that you have the IP)

Two A-records in the Route 53 hosted zone, both pointing at the **Public IPv4** you captured above:

| Name | Type | Points to | TTL |
|---|---|---|---|
| `<sub>.<base>` | A | `<your-elastic-ip>` | 300s |
| `*.<sub>.<base>` | A | `<your-elastic-ip>` | 300s |

The wildcard is critical — without it, only the apex resolves and every per-app subdomain (`poolparty`, `auth`, `graphrag`, …) returns NXDOMAIN.

Add them **now**, before `terraform apply`. Route 53 propagation is near-instant (AWS is the authoritative nameserver), so cert-manager's DNS-01 challenge succeeds on the first try once the cluster comes up.

Single AWS CLI command to UPSERT both records (idempotent — safe to re-run):

```bash
ZONE_ID=$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`<your-base-domain>.`].Id' --output text | sed 's|/hostedzone/||') ; aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"<your-subdomain>.<your-base-domain>\",\"Type\":\"A\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"<your-elastic-ip>\"}]}},{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"*.<your-subdomain>.<your-base-domain>\",\"Type\":\"A\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"<your-elastic-ip>\"}]}}]}"
```

(Console alternative: Route 53 → Hosted zones → click your zone → Create record → twice, once for the apex name and once for `*` prefix.)

- **Graphwise field SEs:** email Kent the subdomain + the IPv4 address; he runs the AWS CLI command above.

Verify propagation before continuing:

```bash
dig +short <sub>.<base> poolparty.<sub>.<base>
```

Both should return your EIP within ~30s.

> **If you skip EIP pre-allocation** and let Terraform allocate a fresh EIP each apply, you don't have the IP at this point and DNS has to wait until after `terraform apply`. The post-apply runbook in [infra/README.md](infra/README.md) walks the slow path. Fast path (this section) is strongly recommended.

---

## 7. EC2 key pair

You need an SSH key pair to log into the deployed instance.
Terraform references it by name; AWS holds the public half, you
hold the private `.pem`.

### Create in the AWS Console

1. AWS Console → EC2 → Network & Security → **Key Pairs** → **Create
   key pair** (top-right).
2. **Name:** `graphwise-stack`. This name MUST match exactly what
   you'll later put in `terraform.tfvars` as `key_pair_name`. The
   `terraform output graphwise_env_exports` line also assumes this
   name (it builds `~/.ssh/<key_pair_name>.pem`); pick something
   else only if you have a reason.
3. **Type:** RSA or ED25519 — both work.
4. **Format:** `.pem` (NOT `.ppk`; `.ppk` is PuTTY's format and
   doesn't work with the `ssh` and `scp` commands this guide uses).
5. **Create key pair.** Browser downloads `graphwise-stack.pem` to
   `~/Downloads/` (or whatever your default is). **You can never
   download it again** — if you lose it, the only recovery is to
   create a new key pair, update `terraform.tfvars`, and rebuild.

### Move it into `~/.ssh/` and lock it down

The `~/.ssh/` directory is where every standard tool (`ssh`, `scp`,
`rsync`, `git`) looks for keys. Putting the file there with the
right permissions is what makes the rest of this guide's
single-line commands "just work".

**macOS / Linux:**

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
mv ~/Downloads/graphwise-stack.pem ~/.ssh/graphwise-stack.pem
chmod 400 ~/.ssh/graphwise-stack.pem
ls -la ~/.ssh/graphwise-stack.pem
```

The final `ls -la` should show `-r--------` (mode `400`,
read-only-by-owner). If `ssh` later complains
`UNPROTECTED PRIVATE KEY FILE`, the chmod didn't take — re-run it.

**Renamed during download?** If your browser saved it as
something other than `graphwise-stack.pem` (e.g.
`graphwise-stack (1).pem` after a re-download), rename in the same
move:

```bash
mv ~/Downloads/<actual-filename>.pem ~/.ssh/graphwise-stack.pem
chmod 400 ~/.ssh/graphwise-stack.pem
```

**Windows** (PowerShell):

```powershell
New-Item -ItemType Directory -Force ~\.ssh | Out-Null
Move-Item ~\Downloads\graphwise-stack.pem ~\.ssh\graphwise-stack.pem
icacls ~\.ssh\graphwise-stack.pem /inheritance:r
icacls ~\.ssh\graphwise-stack.pem /grant:r "$($env:USERNAME):(R)"
```

The `icacls` lines strip inherited permissions and grant only your
user account read access — the Windows equivalent of `chmod 400`.

### What feeds where

| Field | Value | Where it goes |
|---|---|---|
| Key pair **name** (in AWS Console) | `graphwise-stack` | `infra/terraform/terraform.tfvars` → `key_pair_name = "graphwise-stack"` |
| Key file **path** (on your laptop) | `~/.ssh/graphwise-stack.pem` | `GRAPHWISE_KEY` env var (next subsection) — and into `ssh -i <path>` everywhere |

### Export the deploy environment variables now

Every `ssh`, `scp`, and `rsync` command in the rest of this guide
(SETUP, QUICKSTART, DEPLOY, HOWITWORKS, CONSOLE-GUIDE) is written to
reference three shell variables. Set them once in your shell rc and
the commands paste cleanly without further substitution:

| Var | What | Example |
|---|---|---|
| `GRAPHWISE_KEY` | Absolute path to the `.pem` you just saved | `~/.ssh/graphwise-stack.pem` |
| `GRAPHWISE_HOST` | Your deployment hostname **or** Elastic IP. Either works for SSH; the apex hostname is friendlier once DNS is in place. | `stroker.semantic-proof.com` (or `54.149.12.34`) |
| `GRAPHWISE_USER` | SSH user on the EC2. Always `ec2-user` for this stack (AL2023 default). | `ec2-user` |

**macOS / Linux** (`~/.zshrc` or `~/.bashrc`):

```bash
export GRAPHWISE_KEY=~/.ssh/graphwise-stack.pem
export GRAPHWISE_HOST=stroker.semantic-proof.com   # or your EIP
export GRAPHWISE_USER=ec2-user
```

**Windows** (PowerShell profile, `$PROFILE`):

```powershell
$env:GRAPHWISE_KEY = "$HOME\.ssh\graphwise-stack.pem"
$env:GRAPHWISE_HOST = "stroker.semantic-proof.com"
$env:GRAPHWISE_USER = "ec2-user"
```

Reload the shell (`exec $SHELL` or just open a new terminal) and
verify:

```bash
echo "$GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST"
# Should print: /Users/you/.ssh/graphwise-stack.pem ec2-user@stroker.semantic-proof.com
```

You don't have a working host yet (Terraform hasn't run), but
exporting it now means you only do it once. After
`terraform apply`, set `GRAPHWISE_HOST` to your subdomain or EIP
and every subsequent command in the docs Just Works.

The `scripts/laptop/push-to-ec2.sh` and `pull-from-ec2.sh` helpers
also honor these three vars as defaults, so you can run them with
just the operation-specific flags.

If you'd prefer `ssh graphwise` / `scp foo graphwise:bar` (no
flags at all), an `~/.ssh/config` alias is the cleaner pattern:

```
Host graphwise
    HostName stroker.semantic-proof.com
    User ec2-user
    IdentityFile ~/.ssh/graphwise-stack.pem
```

The docs use the env-var form because it's transparent (every
command shows exactly what `ssh` is doing) and works on a fresh
laptop without an SSH config.

---

## 8. Find your laptop's public IP

Terraform restricts SSH ingress to the IP you're connecting from
(prevents anyone-on-the-internet from probing port 22).

```bash
curl -4 https://icanhazip.com
```

Note that value — you'll write it into `terraform.tfvars` as
`admin_cidr = "<your.public.ip>/32"`.

Caveats:

- If your IP changes (Wi-Fi roaming, ISP rotation), SSH will start
  failing. **Do not run an unscoped `terraform apply` to fix this.**
  See the next callout — and use one of the two safe paths below.
- If you're on a corporate VPN, the IP is the VPN egress, which is
  shared. That's usually fine for a demo.

> **⚠️ Never run unscoped `terraform apply` after the first
> provision.** The module's AMI lookup uses `most_recent = true`. Any
> time AWS publishes a refreshed Amazon Linux 2023 ARM64 AMI between
> applies (which is constantly), the next plan resolves a different
> AMI ID and Terraform will **force-replace the EC2 instance** —
> destroying the EBS root volume and every PVC on it — even though
> the change you actually wanted was something tiny like an SG
> ingress edit. Always read `terraform plan` output before applying;
> if you see `aws_instance.stack` being **destroyed and replaced**,
> abort and use one of the safer paths below. See
> [infra/README.md → Safety: never unscoped apply after first provision](infra/README.md#safety-never-unscoped-terraform-apply-after-first-provision).

#### Updating `admin_cidr` after an IP change — safe paths

**Path 1 (preferred): edit the SG rule directly in the AWS Console.**

1. AWS Console → EC2 → **Security Groups** → search for
   `graphwise-stack-<sub>-sg` → click into it.
2. **Inbound rules** tab → **Edit inbound rules**.
3. Find the SSH rule (port 22) → change Source to your new
   `<new-ip>/32` → **Save rules**.
4. SSH works again immediately. **Also update `terraform.tfvars`**
   with the new value so the next legitimate apply doesn't revert
   the change.

Zero blast radius — the EC2 instance is never touched. Drift cost:
the next `terraform plan` will show the SG ingress as
out-of-band-changed; once you've updated `terraform.tfvars` to
match, the diff disappears.

**Path 2: scoped `terraform apply -target`.** Only safe if you
read the plan output character by character first.

```bash
cd infra/terraform
$EDITOR terraform.tfvars                                     # update admin_cidr
terraform plan -target=aws_security_group.stack              # READ THIS OUTPUT
# If the plan shows ANYTHING beyond an in-place SG modification, abort.
# In particular, abort if aws_instance.stack appears.
terraform apply -target=aws_security_group.stack
```

`-target` scopes the apply to just that resource, but `most_recent`
AMI drift can still drag the EC2 in via dependency edges in some
edge cases — so the plan-read step is non-negotiable.

---

## 9. (Optional) EC2 Instance Connect

EC2 Instance Connect is an AWS-managed service that gives you SSH
into the instance without you having to manage your own
authorized_keys file. Two access methods, both at no extra cost:

| Method | Source IP | Needs SG change? | Best for |
|---|---|---|---|
| **CLI: `aws ec2-instance-connect ssh ...`** | Your laptop | **No** — your `admin_cidr` rule already allows it | Day-to-day SSH from your laptop, especially when you've forgotten which `.pem` to use |
| **Browser: Console "Connect" tab** | AWS's `EC2_INSTANCE_CONNECT` service IP range | **Yes** — manual one-time SG rule (Console-only) | Ad-hoc browser-based access from any device that can reach the AWS Console |

The CLI method is simpler and recommended; the browser method is a
nice-to-have for emergency access from a Chromebook / iPad / shared
machine.

### Method 1 (recommended): AWS CLI — `aws ec2-instance-connect ssh`

#### What it does

1. Calls AWS's `SendSSHPublicKey` API over HTTPS — pushes a
   temporary SSH public key to the instance metadata service. AWS
   removes the key automatically after 60 seconds.
2. Opens a normal SSH connection **from your laptop** to the
   instance, signed with your `.pem` — so the source IP is your
   laptop (already in `admin_cidr` from §8). No SG change needed.

#### Run it

```bash
# On laptop -- replace instance-id and private-key-file with your values
aws ec2-instance-connect ssh \
  --instance-id i-0abcdef0123456789 \
  --private-key-file ~/.ssh/graphwise-stack.pem
```

Drops you into a shell on the instance as `ec2-user`. Same as a
plain `ssh -i ...`, just with the AWS API push first.

Look up the instance ID with:

```bash
# On laptop
terraform -chdir=infra/terraform output -raw instance_id
```

#### IAM permissions

Your IAM principal needs `ec2-instance-connect:SendSSHPublicKey`
on the instance plus `ec2:DescribeInstances` (covered by
`AmazonEC2FullAccess` from §4a). The Instance Connect action is
**not** included in `AmazonEC2FullAccess` — if the command fails
with `AccessDenied: ... ec2-instance-connect:SendSSHPublicKey`,
attach this small inline policy to your `terraform-demo` user via
the Console (root or IAM admin per §4 actor table):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ec2-instance-connect:SendSSHPublicKey",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "ec2:osuser": "ec2-user"
        }
      }
    }
  ]
}
```

Name it `ec2-instance-connect-send-key` in IAM Console → Users →
`terraform-demo` → Permissions → Add permissions → Create inline
policy → JSON → paste → Next → name → Create policy.

#### When this is useful

- Your normal `ssh -i ...` invocation is muscle-memory but you've
  rotated the key and forgotten which one — Instance Connect doesn't
  care, AWS injects a fresh key per call.
- You're on a fresh laptop without your `.pem` deployed yet but you
  have AWS CLI creds — you can still get in.

#### When it doesn't help

- If your corporate EDR is breaking standard SSH on port 22, the CLI
  method **still uses port 22** for step 2 — only step 1 (the API
  push) is HTTPS. So an EDR that mangles port-22 streams will mangle
  this too. CONSOLE-GUIDE runbook item 0 covers other workarounds for
  that scenario.

### Method 2 (alternative): Browser-based — manual SG rule

Use this when you want to SSH from any device that can reach the AWS
Console (Chromebook, tablet, etc.) without installing the AWS CLI
locally. Requires a one-time SG edit because the source IP for
browser-based Instance Connect is **AWS's service**, not your
laptop.

#### Why the default SG blocks it

EC2 Instance Connect is an AWS-managed service that:

1. Pushes a temporary SSH public key into the instance via its
   metadata service.
2. Opens an SSH connection on port 22 — but the connection
   originates from one of AWS's published `EC2_INSTANCE_CONNECT`
   service IP ranges (e.g. `18.237.140.160/29` in `us-west-2`),
   **not from your laptop's IP**.

This stack's Terraform locks the SSH ingress rule on the security
group to `admin_cidr` (your laptop's IP/32 from §8). AWS's Instance
Connect service IP range isn't in that allowlist, so the SG drops
the handshake and the browser tab errors with "Failed to connect"
or "Connection timed out."

### What NOT to do

Setting `admin_cidr = "0.0.0.0/0"` would let Instance Connect
through — but it also opens port 22 to **the entire internet**,
exposing your instance to constant SSH brute-force scans. The whole
point of `admin_cidr` is to keep that surface closed. Don't do
this.

### Manual Web UI step (perform AFTER `terraform apply`)

Adds a **second** port-22 ingress rule scoped to the AWS Instance
Connect service prefix list. Your existing `admin_cidr` rule stays
as-is (your laptop only); this new rule lets the AWS Console
"Connect" tab through.

1. AWS Console → **EC2** → **Network & Security** → **Security
   Groups**.
2. Search for `graphwise-stack-<your-subdomain>-sg` and click into it.
3. **Inbound rules** tab → **Edit inbound rules**.
4. **Add rule** (button at the bottom).
5. Fill in:
   - **Type:** Custom TCP
   - **Port range:** `22`
   - **Source:** **Prefix list** (dropdown — switch from the default
     "Custom" / "My IP" / "Anywhere")
   - **Prefix list value:** start typing `ec2-instance-connect` and
     pick `com.amazonaws.<your-region>.ec2-instance-connect` from
     the autocomplete (e.g. `com.amazonaws.us-west-2.ec2-instance-connect`,
     prefix list ID will be something like `pl-...`).
   - **Description:** `EC2 Instance Connect (manual)`
6. Click **Save rules**.

The SG now has two port-22 rules: your `admin_cidr` /32 from
Terraform, and the Instance Connect prefix list from this manual
add.

### Test it

1. AWS Console → **EC2** → **Instances** → select your instance →
   **Connect** (top-right button).
2. **EC2 Instance Connect** tab → confirm `User name` is `ec2-user`
   → click **Connect**.
3. A new browser tab opens with a terminal. You're `ec2-user` on the
   instance.

If the connect attempt times out, double-check the prefix list
matches your instance's region (regions don't share prefix lists).

### Why not automate this

We tried. The Terraform path (looking up the prefix list via
`data "aws_ec2_managed_prefix_list"` and creating an
`aws_vpc_security_group_ingress_rule`) failed silently in our
testing — the rule didn't appear in the SG after `terraform apply`,
no error in the plan output, no obvious cause. Rather than ship
a fragile automation, the supported workflow is the Web UI step
above. Two minutes of clicking; runs once per deployment.

### Will the manual rule survive future `terraform apply` runs?

**Yes**, thanks to the `lifecycle.ignore_changes = [ingress]` block
on `aws_security_group.stack` in `main.tf`. Terraform creates the
three baked-in rules (22 from `admin_cidr`, 80 world, 443 world) on
first apply, then stops managing ingress drift afterward. Your
manually-added Instance Connect rule (or any other ad-hoc SG rule
you add via the Console) persists indefinitely.

Side-effect of the same `ignore_changes`: if you edit the SSH /
HTTP / HTTPS ingress blocks in the `.tf` source after first apply,
those changes also won't take effect via `terraform apply`. Use the
Console for any post-provision SG edit (the Safety section in
[infra/README.md](infra/README.md) already steers you there for
unrelated reasons).

### Recommendation

In order of complexity:

1. **Plain SSH** (`ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST`) — simplest,
   no AWS API calls, no Console step. Use this 99% of the time.
2. **`aws ec2-instance-connect ssh ...`** (Method 1 above) — adds
   one inline IAM policy, no SG change. Useful when your local
   `.pem` situation is messy or you want auto-injected per-session
   keys.
3. **Browser "Connect" tab** (Method 2 above) — adds one manual SG
   rule. Useful for emergency access from a device without AWS CLI
   or your `.pem`.

All three coexist; enabling one doesn't disable the others.

---

## 10. Graphwise registry credentials and license files

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

## 11. You're done — what's next

At this point you have:

- The `graphwise-stack-aws` repo cloned to your laptop, where you'll
  run Terraform from.
- Terraform on `PATH`, AWS CLI authenticated as a non-root IAM user.
- Bedrock available in your region (`cohere.embed-english-v3`
  reachable — no per-model approval needed), plus a least-privilege
  IAM user `graphrag-bedrock` with its access key in your password
  manager / scratch file.
- An EC2 key pair `.pem` `chmod 400`'d.
- A subdomain plan (`<sub>.<base>` apex + `*.<sub>.<base>` wildcard
  records) you'll add to Route 53 after `terraform apply`.
- Your laptop's public IP for `admin_cidr`.
- A pre-allocated Elastic IP — Allocation ID (for `terraform.tfvars`)
  and Public IPv4 (already in your DNS A records).
- Maven creds and three license files on hand.

Continue with:

- **[infra/README.md](infra/README.md)** — `terraform init`, `plan`,
  `apply`. Provisions the EC2 instance, SG, and EIP association.
  Cloud-init finishes the OS bootstrap and brings up the KIND
  cluster. **Important:** read the "Safety: never unscoped apply"
  section before doing anything beyond the first apply.
- **[DEPLOY.md §1.5 Lock the AMI](DEPLOY.md#15-lock-the-ami-one-time-immediately-after-first-apply)**
  — one-time post-apply step. Capture the launched AMI into
  `terraform.tfvars` as `ami_override` so future applies aren't
  exposed to AWS-published AMI drift.
- **[DEPLOY.md §Deploy from zero](DEPLOY.md#deploy-from-zero)** —
  the post-Terraform steps: DNS verify, SSH in, drop creds and
  licenses, run `cluster-bootstrap.sh` and `reset-helm.sh`.

If something on this page didn't work, the typical failure modes
are:

- `aws sts get-caller-identity` returns root → §4a Terraform user
  not created, or `aws configure` picked up the wrong profile.
- `aws ec2 describe-vpcs ...` returns `UnauthorizedOperation` →
  §4a Terraform user is missing `AmazonEC2FullAccess`.
- Bedrock invoke returns `AccessDeniedException` → §4b Bedrock user
  is missing `bedrock:InvokeModel` on the model, or you're hitting
  the wrong region.
- `dig` not on Windows → install `bind-toolsonly` or use
  `nslookup`.
- Homebrew install hangs → corporate firewall or VPN; try off-VPN.
