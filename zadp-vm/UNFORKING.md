# Dropping the vendored `discourse_docker` copy

## What the repo actually is

`zytedata/discourse` is **not a fork** of `discourse/discourse_docker` in the git
sense — `git merge-base upstream/main HEAD` returns nothing, so the histories are
unrelated. `Import discourse_docker base` copied a snapshot in. That is why
staying current needs hand-written "Sync to discourse_docker main" commits rather
than a merge.

## What Zyte actually changed in it

Measured against `upstream/main`:

```
15 files differ, 793 insertions, 1 deletion
```

Every differing file is Zyte-*added* — `zyte-deploy.md`, `.circleci/`,
`AGENTS.md`, `zadp-vm/`. Excluding those paths the diff is **empty**, and the
single deletion is a `tmp/*` line in `.gitignore`.

**So the entire maintenance cost of carrying ~1,700 upstream files buys zero
customisation.**

## What does depend on the vendored tree

One thing, and it is real: `.github/workflows/build-web-only.yml` builds the
deploy-platform image out of the checkout —

```
cp ./samples/web_only.yml ./containers/web_only.yml
grep base_image: ./templates/web.template.yml
bin/launcher build ... web_only
```

So the tree cannot simply be deleted; that workflow needs upstream present.

## Proposed shape

Keep only Zyte's files in the repo, and fetch `discourse_docker` at build time —
which is exactly what the VM at `zadp-vm/` already does:

```yaml
# .github/workflows/build-web-only.yml, before the build steps
- name: Fetch discourse_docker
  run: |
    git clone --depth 1 https://github.com/discourse/discourse_docker.git .docker-src
    # pin for reproducibility; bump deliberately, not by surprise
    git -C .docker-src checkout "${DISCOURSE_DOCKER_REF:-main}"
```

then point the existing `cp`/`grep`/`bin/launcher` lines at `.docker-src/`.

Repo becomes: `.circleci/`, `.github/`, `AGENTS.md`, `zyte-deploy.md`,
`containers/`, `zadp-vm/`, `Dockerfile`, `README.md`.

## Why this is better

- Upstream is whatever you pin, fetched fresh. No sync commits, no drift.
- `detect-secrets` stops scanning upstream's test fixtures — the original reason
  Discourse's Rails source was kept out of this repo in the first place.
- The diff of this repo becomes readable: it shows Zyte's decisions only.
- Reproducibility is *better*, not worse, because the upstream ref becomes an
  explicit pin instead of an implicit snapshot nobody remembers taking.

## Do this first, separately

`main` has **no root `Dockerfile`**, but `.circleci/config.yml` runs
`docker build --progress=plain -t "${IMAGE}" .`. That build cannot succeed on
`main` today. The Dockerfile exists only on the unmerged branch
`feat/zadp-dockerfile-build`.

Land that branch (or fix CircleCI) before restructuring, so the two changes are
not tangled and a broken build has one obvious cause.

## Order of work

1. Merge `feat/zadp-dockerfile-build`, confirm CircleCI goes green.
2. Change `build-web-only.yml` to clone upstream into `.docker-src/` and repoint
   its paths. Confirm the image still builds.
3. Only then `git rm -r` the vendored upstream files, in one commit that touches
   nothing else.
4. Drop the `upstream` remote and the sync process.

Step 3 is reversible from history, and steps 1-2 must be green first, so the
risky part is last and cheap to undo.
