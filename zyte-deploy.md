# Deployment Contract: zyte-community

> Contract version 1 · Managed by the Zyte Apps Deploy Platform  
> Commit this file as `zyte-deploy.md` in the root of your repository.
> Reference: https://zadp.zyte.group/public/contract  

---

## About This App

**Name:** zyte-community  
**Description:** - [Docker](https://docker.com/) is an open source project to pack, ship and run any Linux application in a lighter weight, faster container than a traditional virtual machine.

## Visibility

Who can see this app inside the Zyte Apps Deploy Platform (separate from the app's own runtime authentication).

| Setting | Value |
|---------|-------|
| Visibility | all |
| Groups |  |

Groups is a **comma-separated** list (only used when Visibility is `groups`) — e.g. `infrastructure, another-team`.

## Owners

Teams/people responsible for this app — the platform's Applications page groups apps by these entries (purely organizational, not access control).

| Setting | Value |
|---------|-------|
| Owners | all_user_accounts@zyte.com |

Owners is a **comma-separated** list mixing Google Group emails and free-text team names — e.g. `your-team@zyte.com, Platform Guild`.

## Build

Whether the platform builds this app's container image.

| Setting | Value |
|---------|-------|
| Build System | ZADP Builder |

`ZADP Builder` means a push makes the platform build the image and deploy it — nothing to add to your repository and no CI to enable. `External` means something else builds and pushes the image, and the platform waits for it to appear in the registry.

The two are not exclusive: a repository may have its own CI while the platform also builds. That works, but both will build and deploy on every push.

## Slack Notifications

Where this app's notifications go, and which kinds are sent. These are sent IN ADDITION to the platform's own audit channel, which always receives everything — leave Channel empty for audit-only.

| Setting | Value |
|---------|-------|
| Channel | #qa-automation-website |
| Deploys | Yes |
| Builds | No |
| Pushes | No |
| Lifecycle | No |

Channel is ONE Slack channel — a name (`#team-alerts`) or an ID (`C0123ABCD`). The ZADP bot must be a member of it.

Deploys covers deploy started/succeeded/failed. Builds covers image builds. Pushes covers pushes and anything waiting on you (not built, not deployed). Lifecycle covers app added/deleted, shutdown, teardown and promotion. A missing row means Yes.

Unticking a category only stops it reaching YOUR channel; the platform audit channel still receives it.

An environment can send elsewhere via the **Slack Channel** column in the Environments table below — categories stay app-wide, only the destination varies.

## Services

These are the GCP services provisioned for this application.
Edit the values below and push — the platform picks up changes on the next deployment.

### 🗄️ Cloud SQL — Database

| Setting | Value |
|---------|-------|
| Engine | PostgreSQL |
| Version | POSTGRES_18 |
| Tier | db-custom-1-3840 |
| Storage (GB) | 10 |
| Database Name | db |
| High Availability | No |

> 💡 Injected at deploy time: `DATABASE_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`

### ⚡ Valkey — Cache

| Setting | Value |
|---------|-------|
| Version | 7.2 |
| Memory (GB) | 2 |
| Eviction Policy | allkeys-lru |
| High Availability | No |

> 💡 Injected at deploy time: `VALKEY_URL`, `VALKEY_HOST`, `VALKEY_PORT`

## Deployment Settings

| Setting | Value |
|---------|-------|
| Replicas | 1 |
| CPU Request | 1000m |
| Memory Request | 4Gi |
| App Port | 80 |
| Health Check Path | /srv/status |
| Health Check Port | 80 |

> **Replicas is 1 on purpose.** Discourse runs `db:migrate` as each pod boots
> (`MIGRATE_ON_BOOT` in `containers/app.yml`). Two pods booting together race the
> same schema migration. Before scaling out, move migrations to a pre-deploy step
> and drop `MIGRATE_ON_BOOT`.
>
> **Memory is 4Gi because Unicorn forks 3 workers plus a Sidekiq process.** Each
> worker is ~400-500MB resident. Raise `UNICORN_WORKERS` only together with this
> value.
>
> **Health check is `/srv/status`**, Discourse's own liveness endpoint. Boot
> includes an asset precompile, so allow a generous initial delay (~180s) before
> the first probe or the platform will kill the pod mid-startup.

## Environments

> Ordered — a branch deploys into the FIRST matching row (top-down).
> Branch Pattern is a glob (`main`, `demo*`, `release/*`); prefix with `~` for a regex. Case-sensitive.
> A branch matching no row cannot be deployed — add a row for it, or a catch-all row with pattern `*`.
> Access Groups is a comma-separated list of Google Group emails restricting who can reach this environment's URL through IAP; only takes effect when Authentication is Enabled. Leave empty to keep today's default: any @zyte.com account.
> Services picks a named service group (shared instances); Database/Redis DB choose per-environment isolation on shared instances ($branch = one per branch).
> Image is the registry image this environment deploys; `$commit_sha` becomes the commit's short SHA and `$branch_path` is empty on the deploy branch and `/branch-slug` elsewhere. Omit the whole column to leave the images configured in ZADP untouched.
> Slack Channel overrides where THIS environment's notifications go (`#name` or an ID like `C0123ABCD`); empty inherits the app's channel. They are always sent to the platform's audit channel as well. Omit the whole column to leave the overrides configured in ZADP untouched.

| Name | Branch Pattern | Auto-Deploy | Custom Domains | Authentication | Public Endpoints | Access Groups | Secret Set | Services | Database | Redis DB | Image | Slack Channel |
|------|----------------|-------------|----------------|----------------|------------------|---------------|------------|----------|----------|----------|-------|---------------|
| production | main | Yes | discourse.zyte.group | Disabled | | | default | default | db_$branch | $branch | images.scrapinghub.com/zytedata/discourse:$commit_sha | |
| shared | * | No | | Disabled | | | default | default | db_$branch | $branch | images.scrapinghub.com/zytedata/discourse:$commit_sha | |

## Required Secrets

> Remove this section entirely if your project does not need secrets.
> Otherwise, replace placeholder rows with your actual variable names and an optional description.
> List only the **variable name** — never the secret value itself.
> Mark a row **Yes** under Required to block deploys until its value is set.

| Variable | Required | Description |
|----------|----------|-------------|
| DISCOURSE_SMTP_ADDRESS | Yes | SMTP host. Discourse cannot finish setup without working mail. |
| DISCOURSE_SMTP_PORT | Yes | Usually 587. |
| DISCOURSE_SMTP_USER_NAME | Yes | SMTP username. |
| DISCOURSE_SMTP_PASSWORD | Yes | SMTP password. |
| DISCOURSE_S3_ACCESS_KEY_ID | Yes | GCS HMAC interop key — not a service-account JSON. |
| DISCOURSE_S3_SECRET_ACCESS_KEY | Yes | GCS HMAC interop secret. |
| DISCOURSE_DEVELOPER_EMAILS | Yes | Comma-separated; these accounts become admin on first signup. |

## Environment Variables

> Non-secret configuration injected as environment variables.
> Remove this section entirely if your project does not need any.
> Mark a row **Yes** under Required to block deploys until its value is set.

> `DB_*` and `VALKEY_*` are injected by the platform and translated into the
> `DISCOURSE_*` names Discourse expects by `scripts/zyte-boot` at container start.
> Everything else lives in `containers/app.yml`.

| Variable | Required | Description |
|----------|----------|-------------|
| VALKEY_HOST | Yes | Injected by the platform; read by `scripts/zyte-boot`. |
| VALKEY_PORT | No | Injected by the platform; defaults to 6379. |
| DISCOURSE_NOTIFICATION_EMAIL | No | From address for outbound mail. |

---

*This file was generated by the Zyte Apps Deploy Platform. You can edit values directly — the platform will apply changes on the next deployment.*