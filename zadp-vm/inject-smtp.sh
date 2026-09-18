#!/usr/bin/env bash
# Reads the SMTP password on stdin and substitutes it into the placeholder in
# /var/discourse/containers/app.yml. Never takes it as an argument (argv is
# world-readable via /proc). Run as root.
set -euo pipefail
IFS= read -r PW
[ -n "$PW" ] || { echo "no password on stdin" >&2; exit 1; }
PW="$PW" python3 - <<'PY'
import os, pathlib
p = pathlib.Path("/var/discourse/containers/app.yml")
s = p.read_text()
if "__FROM_SECRET_MANAGER__" not in s:
    raise SystemExit("placeholder not present -- refusing to touch app.yml")
p.write_text(s.replace("__FROM_SECRET_MANAGER__", os.environ["PW"]))
print("password injected")
PY
chmod 600 /var/discourse/containers/app.yml
grep -c '__FROM_SECRET_MANAGER__' /var/discourse/containers/app.yml && echo "PLACEHOLDER STILL PRESENT" || echo "placeholder gone (good)"
