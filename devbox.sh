#!/usr/bin/env python3
"""
devbox.sh - MACHpit DevBox CLI
Autonomous agent fleet for headless software development.

Usage:
  ./devbox.sh up      --repo OWNER/REPO [--branch BRANCH] [--interactive] [--instance t3.medium]
  ./devbox.sh dispatch --job JOB_JSON_OR_S3_KEY
  ./devbox.sh status
  ./devbox.sh logs    WORKER_ID
  ./devbox.sh nuke    [WORKER_ID | --all]
  ./devbox.sh init-secrets
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import boto3
import re

# ── Config ────────────────────────────────────────────────────────────────────
REGION          = os.environ.get("AWS_REGION", "us-east-1")
STACK_PREFIX    = "devbox"
S3_BUCKET       = os.environ.get("DEVBOX_S3_BUCKET", "machpit-devbox")
S3_PREFIX       = "devbox"
SECRETS_PAT     = os.environ.get("DEVBOX_PAT_SECRET", "machpit/github-pat")
DEFAULT_AMI     = os.environ.get("DEVBOX_AMI", "")
DEFAULT_ITYPE   = "t3.medium"
KEYPAIR         = os.environ.get("DEVBOX_KEYPAIR", "machpit-devbox")
SUBNET_ID       = os.environ.get("DEVBOX_SUBNET", "")
VPC_ID          = os.environ.get("DEVBOX_VPC", "")
IDLE_TIMEOUT    = int(os.environ.get("DEVBOX_IDLE_MINUTES", "120"))
CF_TEMPLATE_URL = os.environ.get(
    "DEVBOX_CF_TEMPLATE",
    f"https://s3.amazonaws.com/{S3_BUCKET}/{S3_PREFIX}/devbox-worker.yaml"
)

# ── Helpers ───────────────────────────────────────────────────────────────────
def slug(repo: str) -> str:
    return re.sub(r"[^a-z0-9]", "-", repo.lower())[:30]

def ts() -> str:
    return str(int(time.time()))

def stack_name(repo: str) -> str:
    return f"{STACK_PREFIX}-{slug(repo)}-{ts()}"

def cf_client():  return boto3.client("cloudformation", region_name=REGION)
def ssm_client(): return boto3.client("ssm",            region_name=REGION)
def ec2_client(): return boto3.client("ec2",            region_name=REGION)
def s3_client():  return boto3.client("s3",             region_name=REGION)
def sm_client():  return boto3.client("secretsmanager", region_name=REGION)

def list_devbox_stacks():
    cf = cf_client()
    stacks = []
    paginator = cf.get_paginator("list_stacks")
    for page in paginator.paginate(StackStatusFilter=[
        "CREATE_COMPLETE", "UPDATE_COMPLETE", "CREATE_IN_PROGRESS"
    ]):
        for s in page["StackSummaries"]:
            if s["StackName"].startswith(STACK_PREFIX + "-"):
                stacks.append(s)
    return stacks

def get_stack_output(stack_name, key):
    cf = cf_client()
    r = cf.describe_stacks(StackName=stack_name)
    for o in r["Stacks"][0].get("Outputs", []):
        if o["OutputKey"] == key:
            return o["OutputValue"]
    return None

def resolve_ami():
    ec2 = ec2_client()
    r = ec2.describe_images(
        Owners=["amazon"],
        Filters=[
            {"Name": "name",        "Values": ["al2023-ami-*-x86_64"]},
            {"Name": "state",       "Values": ["available"]},
            {"Name": "architecture","Values": ["x86_64"]},
        ]
    )
    images = sorted(r["Images"], key=lambda x: x["CreationDate"], reverse=True)
    if not images:
        sys.exit("ERROR: Could not resolve Amazon Linux 2023 AMI.")
    return images[0]["ImageId"]

def upload_cf_template():
    template_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "devbox-worker.yaml")
    mach_path     = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mach")
    if not os.path.exists(template_path):
        sys.exit(f"ERROR: devbox-worker.yaml not found at {template_path}")
    s3  = s3_client()
    key = f"{S3_PREFIX}/devbox-worker.yaml"
    s3.upload_file(template_path, S3_BUCKET, key)
    print(f"  Uploaded CF template  -> s3://{S3_BUCKET}/{key}")
    if os.path.exists(mach_path):
        mach_key = f"{S3_PREFIX}/mach"
        s3.upload_file(mach_path, S3_BUCKET, mach_key)
        print(f"  Uploaded mach helper  -> s3://{S3_BUCKET}/{mach_key}")

# ── Commands ──────────────────────────────────────────────────────────────────
def cmd_up(args):
    repo        = args.repo
    branch      = args.branch or f"devbox/{ts()}"
    interactive = args.interactive
    itype       = args.instance or DEFAULT_ITYPE
    ami         = DEFAULT_AMI or resolve_ami()
    name        = stack_name(repo)

    if not SUBNET_ID or not VPC_ID:
        sys.exit("ERROR: Set DEVBOX_SUBNET and DEVBOX_VPC environment variables first.\n"
                 "  Run: ./devbox.sh bootstrap-vpc  (after AWS account is ready)")

    print(f"[devbox] Spinning up worker: {name}")
    print(f"  repo={repo}  branch={branch}  ami={ami}  type={itype}")

    upload_cf_template()

    job = {
        "repo":       repo,
        "branch":     branch,
        "task":       "interactive" if interactive else "headless",
        "test_cmd":   "",
        "on_success": "pr",
        "on_failure": "report"
    }
    job_key = f"{S3_PREFIX}/jobs/{name}.json"
    s3_client().put_object(Bucket=S3_BUCKET, Key=job_key, Body=json.dumps(job).encode())

    params = [
        {"ParameterKey": "AmiId",           "ParameterValue": ami},
        {"ParameterKey": "InstanceType",    "ParameterValue": itype},
        {"ParameterKey": "KeyPairName",     "ParameterValue": KEYPAIR},
        {"ParameterKey": "SubnetId",        "ParameterValue": SUBNET_ID},
        {"ParameterKey": "VpcId",           "ParameterValue": VPC_ID},
        {"ParameterKey": "S3Bucket",        "ParameterValue": S3_BUCKET},
        {"ParameterKey": "JobS3Key",        "ParameterValue": job_key},
        {"ParameterKey": "IdleMinutes",     "ParameterValue": str(IDLE_TIMEOUT)},
        {"ParameterKey": "GithubPatSecret", "ParameterValue": SECRETS_PAT},
        {"ParameterKey": "StackName",       "ParameterValue": name},
    ]

    cf = cf_client()
    cf.create_stack(
        StackName=name,
        TemplateURL=CF_TEMPLATE_URL,
        Parameters=params,
        Capabilities=["CAPABILITY_IAM"],
        Tags=[
            {"Key": "devbox", "Value": "true"},
            {"Key": "repo",   "Value": repo},
            {"Key": "branch", "Value": branch},
        ]
    )

    print(f"  Stack creating... polling for EC2 IP")
    instance_ip = None
    for _ in range(60):
        time.sleep(10)
        try:
            ip = get_stack_output(name, "InstancePublicIp")
            if ip:
                instance_ip = ip
                break
        except Exception:
            pass
        print("  .", end="", flush=True)
    print()

    if not instance_ip:
        sys.exit("ERROR: Stack did not produce an IP within 10 minutes.")

    print(f"\n  Worker IP: {instance_ip}")
    print(f"  Worker ID: {name}")

    if interactive:
        print(f"\n  SSHing in...")
        subprocess.run([
            "ssh", "-i", f"~/.ssh/{KEYPAIR}.pem",
            "-o", "StrictHostKeyChecking=no",
            f"ec2-user@{instance_ip}"
        ])
    else:
        print(f"\n  Worker running headlessly. Track with:")
        print(f"    ./devbox.sh logs {name}")


def cmd_dispatch(args):
    job_input = args.job
    if job_input.startswith("s3://") or not job_input.startswith("{"):
        job_key = job_input.replace(f"s3://{S3_BUCKET}/", "")
        r = s3_client().get_object(Bucket=S3_BUCKET, Key=job_key)
        job = json.loads(r["Body"].read())
    else:
        job = json.loads(job_input)

    class FakeArgs:
        pass
    fa            = FakeArgs()
    fa.repo       = job.get("repo", "unknown/repo")
    fa.branch     = job.get("branch", f"devbox/{ts()}")
    fa.interactive = False
    fa.instance   = job.get("instance_type", DEFAULT_ITYPE)
    cmd_up(fa)


def cmd_status(args):
    stacks = list_devbox_stacks()
    if not stacks:
        print("No active devbox workers.")
        return
    print(f"{'WORKER ID':<50} {'STATUS':<25} {'CREATED'}")
    print("-" * 90)
    for s in stacks:
        print(f"{s['StackName']:<50} {s['StackStatus']:<25} {s['CreationTime'].strftime('%Y-%m-%d %H:%M')}")


def cmd_logs(args):
    key = f"{S3_PREFIX}/logs/{args.worker_id}/bootstrap.log"
    try:
        r = s3_client().get_object(Bucket=S3_BUCKET, Key=key)
        print(r["Body"].read().decode())
    except Exception:
        print(f"No logs yet for {args.worker_id}. Worker may still be booting.")


def cmd_nuke(args):
    cf = cf_client()
    if args.all:
        stacks = list_devbox_stacks()
        if not stacks:
            print("Nothing to nuke.")
            return
        for s in stacks:
            cf.delete_stack(StackName=s["StackName"])
            print(f"  Nuked: {s['StackName']}")
    elif args.worker_id:
        cf.delete_stack(StackName=args.worker_id)
        print(f"  Nuked: {args.worker_id}")
    else:
        sys.exit("ERROR: Provide a WORKER_ID or --all")


def cmd_init_secrets(args):
    import getpass
    sm  = sm_client()
    pat = getpass.getpass("GitHub PAT: ").strip()
    try:
        sm.create_secret(Name=SECRETS_PAT, SecretString=pat)
        print(f"  Created secret: {SECRETS_PAT}")
    except sm.exceptions.ResourceExistsException:
        sm.put_secret_value(SecretId=SECRETS_PAT, SecretString=pat)
        print(f"  Updated secret: {SECRETS_PAT}")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(prog="devbox.sh")
    sub = parser.add_subparsers(dest="command")

    p_up = sub.add_parser("up")
    p_up.add_argument("--repo",        required=True)
    p_up.add_argument("--branch",      default="")
    p_up.add_argument("--interactive", action="store_true")
    p_up.add_argument("--instance",    default=DEFAULT_ITYPE)

    p_dispatch = sub.add_parser("dispatch")
    p_dispatch.add_argument("--job", required=True)

    sub.add_parser("status")

    p_logs = sub.add_parser("logs")
    p_logs.add_argument("worker_id")

    p_nuke = sub.add_parser("nuke")
    p_nuke.add_argument("worker_id", nargs="?", default="")
    p_nuke.add_argument("--all", action="store_true")

    sub.add_parser("init-secrets")

    args = parser.parse_args()
    dispatch = {
        "up":           cmd_up,
        "dispatch":     cmd_dispatch,
        "status":       cmd_status,
        "logs":         cmd_logs,
        "nuke":         cmd_nuke,
        "init-secrets": cmd_init_secrets,
    }
    if args.command not in dispatch:
        parser.print_help()
        sys.exit(1)
    dispatch[args.command](args)

if __name__ == "__main__":
    main()
