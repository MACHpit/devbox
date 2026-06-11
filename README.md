# MACHpit DevBox

Autonomous agent fleet for headless software development. One command spins an EC2 worker, clones a repo, runs your task, opens a PR, and self-destructs.

---

## Architecture

```
MacBook / Orchestrator
  └── devbox.sh            CLI - dispatches jobs, checks status, nukes workers

       └── CloudFormation  devbox-worker.yaml - ephemeral EC2 per job
              └── UserData bootstrap.sh logic - clone, branch, test, commit, PR
                     └── hv  on-box helper for interactive use
```

Each worker is an isolated CloudFormation stack. 10 workers building 10 repos = run the command 10 times.

---

## Quick Start

### 1. Install dependencies (MacBook)

```bash
pip3 install boto3
brew install awscli gh
```

### 2. Store your GitHub PAT

```bash
./devbox.sh init-secrets
```

### 3. Upload the CF template to S3

```bash
aws s3 cp devbox-worker.yaml s3://hackerverse-agents/devbox/devbox-worker.yaml
aws s3 cp hv s3://hackerverse-agents/devbox/hv
```

### 4. Spin up a worker

```bash
# Headless - clone, test, PR, self-destruct
./devbox.sh up --repo machpit/some-repo --branch fix/my-fix

# Interactive - SSH in and work manually
./devbox.sh up --repo machpit/some-repo --branch my-branch --interactive
```

---

## Commands

```
devbox.sh up      --repo OWNER/REPO [--branch BRANCH] [--interactive] [--instance t3.large]
devbox.sh dispatch --job '{"repo":"...","branch":"...","task":"headless","test_cmd":"pytest"}'
devbox.sh status                     list all running workers
devbox.sh logs    WORKER_ID          tail worker output from S3
devbox.sh nuke    WORKER_ID          kill one worker
devbox.sh nuke    --all              kill the fleet
devbox.sh init-secrets               store GitHub PAT in Secrets Manager
```

## On-box helper (inside a worker)

```
hv branch <name>        create + checkout branch
hv test                 run repo's test suite
hv done "<message>"     commit + push + open PR
hv status               git status + branch
hv nuke                 self-destruct this worker
hv log "<message>"      append to S3 log
```

---

## Repo Contract

Drop a `.devbox.yml` in any repo root to declare setup, test, and secrets. Workers read it automatically after clone. Zero `.devbox.yml` = still works, no custom setup.

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

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `AWS_REGION` | `us-east-1` | AWS region |
| `DEVBOX_S3_BUCKET` | `hackerverse-agents` | S3 bucket for jobs/logs/templates |
| `DEVBOX_KEYPAIR` | `arenaproof` | EC2 keypair name |
| `DEVBOX_SUBNET` | *(set in devbox.sh)* | Subnet ID |
| `DEVBOX_VPC` | *(set in devbox.sh)* | VPC ID |
| `DEVBOX_IDLE_MINUTES` | `120` | Auto-shutdown idle timer |
| `DEVBOX_PAT_SECRET` | `machpit/github-pat` | Secrets Manager key for GitHub PAT |

---

## Worker Lifecycle

```
dispatch --> CF stack CREATE --> EC2 boots --> bootstrap.sh runs
  --> clone repo --> checkout branch --> load .devbox.yml --> setup
  --> run tests --> report to S3 --> commit + PR --> CF stack DELETE
```

Failures: result written to `s3://hackerverse-agents/devbox/results/<worker-id>.json`
Logs:     streamed to `s3://hackerverse-agents/devbox/logs/<worker-id>/bootstrap.log`
