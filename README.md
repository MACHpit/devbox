# MACHpit DevBox

Autonomous agent fleet for headless software development. One command spins an EC2 worker, clones a repo, runs your task, opens a PR, and self-destructs.

---

## Architecture

```
MacBook / Orchestrator
  └── devbox.sh              CLI - dispatches jobs, checks status, nukes workers

       └── CloudFormation    devbox-worker.yaml - ephemeral EC2 per job
              └── UserData   bootstrap - clone, branch, test, commit, PR
                     └── mach           on-box helper for interactive use
```

Each worker is an isolated CloudFormation stack. 10 workers building 10 repos simultaneously = run the dispatch command 10 times.

---

## Prerequisites

### 1. MACHpit AWS Account Setup

Create a fresh AWS account for MACHpit:

1. Go to **aws.amazon.com** - click "Create an AWS Account"
2. Email: use a MACHpit address (e.g. aws@machpit.com)
3. Account name: `MACHpit`
4. Complete billing + phone verification
5. Choose **Free tier** to start

Once in the console:

```bash
# Create S3 bucket for devbox jobs/logs/templates
aws s3 mb s3://machpit-devbox --region us-east-1

# Create a VPC (or use the default VPC)
# Note your subnet ID and VPC ID - set them as env vars below

# Create EC2 keypair
aws ec2 create-key-pair --key-name machpit-devbox \
  --query 'KeyMaterial' --output text > ~/.ssh/machpit-devbox.pem
chmod 400 ~/.ssh/machpit-devbox.pem

# Store your GitHub PAT
./devbox.sh init-secrets
```

### 2. Environment Variables

```bash
export AWS_REGION=us-east-1
export DEVBOX_SUBNET=subnet-xxxxxxxxxxxxxxxxx   # from your MACHpit VPC
export DEVBOX_VPC=vpc-xxxxxxxxxxxxxxxxx         # from your MACHpit VPC
export DEVBOX_KEYPAIR=machpit-devbox
export DEVBOX_S3_BUCKET=machpit-devbox
```

Add these to your `~/.zshrc` or `~/.bashrc`.

### 3. Upload assets to S3

```bash
aws s3 cp devbox-worker.yaml s3://machpit-devbox/devbox/devbox-worker.yaml
aws s3 cp mach               s3://machpit-devbox/devbox/mach
```

### 4. Install MacBook dependencies

```bash
pip3 install boto3
brew install awscli gh
```

---

## Usage

```bash
# Headless - clone, test, commit, PR, self-destruct
./devbox.sh up --repo MACHpit/some-repo --branch fix/my-fix

# Interactive - SSH in and work manually
./devbox.sh up --repo MACHpit/some-repo --branch my-branch --interactive

# Fire a job from a JSON definition
./devbox.sh dispatch --job '{"repo":"MACHpit/some-repo","branch":"agent/fix","task":"headless","test_cmd":"pytest"}'

# Monitor the fleet
./devbox.sh status

# Tail a worker's log
./devbox.sh logs devbox-machpit-some-repo-1234567890

# Kill one worker
./devbox.sh nuke devbox-machpit-some-repo-1234567890

# Kill everything
./devbox.sh nuke --all
```

---

## On-Box Helper: `mach`

Available on every running worker at `/usr/local/bin/mach`:

```
mach branch <name>       create + checkout branch
mach test                run repo test suite (.devbox.yml test cmd)
mach done "<message>"    commit + push + open PR
mach status              git status + branch + worker info
mach nuke                self-destruct this worker
mach log "<message>"     append to S3 log
mach env                 show current devbox environment
```

---

## Repo Contract: `.devbox.yml`

Drop this file in any repo root. Workers read it automatically after clone.
Zero `.devbox.yml` = still works, no custom setup.

```yaml
setup: |
  pip install -r requirements.txt

test: |
  pytest tests/ -v

secrets:
  - machpit/my-service-credentials

base_branch: main
auto_nuke_on_success: true
```

---

## Worker Lifecycle

```
devbox.sh up / dispatch
  --> S3: write job.json
  --> CloudFormation: CREATE stack
  --> EC2: boot Amazon Linux 2023
  --> UserData: install tools, pull GitHub PAT, clone repo
  --> checkout branch, load .devbox.yml, run setup
  --> run tests
  --> S3: write result.json + bootstrap.log
  --> git commit + push + open PR  (if headless + success + changes exist)
  --> CloudFormation: DELETE stack  (self-destruct)
```

Results: `s3://machpit-devbox/devbox/results/<worker-id>.json`
Logs:    `s3://machpit-devbox/devbox/logs/<worker-id>/bootstrap.log`

---

## Environment Variables Reference

| Variable | Default | Purpose |
|---|---|---|
| `AWS_REGION` | `us-east-1` | AWS region |
| `DEVBOX_S3_BUCKET` | `machpit-devbox` | S3 bucket for all devbox assets |
| `DEVBOX_KEYPAIR` | `machpit-devbox` | EC2 keypair name |
| `DEVBOX_SUBNET` | *(required)* | Subnet ID in MACHpit VPC |
| `DEVBOX_VPC` | *(required)* | VPC ID in MACHpit account |
| `DEVBOX_IDLE_MINUTES` | `120` | Auto-shutdown timer for interactive workers |
| `DEVBOX_PAT_SECRET` | `machpit/github-pat` | Secrets Manager key for GitHub PAT |
