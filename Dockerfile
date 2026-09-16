# zyte-community — Discourse image for the Zyte Apps Deploy Platform.
#
# This replaces upstream's `./launcher bootstrap` flow. It runs the same pups
# templates, but splits them across build and boot:
#
#   build time  pups --skip-tags=migrate,precompile
#               -> checkout source, pnpm/bundle install, assets:precompile:build
#                  (SKIP_DB_AND_REDIS=1). Needs no database, which is the whole
#                  point: Cloud Build has none.
#   boot time   MIGRATE_ON_BOOT / PRECOMPILE_ON_BOOT in /etc/service/unicorn/run
#               -> db:migrate and assets:precompile against Cloud SQL + Valkey.
#
# Bump DISCOURSE_BASE_TAG deliberately; Renovate opens the PR. Never use
# :release or :latest — a silent base bump is an unreviewed production change.
ARG DISCOURSE_BASE_TAG=2.0.20260915-1709-stable
FROM discourse/base:${DISCOURSE_BASE_TAG}

ENV RAILS_ENV=production

COPY templates/ /zyte/templates/
COPY containers/app.yml /zyte/app.yml
COPY scripts/zyte-bootstrap /usr/local/bin/zyte-bootstrap
COPY scripts/zyte-boot /usr/local/bin/zyte-boot
RUN chmod +x /usr/local/bin/zyte-bootstrap /usr/local/bin/zyte-boot

RUN /usr/local/bin/zyte-bootstrap

EXPOSE 80

# zyte-boot translates ZADP's injected DB_*/VALKEY_* vars into the DISCOURSE_*
# names Discourse expects, then hands off to upstream's runit supervisor.
CMD ["/usr/local/bin/zyte-boot"]
