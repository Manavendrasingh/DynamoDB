#!/usr/bin/env bash
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  aws --version
  exit 0
fi

sudo apt-get update
sudo apt-get install -y unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install

