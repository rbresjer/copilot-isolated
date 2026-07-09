#!/usr/bin/env bash
# Container entrypoint for the copilot-isolated sandbox. Two phases:
#
#   1. root  — start the filtering proxy and program the egress firewall, then
#              drop to the unprivileged 'agent' user (uid 1000).
#   2. agent — configure git/gh, install the push guard, and exec Copilot CLI
#              with --yolo. The sandbox is the guard.
set -euo pipefail

PROXY_PORT=3128
COPILOT_HOME=/home/agent/.copilot

# ---------------------------------------------------------------------------
# Phase 1: root. Bring up egress controls, then re-exec ourselves as 'agent'.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    proxy_uid="$(id -u proxy)"

    # Materialize the egress allowlist squid reads. It is the single source of
    # truth for egress and is supplied by the host (the wrapper passes the
    # host-side config's domains in SANDBOX_ALLOWLIST). One dstdomain entry per
    # line; an empty list yields an empty file -> squid denies all (fail closed).
    # Written BEFORE squid starts, because squid reads the allowlist once at boot.
    mkdir -p /etc/squid
    : > /etc/squid/allowlist.txt
    for host in ${SANDBOX_ALLOWLIST:-}; do
        printf '%s\n' "$host" >> /etc/squid/allowlist.txt
    done
    echo "[entrypoint] wrote $(wc -l < /etc/squid/allowlist.txt) egress allowlist entries"

    echo "[entrypoint] starting filtering proxy (squid) on 127.0.0.1:${PROXY_PORT}"
    # squid daemonizes; its worker runs as the 'proxy' user, the only uid the
    # firewall below lets reach the network.
    squid -f /etc/squid/squid.conf

    echo "[entrypoint] waiting for proxy to accept connections"
    ready=0
    for _ in $(seq 1 100); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${PROXY_PORT}") 2>/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "[entrypoint] FATAL: proxy did not come up — refusing to start (fail closed)" >&2
        exit 1
    fi

    echo "[entrypoint] applying default-deny egress firewall (proxy-uid=${proxy_uid})"
    # Flush, then build an allow-list of OUTPUT rules and finally flip the
    # default policy to DROP. The agent (uid 1000) matches none of the ACCEPTs,
    # so its only reachable destination is loopback (the proxy).
    iptables -F
    iptables -X 2>/dev/null || true

    # Loopback: the agent -> proxy hop, and Docker's embedded DNS at 127.0.0.11.
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    # Return traffic for connections we already permitted.
    iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # ONLY the proxy uid may reach the network: DNS (to resolve allowlisted
    # hosts) and HTTP/HTTPS (to forward allowed requests). Nothing else.
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p udp --dport 53  -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p tcp --dport 53  -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p tcp --dport 80  -j ACCEPT
    iptables -A OUTPUT -m owner --uid-owner "$proxy_uid" -p tcp --dport 443 -j ACCEPT

    # Inbound dev-server ports (opt-in via `ports` in the host-side config; the
    # wrapper resolves them and passes the container ports in via SANDBOX_PORTS).
    for dev_port in ${SANDBOX_PORTS:-}; do
        case "$dev_port" in ''|*[!0-9]*) continue ;; esac
        iptables -A INPUT -p tcp --dport "$dev_port" -j ACCEPT
        echo "[entrypoint] allowing inbound dev-server port ${dev_port}/tcp"
    done

    # Default-deny everything else, inbound and out.
    iptables -P INPUT   DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT  DROP
    echo "[entrypoint] firewall active — agent has no path out except the proxy"

    # --- Make host-absolute config paths resolve inside the container ----------
    # Your real ~/.copilot lives at $HOST_COPILOT_DIR on the host (e.g.
    # /home/you/.copilot), and config copied from it may bake that absolute path.
    # Symlink the host path to the agent's real config dir so every baked-in
    # reference resolves. Done as root; the target is assembled in phase 2.
    if [ -n "${HOST_COPILOT_DIR:-}" ] && [ "$HOST_COPILOT_DIR" != "$COPILOT_HOME" ]; then
        mkdir -p "$(dirname "$HOST_COPILOT_DIR")"
        ln -sfn "$COPILOT_HOME" "$HOST_COPILOT_DIR"
        echo "[entrypoint] linked ${HOST_COPILOT_DIR} -> ${COPILOT_HOME} (host config paths resolve)"
    fi

    # Drop privileges to the agent user and re-run this script as phase 2.
    # NET_ADMIN and root are left behind here; the agent never holds them.
    exec runuser -u agent -- "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Phase 2: agent (uid 1000, no NET_ADMIN). Configure tooling and run Copilot.
# ---------------------------------------------------------------------------

# --- Verify the egress posture before handing control to the agent ------------
# Phase 1 only confirmed squid is *up*; it never confirmed the firewall actually
# *contains* the agent. Probe the real principal (uid 1000) now, same fail-closed
# stance as the proxy-startup wait.
#
#   1. HARD — a connection that BYPASSES the proxy must not reach the network.
#   2. HARD — a request THROUGH the proxy to a non-allowlisted host must be denied.
#   3. SOFT — a request through the proxy to an allowlisted host should succeed.
echo "[entrypoint] verifying egress posture (agent uid=$(id -u))"

if curl --noproxy '*' --silent --connect-timeout 5 --output /dev/null \
        http://1.1.1.1 2>/dev/null; then
    echo "[entrypoint] FATAL: agent reached the network directly, bypassing the proxy (firewall breach) — refusing to start" >&2
    exit 1
fi

if curl --silent --connect-timeout 5 --output /dev/null \
        https://sandbox-egress-canary.invalid 2>/dev/null; then
    echo "[entrypoint] FATAL: proxy forwarded a non-allowlisted host (squid is not denying) — refusing to start" >&2
    exit 1
fi

if curl --silent --connect-timeout 5 --max-time 10 --output /dev/null \
        https://api.github.com/zen 2>/dev/null; then
    echo "[entrypoint] egress posture OK — direct blocked, proxy denies non-allowlisted, allowlist reachable"
else
    echo "[entrypoint] WARNING: an allowlisted host was unreachable through the proxy — network down or allowlist too tight?" >&2
fi

# --- Assemble ~/.copilot from a read-only seed + a writable state dir ---------
# Isolation model: your real host config is mounted READ-ONLY at /seed and is
# only ever copied FROM — the agent can never write back to it, so it cannot
# plant hooks, settings, or configs that would later run in your normal host
# Copilot sessions. The mutable state worth keeping (sessions, logs) lives in
# /state, a dedicated host dir SEPARATE from your real ~/.copilot.
if [ -d /seed ]; then
    mkdir -p "$COPILOT_HOME"
    # Copy small config items out of the seed, skipping bulk/state paths.
    # installed-plugins is skipped here and symlinked read-only below (like
    # claude-isolated's plugin handling) — the agent cannot alter plugin code.
    for item in /seed/* /seed/.[!.]*; do
        [ -e "$item" ] || continue
        case "$(basename "$item")" in
            session-state|session-store.db|session-store.db-shm|session-store.db-wal|logs|cache|command-history-state.json|installed-plugins)
                continue ;;
        esac
        cp -r --preserve=mode "$item" "$COPILOT_HOME/" 2>/dev/null || true
    done
    # Plugins: read-only, straight from the host seed (no copy, cannot be altered).
    if [ -d /seed/installed-plugins ]; then
        rm -rf "$COPILOT_HOME/installed-plugins"
        ln -sfn /seed/installed-plugins "$COPILOT_HOME/installed-plugins"
        echo "[entrypoint] plugins linked read-only from host seed"
    fi
fi

# Persistent state -> /state (a host dir separate from your real ~/.copilot).
if [ -d /state ]; then
    mkdir -p /state/session-state /state/logs
    ln -sfn /state/session-state "$COPILOT_HOME/session-state"
    ln -sfn /state/logs          "$COPILOT_HOME/logs"

    # Persist pnpm's content-addressed store under /state so installs are cached
    # across sessions instead of re-downloading (and re-hitting egress) each run.
    mkdir -p /state/pnpm/store
    if ! grep -qs '^store-dir=' /home/agent/.npmrc 2>/dev/null; then
        echo 'store-dir=/state/pnpm/store' >> /home/agent/.npmrc \
            && echo "[entrypoint] pnpm store -> /state/pnpm/store (cached across sessions)"
    fi
fi

# --- Seed gh CLI auth from the host -------------------------------------------
# The host's ~/.config/gh is mounted read-only at /seed-gh. Copy it to the
# agent's config dir so both `gh` and `copilot` can use the host's OAuth tokens.
# The copy is writable so `gh auth setup-git` can update it.
GH_CONFIG_DIR=/home/agent/.config/gh
if [ -d /seed-gh ]; then
    mkdir -p "$GH_CONFIG_DIR"
    cp -r --preserve=mode /seed-gh/* "$GH_CONFIG_DIR/" 2>/dev/null || true
    echo "[entrypoint] seeded gh config from host (copilot + gh auth available)"
fi

# --- Graft host config into the sandbox's config.json -------------------------
# The sandbox's config.json is bind-mounted; graft host settings that make the
# session usable without re-login (trusted folders, first launch markers, etc.)
COPILOT_CONFIG="$COPILOT_HOME/config.json"
jsonc_to_json() {
    sed '/^[[:space:]]*\/\//d' "$1"
}
if [ -f /seed/config.json ] && command -v jq >/dev/null 2>&1; then
    [ -s "$COPILOT_CONFIG" ] || echo '{}' > "$COPILOT_CONFIG"
    # Graft login/onboarding markers AND installedPlugins from the seed.
    # installedPlugins carries the plugin registry (name, version, cache_path,
    # enabled). The cache_path references the HOST absolute path (e.g.
    # /home/ubuntu/.copilot/installed-plugins/...); it resolves inside the
    # container via the HOST_COPILOT_DIR symlink created in phase 1.
    markers="$(jsonc_to_json /seed/config.json | jq '{firstLaunchAt, appTipShown, reasoningSummariesCleanupDone, installedPlugins} | with_entries(select(.value != null))' 2>/dev/null || echo '{}')"
    if merged="$(jsonc_to_json "$COPILOT_CONFIG" | jq --argjson m "$markers" '. * $m' 2>/dev/null)"; then
        printf '%s\n' "$merged" > "$COPILOT_CONFIG"
        echo "[entrypoint] grafted host config markers + plugins into ~/.copilot/config.json"
    fi
fi

# Always trust /workspace inside the container.
if command -v jq >/dev/null 2>&1 && [ -f "$COPILOT_CONFIG" ]; then
    updated="$(jsonc_to_json "$COPILOT_CONFIG" | jq '.trustedFolders = (["/workspace"] + (.trustedFolders // []) | unique)' 2>/dev/null)" \
        && printf '%s\n' "$updated" > "$COPILOT_CONFIG"
fi

# Treat the bind-mounted workspace as trusted (it's owned by uid 1000 anyway).
git config --global --add safe.directory /workspace
git config --global --add safe.directory '*'

# Route all git hooks through our guard dir so the pre-push main-block applies
# regardless of what the repo ships. Best-effort: real protection is server-side.
git config --global core.hooksPath /etc/copilot-isolated/git-hooks

# Give commits an identity. Override via GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL in
# the env file (git also reads those two vars directly when making a commit).
git config --global user.name  "${GIT_AUTHOR_NAME:-copilot-isolated}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-copilot-isolated@localhost}"
git config --global init.defaultBranch main

# Wire git to authenticate to GitHub over HTTPS using the injected PAT, so the
# agent can fetch/push to allowlisted repos and `gh` works. No token -> no auth
# configured (the agent can still work on local repos / public clones).
if [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git 2>/dev/null \
        && echo "[entrypoint] git configured to auth via GH_TOKEN (gh credential helper)" \
        || echo "[entrypoint] WARNING: 'gh auth setup-git' failed; pushes may prompt" >&2
fi

# --- Optional project database (opt-in via config OR DATABASE_URL auto-detect) -
# Same contract as claude-isolated: a "database" object in
# /workspace/.copilot-isolated.json selects an engine, or auto-detect from
# DATABASE_URL. Best-effort, never fail-closed.

start_postgres() {
    local user="$1" name="$2" password="$3" port="$4"

    local id_re='^[A-Za-z_][A-Za-z0-9_]{0,62}$'
    if ! [[ "$user" =~ $id_re ]]; then
        echo "[entrypoint] WARNING: invalid database user '$user' (must match ${id_re}) — skipping database setup" >&2
        return 0
    fi
    if ! [[ "$name" =~ $id_re ]]; then
        echo "[entrypoint] WARNING: invalid database name '$name' (must match ${id_re}) — skipping database setup" >&2
        return 0
    fi
    case "$port" in
        ''|*[!0-9]*) echo "[entrypoint] WARNING: invalid database port '$port' — skipping database setup" >&2; return 0 ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "[entrypoint] WARNING: database port '$port' out of range — skipping database setup" >&2
        return 0
    fi

    local pgbin=/usr/lib/postgresql/16/bin
    local key="${SANDBOX_PROJECT_KEY:-default}"
    local pgdata="/state/pg/${key}/16"
    local logfile="/state/pg/${key}/postgres-16.log"
    mkdir -p "$pgdata"

    if [ ! -f "$pgdata/PG_VERSION" ]; then
        echo "[entrypoint] initializing Postgres cluster at $pgdata"
        if ! "$pgbin/initdb" -D "$pgdata" -U postgres \
                --auth-local=trust --auth-host=trust >/dev/null 2>&1; then
            echo "[entrypoint] WARNING: initdb failed — project database unavailable" >&2
            return 0
        fi
        {
            echo "listen_addresses = '127.0.0.1'"
            echo "unix_socket_directories = '/tmp'"
        } >> "$pgdata/postgresql.conf"
    fi

    if ! "$pgbin/pg_ctl" -D "$pgdata" -l "$logfile" -o "-p $port" -w -t 30 start >/dev/null 2>&1; then
        echo "[entrypoint] WARNING: postgres did not start on port $port — continuing without a database" >&2
        return 0
    fi
    echo "[entrypoint] postgres listening on 127.0.0.1:${port} (data: $pgdata)"

    local psql_base=("$pgbin/psql" -h 127.0.0.1 -p "$port" -U postgres -d postgres -tA)
    if [ "$("${psql_base[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$user'" 2>/dev/null)" != "1" ]; then
        printf '%s\n' "CREATE ROLE \"$user\" LOGIN SUPERUSER PASSWORD :'pw'" \
            | "${psql_base[@]}" -v pw="$password" >/dev/null 2>&1 \
            && echo "[entrypoint] created role '$user'"
    fi
    if [ "$("${psql_base[@]}" -c "SELECT 1 FROM pg_database WHERE datname='$name'" 2>/dev/null)" != "1" ]; then
        "${psql_base[@]}" -c "CREATE DATABASE \"$name\" OWNER \"$user\"" >/dev/null 2>&1 \
            && echo "[entrypoint] created database '$name' owned by '$user'"
    fi
}

urldecode() { printf '%b' "${1//%/\\x}"; }

autodetect_postgres() {
    local url="${DATABASE_URL:-}"
    if [ -z "$url" ]; then
        local f line
        for f in /workspace/.env /workspace/.env.local /workspace/.env.development; do
            [ -f "$f" ] || continue
            line="$(grep -aE '^[[:space:]]*(export[[:space:]]+)?DATABASE_URL=' "$f" 2>/dev/null | tail -1)" || true
            [ -n "$line" ] || continue
            url="${line#*=}"
            url="${url%$'\r'}"
            url="${url#\"}"; url="${url%\"}"
            url="${url#\'}"; url="${url%\'}"
            [ -n "$url" ] && break
        done
    fi
    [ -n "$url" ] || return 0
    case "$url" in postgres://*|postgresql://*) ;; *) return 0 ;; esac

    local rest authority path userinfo hostport host port user password dbname
    rest="${url#*://}"
    authority="${rest%%/*}"
    path="${rest#*/}"; [ "$path" = "$rest" ] && path=""
    dbname="${path%%\?*}"
    if [[ "$authority" == *"@"* ]]; then
        userinfo="${authority%@*}"; hostport="${authority##*@}"
    else
        userinfo=""; hostport="$authority"
    fi
    user="${userinfo%%:*}"
    if [[ "$userinfo" == *":"* ]]; then password="${userinfo#*:}"; else password=""; fi
    host="${hostport%%:*}"
    if [[ "$hostport" == *":"* ]]; then port="${hostport##*:}"; else port="5432"; fi

    case "$host" in localhost|127.0.0.1|::1|"") ;; *) return 0 ;; esac

    user="$(urldecode "$user")"
    password="$(urldecode "$password")"
    dbname="$(urldecode "$dbname")"

    [ -n "$user" ] || user="postgres"
    [ -n "$dbname" ] || dbname="$user"
    case "$port" in ''|*[!0-9]*) port="5432" ;; esac

    jq -nc --arg u "$user" --arg p "$password" --arg n "$dbname" --argjson port "$port" \
        '{user:$u,password:$p,name:$n,port:$port}'
}

setup_database() {
    local cfg=/workspace/.copilot-isolated.json
    command -v jq >/dev/null 2>&1 || return 0

    local mode=auto
    if [ -f "$cfg" ]; then
        mode="$(jq -r '
            if (has("database") and .database == false) then "off"
            elif (.database | type) == "object" then "explicit"
            else "auto" end' "$cfg" 2>/dev/null || echo auto)"
    fi
    [ "$mode" = "off" ] && return 0

    local dbtype user name password port
    if [ "$mode" = "explicit" ]; then
        dbtype="$(jq -r '.database.type // "postgres"' "$cfg")"
        user="$(jq -r '.database.user // "postgres"' "$cfg")"
        name="$(jq -r --arg u "$user" '.database.name // $u' "$cfg")"
        password="$(jq -r '.database.password // "postgres"' "$cfg")"
        port="$(jq -r '.database.port // 5432' "$cfg")"
    else
        local detected
        detected="$(autodetect_postgres)" || return 0
        [ -n "$detected" ] || return 0
        dbtype=postgres
        user="$(printf '%s' "$detected" | jq -r '.user')"
        name="$(printf '%s' "$detected" | jq -r '.name')"
        password="$(printf '%s' "$detected" | jq -r '.password')"
        port="$(printf '%s' "$detected" | jq -r '.port')"
        echo "[entrypoint] auto-detected local Postgres from DATABASE_URL (database '$name', user '$user', port $port)"
    fi

    case "$dbtype" in
        postgres) start_postgres "$user" "$name" "$password" "$port" ;;
        *) echo "[entrypoint] WARNING: unsupported database type '$dbtype' in .copilot-isolated.json — skipping" >&2 ;;
    esac
}

# Guarded so a database hiccup can never abort phase 2 (set -e is active).
setup_database || true

# A --yolo Copilot session in the workspace; the proxy + firewall + non-root
# user are what make that flag safe here. Any args the wrapper forwarded (e.g.
# --resume <id>) are copilot args per the documented contract.
copilot --yolo "$@"
