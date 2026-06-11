#!/bin/bash
# load-env.sh - source this before running devbox commands
# Usage: source ./load-env.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill in your values."
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

echo "MACHpit DevBox environment loaded."
echo "  AWS_PROFILE  = $AWS_PROFILE"
echo "  AWS_REGION   = $AWS_REGION"
echo "  DEVBOX_VPC   = ${DEVBOX_VPC:-NOT SET}"
echo "  DEVBOX_SUBNET= ${DEVBOX_SUBNET:-NOT SET}"
