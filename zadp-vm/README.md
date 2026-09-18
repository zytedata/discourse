# Discourse community site on a ZADP VM

A deliberately minimal, single-VM Discourse install in the ZADP project
`zyte-vm-community-019d`. This is **separate** from the `zyte-deploy.md` /
`web_only` path at the root of this repo — that one runs Discourse on the Zyte
deploy platform; this is a self-contained box.

- Site: <https://discourse.community.zadp-vms.zyte.group>
- ZADP project page (budget, VM card, delete): <https://zadp.zyte.group/vm/8/>

## What exists

| Thing | Value |
|---|---|
| VM | `discourse`, zone `us-east1-b`, `e2-small` (2 vCPU / 2 GB) |
| Disk | 20 GB `pd-balanced`, daily snapshots kept 14 days (`daily-14d`) |
| Swap | 2 GB on `/swapfile` (Discourse requires swap under 4 GB RAM) |
| OS | newest Ubuntu LTS family, discovered at create time |
| Install | `discourse_docker` standalone at `/var/discourse` |
| Firewall | `allow-web` (tcp 80/443, tag `web`) + ZADP's IAP-only SSH |
| TLS | Let's Encrypt, obtained and renewed by Discourse's own nginx |
| Mail | SMTP2GO, `mail-eu.smtp2go.com:2525` STARTTLS |

`e2-small` rather than Discourse's documented 1 GB minimum: asset compilation
OOMs or crawls at 1 GB on burstable CPU. This is the smallest type that
bootstraps reliably.

## Files here

| File | Purpose |
|---|---|
| `create-vm.sh` | recreates the VM, firewall rule and startup script from nothing |
| `startup-script.sh` | Ops Agent, `unattended-upgrades`, `needrestart`, 2 GB swap |
| `app.yml` | the Discourse container config; goes to `/var/discourse/containers/app.yml` |
| `inject-smtp.sh` | substitutes the real SMTP password into `app.yml` on the VM |

## Secrets

`app.yml` here is tracked in git, so it carries
`DISCOURSE_SMTP_PASSWORD: "__FROM_SECRET_MANAGER__"`. The real value lives in this
project's Secret Manager as **`discourse-smtp-password`** and is put in place on
the VM only:

```bash
export CLOUDSDK_ACTIVE_CONFIG_NAME=zadp-zyte-vm-community-019d
gcloud compute scp zadp-vm/app.yml zadp-vm/inject-smtp.sh discourse:/tmp/ \
  --zone=us-east1-b --tunnel-through-iap
gcloud secrets versions access latest --secret=discourse-smtp-password \
| gcloud compute ssh discourse --zone=us-east1-b --tunnel-through-iap --command='
    set -e
    sudo cp /tmp/app.yml /var/discourse/containers/app.yml
    sudo bash /tmp/inject-smtp.sh
    rm -f /tmp/app.yml /tmp/inject-smtp.sh'
```

`inject-smtp.sh` takes the password on **stdin**, never as an argument — argv is
readable by any local user through `/proc`.

The VM's own runtime service account **cannot** read that secret
(`secretmanager.versions.access` denied), so it cannot fetch it at boot. Granting
that needs a project IAM change, which the agent account is not permitted to make
— ask in #zadp-support if you want boot-time fetch instead of the injection above.

## Rebuild from nothing

```bash
./zadp-vm/create-vm.sh      # prints the remaining on-VM steps
```

## Day to day

Every `gcloud` call needs this project's own configuration. **Never** activate it
globally — that repoints `gcloud` and `kubectl` machine-wide:

```bash
export CLOUDSDK_ACTIVE_CONFIG_NAME=zadp-zyte-vm-community-019d
```

```bash
gcloud compute ssh discourse --zone=us-east1-b --tunnel-through-iap
cd /var/discourse
sudo ./launcher logs app          # what it's doing
sudo ./launcher restart app       # restart, no rebuild
sudo ./launcher rebuild app       # after editing containers/app.yml (~15-25 min)
```

Long-running work over the tunnel dies when the session drops (`broken pipe`), so
run a bootstrap or rebuild as a detached unit:

```bash
sudo systemd-run --unit=discourse-bootstrap --collect \
  --working-directory=/var/discourse \
  --property=StandardOutput=append:/var/log/discourse-bootstrap.log \
  --property=StandardError=append:/var/log/discourse-bootstrap.log \
  --property=TimeoutStartSec=infinity \
  /var/discourse/launcher rebuild app
```

Stop the VM when nobody needs it — it is the expensive part:

```bash
gcloud compute instances stop  discourse --zone=us-east1-b
gcloud compute instances start discourse --zone=us-east1-b
```

The hostname's A record follows the ephemeral external IP, so a stop/start keeps
the name working.

## Gotchas found the hard way

- `DISCOURSE_SMTP_ADDRESS: smtp.example.com` is a **sentinel**: Discourse's web
  template aborts the build on it unless `DISCOURSE_SKIP_EMAIL_SETUP: "1"` is set.
- `pkill -f "launcher bootstrap"` over SSH matches **its own** command line and
  kills the session. Use the bracket trick: `pkill -f "launche[r] bootstrap"`.
  Same for `pgrep -f`, which otherwise always reports the process as running.
- Do not pass `--troubleshoot` to `gcloud compute ssh`; it enables
  `networkmanagement.googleapis.com` on the project without asking.

## Verified on 2026-09-18

- `https://discourse.community.zadp-vms.zyte.group/srv/status` -> 200
- Let's Encrypt certificate issued, `notAfter=Dec 17 15:48:49 2026 GMT`, renewal
  cron (`acme.sh --cron`) present inside the container
- `http://` -> 301 to `https://`, `DISCOURSE_FORCE_HTTPS=true`
- SMTP2GO login succeeded from the VM over 2525/STARTTLS
- Ops Agent and `unattended-upgrades` both active

Memory is tight: 1.4 GB of 1.9 GB in use with ~400 MB of swap touched, 2 unicorn
workers. It runs, but `e2-medium` (4 GB) is the upgrade if it starts swapping
under real traffic.

## Outstanding work

1. **No admin account exists yet.** Sign up at the site with
   `angel.munoz@zyte.com` — it is in `DISCOURSE_DEVELOPER_EMAILS`, so the first
   account registered with it becomes admin. SMTP works, so the activation mail
   will arrive.
2. **Discourse-level backups.** The snapshot schedule protects the *disk*; it is
   not a Discourse backup, and Postgres lives inside this VM, so app and data die
   together. Before real content lands: enable Discourse's scheduled backups and
   push them to a bucket **outside this project**, then restore one to prove it
   works. The ZADP budget's hard cap can unlink billing, after which resources
   here become deletable — an off-project copy is the only thing that survives.
3. **Weekly maintenance report.** `unattended-upgrades` applies patches, but
   nothing yet reports upgradable packages, `pro security-status`, pending
   restarts (`needrestart`) or days-to-expiry on the TLS certificate.

## Cost

Roughly **$19/month** with the VM running continuously: ~$13.50 VM, ~$2 disk,
~$3.65 ephemeral external IP (the IP bills only while the VM runs). Budget is
$50/month with alerts at 50/80% and possible billing unlink at 100%. Stopping the
VM drops it to about $2–6.

## Owner

angel.munoz@zyte.com
