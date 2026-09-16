# zyte-community

Discourse for [discourse.zyte.group](https://discourse.zyte.group), deployed by the
[Zyte Apps Deploy Platform](https://zadp.zyte.group).

This repository began as a fork of [discourse/discourse_docker][upstream], but it does
**not** deploy the upstream way. Upstream's `./launcher` builds and runs Discourse on a
VM you SSH into, with Postgres and Redis inside the same container and uploads on a local
disk. None of that applies here: ZADP builds a container image and runs it on Kubernetes
against managed Cloud SQL and Valkey, with ephemeral pods.

[upstream]: https://github.com/discourse/discourse_docker

## How the build works

`docker build .` at the repository root. There is no `./launcher bootstrap` step.

The [Dockerfile](Dockerfile) runs the same upstream pups templates, split across build and
boot using pups' tag filtering:

| Phase | Command | Does |
|---|---|---|
| Build | `pups --skip-tags=migrate,precompile` | Checkout Discourse source, clone plugins, `pnpm install`, `bundle install`, `assets:precompile:build` with `SKIP_DB_AND_REDIS=1` |
| Boot | `MIGRATE_ON_BOOT=1`, `PRECOMPILE_ON_BOOT=1` | `db:migrate` and `assets:precompile` against Cloud SQL and Valkey |

The split exists because Cloud Build has no database. Every step that needs one is tagged
`migrate` or `precompile` upstream, so deferring them is a filter, not a fork.

[scripts/zyte-bootstrap](scripts/zyte-bootstrap) assembles the config the way `launcher`
does — every template listed in `containers/app.yml`, then `app.yml` last so it wins the
merge. [scripts/zyte-boot](scripts/zyte-boot) translates ZADP's injected `DB_*` and
`VALKEY_*` variables into the `DISCOURSE_*` names Discourse reads, then execs
upstream's `/sbin/boot`.

## Layout

| Path | Purpose |
|---|---|
| [Dockerfile](Dockerfile) | Image build. Pins the `discourse/base` tag. |
| [containers/app.yml](containers/app.yml) | Deployment config: version, plugins, S3/GCS, resources. |
| [templates/web.template.yml](templates/web.template.yml) | Upstream web template. Do not edit — sync it from upstream. |
| [templates/zyte-proxy.template.yml](templates/zyte-proxy.template.yml) | Our nginx override: trust the GCP load balancer's `X-Forwarded-For`. |
| [scripts/zyte-bootstrap](scripts/zyte-bootstrap) | Build-time pups driver. |
| [scripts/zyte-boot](scripts/zyte-boot) | Runtime entrypoint and env translation. |
| [zyte-deploy.md](zyte-deploy.md) | ZADP deployment contract: replicas, resources, secrets. |

## Common tasks

### Add a plugin

Append a `git clone` to the `after_code` hook in [containers/app.yml](containers/app.yml)
and push. Plugins are baked into the image, so this requires a rebuild.

Clone the default branch rather than pinning a SHA. Discourse resolves the commit
compatible with our core version from each plugin's `.discourse-compatibility` file,
via the `plugin:pull_compatible_all` step. Pinning fights that mechanism and strands the
plugin on a version that breaks at the next stable bump.

### Add or change a theme

Do **not** put themes in this repository. Discourse stores themes in the database and
pulls them from a git remote at runtime, so baking them into the image blocks admin-side
updates.

Themes live in `zytedata/zyte-community-theme` and are installed through
**Admin → Customize → Themes → From a git repository**, with auto-update enabled. Develop
locally with the [`discourse_theme`](https://github.com/discourse/discourse_theme) CLI.

### Upgrade Discourse

Two independent pins:

- **Discourse source** — `params.version: stable` in `containers/app.yml`. The `stable`
  branch takes security backports and moves roughly quarterly. A rebuild picks up the
  latest stable; there is nothing to edit.
- **Base image** — `ARG DISCOURSE_BASE_TAG` in the `Dockerfile`. Renovate opens a PR
  weekly. Review and merge it; never switch to `:release` or `:latest`, which turn a base
  image change into an unreviewed production deploy.

Do not use the in-app "Upgrade" button under `/admin/upgrade` for core or plugins. It
mutates the running container's filesystem, and the next deploy throws that away. Builds
are the only path that persists.

### Change deployment resources or secrets

Edit [zyte-deploy.md](zyte-deploy.md) and push. Secret *values* are set in the ZADP UI —
this file lists variable names only.

## Operational notes

- **Uploads and backups go to GCS**, via its S3-compatible interop endpoint. Pods are
  ephemeral; anything written to local disk is lost on the next deploy. CORS must be set
  on the bucket with `gcloud storage buckets update --cors-file=...` — Discourse's
  automatic CORS setup is disabled because GCS does not implement that S3 API.
- **Replicas is 1.** Each pod runs `db:migrate` on boot, and concurrent migrations race.
  See the note in `zyte-deploy.md` before scaling out.
- **Boot takes a few minutes** because assets precompile at startup. Health checks need a
  generous initial delay.
- **Two CI systems build this repo**: ZADP's Cloud Build and
  [.circleci/config.yml](.circleci/config.yml). Both run on every push. That is supported
  but wasteful — disable one once you have picked a winner.
