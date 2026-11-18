# Developing on the Zyte community forum

Two separate things live here, developed differently:

1. **The theme component** (`zyte-community-theme`) — branding, CSS, small JS.
   No rebuild, hot-loaded, safe to iterate on.
2. **The VM / deployment config** (`zyte-community` repo, `zadp-vm/`) — the
   forum's infrastructure. Every change needs a rebuild (15-30 min normally;
   watched one run ~29 min end to end, with `docker commit` alone taking 13
   min under disk contention) and is a real risk to a production site with no
   staging environment.

Read the right section below depending on which one you're touching.

---

## 1. Theme development

### One-time setup

```bash
# Ruby: macOS ships 2.6.10, and its gem directory isn't user-writable, so a
# plain `gem install` fails without sudo. Get a real Ruby instead:
brew install ruby
echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

gem install discourse_theme
```

### Get an admin API key

You need an admin account on the forum first — sign up, and the first account
matching `DISCOURSE_DEVELOPER_EMAILS` in `app.yml` becomes admin automatically.
Then: **Admin → API → New API Key**

- Scope: **Global** (not a single scope) — a scoped key 403s on theme endpoints.
- User Level: **Single User**, pinned to your account, not "All Users".

### The edit loop

```bash
cd ~/Documents/GitHub/zyte-community-theme
discourse_theme watch .
```

It asks for the site URL and the API key on first run and caches them in
`~/.discourse_theme`. Every file save syncs to the site and the open browser
tab refreshes. `--reset` if you need to point it at a different key or site.

### There is no staging environment

`discourse_theme watch` edits the **live** site as you type. Given that:

- Install the theme as **non-default**, and preview changes with
  `?preview_theme_id=<id>` appended to any page URL — only you see it.
- If something renders broken for everyone, `/safe-mode` loads the site with
  themes disabled, from which you can revert in Admin → Customize → Themes.
- For anything beyond a small CSS/copy tweak, run Discourse locally
  (`discourse/discourse`'s own dev container) and point `discourse_theme
  watch` at `http://localhost:3000` instead.

### Publishing changes

```bash
cd ~/Documents/GitHub/zyte-community-theme
git add -A && git commit -m "..."
git push
```

Discourse pulls updates from the remote when an admin clicks **Check for
updates** on the theme in Admin → Customize → Themes — `watch` mode bypasses
that and pushes straight to the site, so treat committed history as the record
of what shipped, not as something that deploys itself.

**Gap: this repo has no remote yet.** It should live at
`github.com/zytedata/zyte-community-theme`, following the same pattern as any
Zyte plugin/theme (see `zyte-community`'s own `AGENTS.md`). Normally that repo
is created from `zytedata/zyte-service-template` so it inherits the org's
secret-scanning workflow and branch rules automatically. That template
**does not exist** in the 245 repos this account can see in `zytedata` — not a
permissions edge case, it simply isn't there under that name. Two ways
forward: ask whoever administers `zytedata` where the current template lives,
or create the repo plain (`gh repo create zytedata/zyte-community-theme
--private`) and accept that it starts ungoverned until someone applies the
org's rulesets to it by hand.

---

## 2. VM / deployment changes

Everything here is `zadp-vm/` in the `zyte-community` repo, on branch
`zadp-vm-setup` (not yet on `main`).

### Access

```bash
export CLOUDSDK_ACTIVE_CONFIG_NAME=zadp-zyte-vm-community-019d
gcloud compute ssh discourse --zone=us-east1-b --tunnel-through-iap
```

Never activate that gcloud configuration globally — it would repoint every
`gcloud`/`kubectl` call on the machine, including unrelated projects.

### The loop

1. Edit the relevant file under `zadp-vm/`.
2. `gcloud compute scp <file> discourse:/tmp/ --zone=us-east1-b --tunnel-through-iap`
3. Move it into place on the VM (`sudo cp /tmp/<file> /var/discourse/containers/app.yml`
   for the main config, `/usr/local/bin/` for the operational scripts).
4. For `app.yml`: `cd /var/discourse && sudo ./launcher rebuild app`.
   For a script: just `sudo install -m 0755 ...` — no rebuild needed.
5. Verify externally: `curl -s -o /dev/null -w '%{http_code}\n' https://forum.zyte.com/srv/status`
6. Commit the repo change **only after** confirming the live result matches —
   this repo should describe the VM's actual state, not an intended one.

### The one real constraint: the VM is CPU-tight

The VM has since moved to `e2-medium` (checked 2026-11-18); the history below
explains why.

`e2-small` sustains only **50% of one physical core** across its 2 vCPUs
(bursting briefly beyond that). `docker stats` shows the running container at
~98% CPU under ordinary traffic, no rebuild in progress. A `launcher rebuild`
runs several parallel JS-minifier workers during asset precompile, each capped
at a 15-second script timeout — burstable credit runs out mid-build and one
of those workers gets killed, failing the whole rebuild
(`MiniRacer::ScriptTerminatedError`).

Consequence: **a rebuild can fail for capacity reasons alone**, with no config
error to fix. This happened for real on 2026-09-30 (see the hostname-history
entry in `README.md`) — a plain retry succeeded with nothing else changed, so
it is worth one retry before concluding it's systemic. A second failure means
the VM needs `e2-medium` (doubles the sustained floor to 100% of a core,
~$24/mo vs ~$12/mo) — that requires stopping the VM, so it's a real decision,
not something to do silently mid-task.

### `app.yml`'s SMTP password: two safe ways to deploy, one unsafe one

The repo's `app.yml` carries `DISCOURSE_SMTP_PASSWORD: "__FROM_SECRET_MANAGER__"`
as a placeholder — the real value only exists in Secret Manager (write-only
for the VM's service account, so it cannot be read back there either) and
already-injected on the live file.

- **Copying the repo file over the live one and stopping there blanks the
  password.** Don't do that.
- **Safe, and what actually shipped the `forum.zyte.com` change:** back up
  the live file (`sudo cp app.yml app.yml.bak-$(date +%Y%m%d)`), then `sed`
  just the specific lines you're changing directly on the live file, leaving
  the password line untouched.
- **Also safe, when the change genuinely does touch SMTP:** copy the repo
  file over, then re-run `inject-smtp.sh` (reads the password from stdin,
  never argv) before rebuilding.

### Watchdog behaviour during a rebuild

`discourse-healthcheck.timer` runs every 5 minutes and restarts the container
if it's down past a 10-minute boot grace. During a rebuild that fails at the
image-build stage, the *old* container may already be stopped — the watchdog
will restart it, bringing back the pre-change version (correct fallback
behaviour, but it means "the site is up" doesn't imply "the rebuild landed").
Always verify the actual running config after any rebuild:

```bash
sudo docker inspect app --format '{{range .Config.Env}}{{println .}}{{end}}' | grep HOSTNAME
```

### Backups before anything risky

```bash
sudo systemctl start discourse-backup.service   # ~10s, uploads to GCS, safe to run anytime
```

Full operational reference: `zadp-vm/README.md`.
