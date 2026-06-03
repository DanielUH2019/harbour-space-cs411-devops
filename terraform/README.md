# Terraform — cloud deployment target

Provisions the AWS EC2 box the Jenkins pipeline deploys to. This replaces
clicking through the EC2 console: the `aws_instance`, `aws_security_group`, and
`aws_key_pair` are declared as code so the target is reproducible and reviewable.

Terraform provisions **infrastructure only**. The app itself is shipped by the
existing Jenkins pipeline (`scripts/deploy.sh` → `scripts/remote-install.sh`),
exactly as in first-deployment-pipeline — only the target host changes.

State lives in **S3** so the pipeline's workspace wipe can't lose track of the
instance and a re-run never spawns a second one. The default flow is fully
Jenkins-driven (below); running from a laptop is optional.

## Run it entirely through Jenkins

The pipeline's **Provision** stage runs Terraform itself (creating the state
bucket on first run), then deploys to the IP it created. One-time setup, then
just press Build — no laptop, no local Terraform.

**1. Generate a deploy key pair (once, anywhere — e.g. AWS CloudShell):**

```bash
ssh-keygen -t ed25519 -f myapp-deploy -C myapp-deploy -N ''
cat myapp-deploy        # the PRIVATE half — paste into Jenkins, step 2
```

You only ever paste the **private** half into Jenkins; the pipeline derives the
public half (`ssh-keygen -y`) and hands it to `aws_key_pair`, so the box trusts
exactly the key the Deploy stage logs in with.

**2. Add two Jenkins credentials** (Manage Jenkins → Credentials):

| Kind | ID (pipeline default) | Fields |
|------|----------------------|--------|
| SSH Username with private key | `target-ssh-key` | Username **`ubuntu`** (the Ubuntu AMI login — must be exactly this); private key = the `myapp-deploy` contents |
| Username with password | `aws-deploy-keys` | Username = AWS access key ID; password = AWS secret access key |

The IAM user behind those AWS keys needs **EC2**, **EC2 security groups**,
**S3** (to create/use the state bucket) and **budgets** permissions.

**3. Make sure the agent has** `terraform` (≥ 1.10), the `aws` CLI, and
`ssh-keygen` on PATH (plus the `ssh`/`scp`/`curl` the deploy already uses).

**4. Build with Parameters** — the defaults match the credential IDs above, so
usually you just press Build. `TARGET_HOST` is *not* an input; Terraform produces
it. The Provision stage creates the `danielc-cs411-tfstate` bucket if missing,
applies, captures the public IP, and the Deploy/Health stages take it from there.

Because the `ubuntu` user has passwordless sudo by default, the existing
`deploy.sh` / `remote-install.sh` work unchanged — no
`setup-target-local-jenkins-ssh.sh` step required on this target.

The health check (and the dashboard) then expect
`http://<public_ip>:4444/` to return the `{"Name":"Hello","Description":"World",...}`
JSON. Read the IP from the Provision stage log (`Provisioned EC2 target at ...`)
and paste it into the dashboard.

## Running from a laptop instead (optional)

Not needed for the Jenkins flow, but if you ever want to apply locally: create
the bucket once (`aws s3api create-bucket --bucket danielc-cs411-tfstate
--region us-east-1` + enable versioning), `cp terraform.tfvars.example
terraform.tfvars`, fill in `public_key_path` + `budget_alert_email`, then
`terraform init && terraform apply`.

## Tear down

```bash
terraform destroy
```

## Staying inside the free tier

This config provisions only free-tier-shaped resources, but the responsibility
for staying free is operational, not just declarative:

- **Run exactly one instance.** Free tier covers 750 hrs/month of a micro box —
  a month is 744 hrs, so one 24/7 fits; a second one (e.g. a forgotten `apply`)
  blows it. `instance_type` is validated to t3.micro/t2.micro only, and pinned to
  "standard" CPU credits so t3 bursts can't bill you.
- **Instance type depends on your plan.** The credit-based Free Tier (newer
  accounts) lists **t3.micro**; the legacy 12-month plan used **t2.micro**. The
  default is `t3.micro`; if `RunInstances` rejects it as not free-tier-eligible,
  flip `instance_type` to the other one. Run
  `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`
  to see which your account allows.
- **`terraform destroy` when you're done** for the day/week. Nothing here is
  "always free" in unlimited quantity.
- **Public IPv4 is billed since Feb 2024** (~$0.005/hr). One IP on a running
  instance is covered by the IPv4 free allowance — do **not** add an Elastic IP
  (an EIP on a stopped/unassociated instance is billed with no allowance).
- **EBS** is capped at 8 GiB gp3 here (validated <= 30 GiB).
- **Billing budget is in code.** `aws_budgets_budget.monthly` emails you as spend
  nears $1/month. The pipeline passes the address via `BUDGET_ALERT_EMAIL` in the
  Jenkinsfile (laptop runs read `budget_alert_email` from `terraform.tfvars`). It
  only *alerts* — it does not stop resources.
- **Check your plan.** Accounts created after ~July 2025 use a credit-based free
  tier (~$100, ~6-month expiry), not the legacy 12-month model — verify under
  Billing → Free tier.

## Notes / gotchas

- **Egress is not free.** A Terraform `aws_security_group` has *no* outbound
  rules unless you declare them — the console silently adds allow-all. We add an
  explicit egress block; without it, `apt`/outbound from the box would break.
- **Region-pinned AMIs.** The Ubuntu AMI ID differs per region, so we resolve
  the latest Canonical image with a `data "aws_ami"` lookup rather than
  hard-coding an ID.
- **State is sensitive.** It lives in the private, encrypted S3 bucket — never in
  git. `terraform.tfvars` is gitignored too; the evidence committed to the repo
  is the `*.tf` configuration.
- **Remote state vs. free tier.** S3 state is what stops a lost/forgotten local
  state file from orphaning the instance and spawning a billed second one on the
  next `apply`. The bucket itself is effectively free (a few KB of state).
