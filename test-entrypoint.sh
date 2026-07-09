#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
entrypoint="$repo_dir/entrypoint.sh"
dockerfile="$repo_dir/Dockerfile"

root_phase="$(
    awk '
        /^[[:space:]]*if \[ "\$\(id -u\)" -eq 0 \]; then/ { in_root = 1 }
        in_root { print }
        /^[[:space:]]*exec runuser -u agent -- "\$0" "\$@"/ { exit }
    ' "$entrypoint"
)"

if [ -z "$root_phase" ]; then
    echo "FAIL: test could not locate root phase in entrypoint" >&2
    exit 1
fi

if grep -Eq 'install -d .*-(o|g) agent|chown .*agent:agent' <<<"$root_phase"; then
    echo "FAIL: root phase must not need CHOWN/FOWNER capabilities to prepare COPILOT_HOME" >&2
    exit 1
fi

if ! grep -Eq 'install -d .*-(o|g) agent .* /home/agent/\.copilot|install -d .* /home/agent/\.copilot .*-(o|g) agent' "$dockerfile"; then
    echo "FAIL: Dockerfile must pre-create /home/agent/.copilot as agent-owned before runtime bind mounts" >&2
    exit 1
fi

if ! grep -Eq 'ln -sfn /seed/installed-plugins "\$COPILOT_HOME/installed-plugins"' "$entrypoint"; then
    echo "FAIL: entrypoint must still link installed plugins from the seed into COPILOT_HOME" >&2
    exit 1
fi

if grep -q 'jq.*trustedFolders' "$entrypoint" && ! grep -q 'jsonc_to_json' "$entrypoint"; then
    echo "FAIL: entrypoint must handle Copilot's JSONC config before updating trustedFolders" >&2
    exit 1
fi
