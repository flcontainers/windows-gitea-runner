#!/usr/bin/env bash
# Renders the in-VM settings from the container environment into config.env, then starts dockur.
# Skipped when /oem is a read-only mount (e.g. the compose oem-config sidecar already wrote it).
set -euo pipefail

if [ -w /oem ]; then
  env | grep -E '^(GITEA_|RUNNER_|KMS_|UPDATE_|LOCALE_)' > /oem/config.env || true
fi

# configure.ps1 pulls config.env and script fixes from \\host.lan\Data (/shared) at each runner start.
mkdir -p /shared 2>/dev/null || true
if [ -w /shared ]; then
  cp -f /oem/* /shared/
fi

exec /run/entry.sh "$@"
