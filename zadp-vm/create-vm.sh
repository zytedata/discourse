#!/usr/bin/env bash
# Recreate the Discourse community VM in the ZADP project from scratch.
# Prereqs: the zadp gcloud configuration from .claude/skills/zadp-gcp/SKILL.md section 2.
set -euo pipefail

export CLOUDSDK_ACTIVE_CONFIG_NAME=zadp-zyte-vm-community-019d
ZONE=us-east1-b
VM=discourse
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Newest Ubuntu LTS, discovered -- never hardcoded (families get retired).
IMAGE_FAMILY=$(gcloud compute images list --project=ubuntu-os-cloud \
  --filter="family~^ubuntu-[0-9]{4}-lts-amd64$" \
  --sort-by=~creationTimestamp --limit=1 --format="value(family)")

# One firewall rule for the `web` tag. Idempotent.
gcloud compute firewall-rules describe allow-web >/dev/null 2>&1 || \
gcloud compute firewall-rules create allow-web \
  --allow=tcp:80,tcp:443 --target-tags=web --source-ranges=0.0.0.0/0 \
  --description="HTTP(S) to VMs tagged web (Discourse terminates TLS itself)"

# e2-small (2 vCPU / 2 GB) is the smallest type that bootstraps Discourse
# reliably; its documented 1 GB minimum OOMs during asset compilation.
gcloud compute instances create "$VM" \
  --zone="$ZONE" \
  --machine-type=e2-small \
  --image-family="$IMAGE_FAMILY" \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-balanced \
  --service-account=zadp-vm-runtime@zyte-vm-community-019d.iam.gserviceaccount.com \
  --scopes=cloud-platform \
  --labels=created-by=claude,zadp-project=zyte-vm-community-019d,app=discourse \
  --tags=web \
  --description="Discourse community site (discourse_docker standalone, self-managed Let's Encrypt TLS)" \
  --metadata-from-file=startup-script="$HERE/startup-script.sh"

echo "VM created. Then, once it has booted:"
echo "  gcloud compute scp $HERE/app.yml $VM:/tmp/app.yml --zone=$ZONE --tunnel-through-iap"
echo "  gcloud compute ssh $VM --zone=$ZONE --tunnel-through-iap"
echo "  # on the VM:"
echo "  curl -fsSL https://get.docker.com | sudo sh"
echo "  sudo git clone --depth 1 https://github.com/discourse/discourse_docker.git /var/discourse"
echo "  sudo cp /tmp/app.yml /var/discourse/containers/app.yml"
echo "  cd /var/discourse && sudo ./launcher bootstrap app && sudo ./launcher start app"
