# Challenge 5 — Deploying to a real AWS EC2 target with Terraform + Jenkins

The target moved out of the playground onto a self-provisioned AWS EC2 box. I did
the whole thing as code: **Terraform** declares the infrastructure
(`terraform/main.tf` — `aws_instance`, `aws_security_group`, `aws_key_pair`,
plus a billing budget) and the **Jenkins pipeline** drives it end to end —
provision → build → deploy → health-check — with no clicking through the console
and no secrets in the repo.

This file is the reflection the challenge asks for: the two required observations
(what the plan caught vs. what was more annoying than the console), followed by
the real design decisions and the gotchas I actually hit getting it green.

---

## The two required reflections

### One thing the Terraform plan caught that I'd have missed in the console

**A Terraform-managed security group has *no* outbound rule unless you declare
one.** When you create a security group in the EC2 console, AWS silently
pre-fills an "All traffic → 0.0.0.0/0" egress rule, so you never think about it.
`aws_security_group` does the opposite: omit the `egress` block and the group is
created with **zero** outbound rules. `terraform plan` showed the SG with an empty
egress set — exactly the line you skim past in the console — and that box would
have booted unable to reach the internet (no `apt`, no package pulls, failed
outbound). I'd have wasted time blaming SSH or the AMI. The fix was an explicit
allow-all `egress` block, which makes the outbound policy visible and reviewable
instead of an invisible console default.

### One thing that was more annoying via Terraform than the console

**Getting a usable private key.** In the console, "Create key pair" generates the
pair and downloads the `.pem` in one click — you're holding a working private key
seconds later. Terraform's `aws_key_pair` only accepts the **public** half, so I
had to `ssh-keygen` the pair myself first and point Terraform at the `.pub`. It
deliberately won't hand you a private key, and the `tls_private_key` shortcut
would dump the private key into `terraform.tfstate` in plaintext (worse). It's the
*more correct* workflow, but it's extra steps and a "where did I save that key"
moment the console collapses into a button.

---

## Design decisions

### 1. Terraform provisions; Jenkins deploys

Two tools, two jobs. Terraform only creates the box, the security group, and the
key pair. The application is still shipped by the existing
`scripts/deploy.sh` → `scripts/remote-install.sh` under systemd — identical to the
first-deployment-pipeline, just a different target host. Keeping "infra" and
"deploy" separate means the Terraform stays a clean description of *what exists*,
and the deploy stays a clean description of *what runs*.

### 2. Remote state in S3 (not local state)

This was the decision with the most thought behind it. The pipeline wipes its
workspace (`post { always { deleteDir() } }`) and runs on `agent any`. With
**local** Terraform state in the workspace, that state would be deleted between
builds — or a build could land on a different agent that never had it — and the
next `terraform apply` would have no memory of the instance and create a
**second one**. That is precisely the free-tier trap (two instances → blown
750-hour and IPv4 allowances).

So state lives in an **S3 backend** (`backend "s3"`, bucket
`danielc-cs411-tfstate`, `use_lockfile = true` for native locking, no DynamoDB).
Now the workspace wipe is harmless (re-`init` pulls state back from S3), `agent
any` is safe, and the laptop and the pipeline share one source of truth. The
trade-off is the one-time chicken-and-egg: Terraform can't create the bucket that
holds its own state, so the bucket is bootstrapped once (the pipeline does it via
the AWS CLI before `terraform init`; it's a few KB, well inside the S3 free tier).

### 3. The whole flow runs from Jenkins

A new **Provision** stage runs before lint/build (so the instance is booting while
those run, ready for SSH by Deploy time). It:

- injects AWS keys (`withCredentials`) for Terraform and the S3 backend,
- **derives the deploy key's public half from the Jenkins SSH credential**
  (`ssh-keygen -y`) and feeds it to `aws_key_pair` — so the box is born trusting
  exactly the key the Deploy stage logs in with. One credential, one source of
  truth, no separate "upload my public key" step,
- runs `terraform apply`, reads `terraform output public_ip` into
  `env.TARGET_HOST`, then **waits for port 22** so the deploy's `ssh-keyscan`
  doesn't race the boot.

`TARGET_HOST` is no longer a build parameter — Terraform produces it. The only two
parameters left are the credential IDs (`SSH_CREDENTIALS_ID`, `AWS_CREDENTIALS_ID`).

### 4. Credentials and secrets

- **No root keys in automation.** I used the account root only to bootstrap a
  dedicated, least-privilege IAM user (`jenkins-terraform`) with a scoped policy
  (`ec2:*`, `budgets:*`, and S3 limited to the state bucket), then put *that*
  user's access key into Jenkins — not root's.
- **Two Jenkins credentials**: `aws-deploy-keys` (AWS access key/secret, talks to
  the AWS API) and `target-ssh-key` (SSH key, username `ubuntu`, logs into the
  instance). The SSH private key never leaves Jenkins; AWS only ever sees the
  public half.
- **Nothing sensitive in git**: state is in encrypted S3, `terraform.tfvars` and
  `*.pem`/`deploy.pub` are gitignored. The committed evidence is just the `*.tf`.

### 5. Free-tier guardrails baked in

- `t3.micro` only (see gotcha below), pinned to **`cpu_credits = "standard"`** so
  t3 burst credits can't quietly bill.
- `instance_type` is **validated** to t3.micro/t2.micro and the root volume to
  ≤ 30 GiB, so a typo can't provision a billed shape.
- An **`aws_budgets_budget`** ($1/month, emails me at 80% actual / 100% forecast)
  is declared in Terraform — the real safety net, since it warns regardless of
  pricing changes. (It only *alerts*; it doesn't cap spend.)
- Deliberately **no Elastic IP** — since Feb 2024 every public IPv4 is billed
  (~$0.005/hr, one is covered by the free allowance), and an EIP on a stopped
  instance bills with no allowance. The auto-assigned IP is the cheaper choice.
- Operational discipline that code can't enforce: run **one** instance and
  `terraform destroy` when done.

---

## Gotchas I actually hit (and the fix)

- **`t2.micro` was rejected at `apply`:** `InvalidParameterCombination: not
  eligible for Free Tier`. This account is on the **newer credit-based Free Tier**
  (post-2025), where the eligible x86_64 type is **`t3.micro`**, not the legacy
  `t2.micro`. Switched the default to `t3.micro` (still amd64, so the AMI/binary
  are unaffected — importantly *not* `t4g.micro`, which is ARM).
- **`aws: command not found` in the pipeline:** the bucket-bootstrap step needs
  the AWS CLI, which wasn't on the Jenkins agent. Terraform itself talks to AWS via
  its own SDK and needs no CLI — only the one-time bucket creation does. Fixed by
  installing the AWS CLI on the agent. (Agent now needs: `terraform` ≥ 1.10, the
  `aws` CLI, `ssh-keygen`, plus the `ssh`/`scp`/`curl` the deploy already used.)
- **"I can't find the instance in the console":** it was a region mismatch — the
  box lives in `us-east-1` (its `54.91.x.x` IP gives it away) and the console was
  pointed elsewhere. The instance was fine; the console region selector was not.

---

## Not done / future stretch

- **Lock down the security group.** `tcp/22` is currently open to `0.0.0.0/0`. The
  stretch is to restrict SSH to a single known IP (or go SSH-less via SSM Session
  Manager) while keeping `tcp/4444` world-open for the verifier. The `terraform/`
  config already exposes a `ssh_ingress_cidrs` variable to narrow it.
- **One-click teardown.** A `DESTROY` boolean parameter on the pipeline would let
  Jenkins `terraform destroy` instead of running it from the laptop.
