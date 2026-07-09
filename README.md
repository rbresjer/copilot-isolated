# copilot-isolated

Run [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli)
with full permissions (`--yolo`) inside a hardened Docker container so the host
doesn't have to trust the agent.

```sh
cd ~/my-project && copilot-isolated
```

The AI agent gets unrestricted tool use — shell commands, file edits, network
requests — while the **container** enforces the actual security boundary:

- **Egress firewall** — all outbound traffic goes through a domain-allowlist
  proxy. The agent cannot reach hosts you haven't explicitly permitted.
- **Config isolation** — your host `~/.copilot` and `~/.config/gh` are
  read-only seeds. The agent cannot plant configs, hooks, or plugins that would
  run in your normal sessions.
- **Git guard** — pushes to `main`/`master` are blocked (real protection is
  server-side branch protection; this is a convenience).
- **Resource limits** — capped CPU, memory, and PIDs prevent runaway processes.

Each invocation is a fresh, ephemeral container. Many can run concurrently (one
per tmux pane / project) with no shared state between projects.

---

## Table of contents

- [Quick start](#quick-start)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Authentication](#authentication)
- [Plugins](#plugins)
- [Egress allowlist](#egress-allowlist)
- [Dev-server ports](#dev-server-ports)
- [Read-only mounts](#read-only-mounts)
- [Project databases](#project-databases)
- [Security model](#security-model)
- [Configuration reference](#configuration-reference)
- [Environment variables](#environment-variables)
- [Building](#building)
- [Updating](#updating)
- [What's in the box](#whats-in-the-box)
- [Architecture](#architecture)

---

## Quick start

```sh
# 1. Clone this repo
git clone https://github.com/youruser/copilot-isolated.git
cd copilot-isolated

# 2. Build the Docker image
docker build -t copilot-sandbox:latest .

# 3. Install the wrapper script
sudo install -m 755 ./copilot-isolated /usr/local/bin/copilot-isolated

# 4. First run — scaffolds the env file, then exits
cd ~/my-project && copilot-isolated
# -> "created env template at ~/.config/copilot-isolated/env — fill in GH_TOKEN, then re-run"

# 5. Edit the env file with your token and identity
vim ~/.config/copilot-isolated/env

# 6. Run for real
cd ~/my-project && copilot-isolated
```

## Prerequisites

- **Docker** (tested with Docker Engine 24+)
- **jq** (for config parsing)
- **GitHub Copilot subscription** (Individual, Business, or Enterprise)
- A **fine-grained PAT** with the "Copilot Requests" permission, or an existing
  `gh auth login` session

Target host architecture: **arm64/aarch64** (the Dockerfile uses
`node:22-bookworm-slim` which supports both arm64 and amd64).

## Installation

### Build the image

```sh
docker build -t copilot-sandbox:latest .
```

This takes a few minutes on the first build (downloads Node, PostgreSQL,
Terraform, Chromium, etc.). Subsequent rebuilds use layer caching and are fast.

### Install the wrapper

```sh
sudo install -m 755 ./copilot-isolated /usr/local/bin/copilot-isolated
```

The wrapper is a bash script that runs on the **host** — it assembles the
Docker command with the right mounts, env vars, and firewall config. It is NOT
inside the image.

### Set up credentials

On first run, the wrapper creates `~/.config/copilot-isolated/env`:

```sh
# copilot-isolated environment — NOT committed. One VAR=value per line.
GH_TOKEN=github_pat_...
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com
# Optional: override just for Copilot inference (takes precedence over GH_TOKEN)
# COPILOT_GITHUB_TOKEN=github_pat_...
```

**Token requirements:**
- Fine-grained PAT (v2) — classic tokens (`ghp_`) are NOT supported by Copilot CLI
- Permission: "Copilot Requests" (required for inference)
- Optional: "Contents: Read & Write" + "Pull Requests: Read & Write" on repos
  you want the agent to push to

## Usage

```sh
# Interactive session in current directory
cd ~/my-project && copilot-isolated

# Pass any copilot CLI flags
copilot-isolated --model gpt-5.5
copilot-isolated --resume
copilot-isolated --continue
copilot-isolated -p "Fix the failing tests"

# Non-interactive one-shot
copilot-isolated -p "Add error handling to the auth module"
```

All arguments after `copilot-isolated` are passed directly to `copilot --yolo`.

### Multiple concurrent sessions

Each project gets its own container. Run them in separate terminals:

```sh
# Terminal 1
cd ~/project-a && copilot-isolated

# Terminal 2
cd ~/project-b && copilot-isolated
```

## Authentication

Copilot CLI checks these in order of precedence:

| Source | How to configure |
|---|---|
| `COPILOT_GITHUB_TOKEN` env var | Set in `~/.config/copilot-isolated/env` |
| `GH_TOKEN` env var | Set in `~/.config/copilot-isolated/env` |
| `gh` CLI credential store | Automatic — `~/.config/gh` is seeded into the container |

The sandbox seeds your host `~/.config/gh` (read-only) into the container, so
if you've already run `gh auth login` on the host, Copilot will authenticate
automatically without needing a token in the env file. However, you'll still
need `GH_TOKEN` in the env file for git push operations.

## Plugins

Plugins installed on the **host** are automatically available in the sandbox —
no extra configuration needed.

### Installing a plugin

Install plugins on the host (not inside the sandbox):

```sh
# Add a marketplace (if not already registered)
copilot plugin marketplace add obra/superpowers-marketplace

# Install from the marketplace
copilot plugin install superpowers@superpowers-marketplace

# Or install directly from a GitHub repo
copilot plugin install owner/repo
```

Then just run `copilot-isolated` — the plugin is available.

### How it works

- `~/.copilot/installed-plugins/` is symlinked **read-only** from the host seed
  — the agent can use plugins but cannot modify or install new ones
- `settings.json` (marketplace registrations, enabled state) is copied from the
  host seed
- `installedPlugins` from `config.json` is grafted into the sandbox's config
- The `HOST_COPILOT_DIR` symlink makes absolute `cache_path` references resolve
  inside the container

### Installing plugins that need network

Some plugins (e.g., MCP servers) make network requests at runtime. Add their
domains to the [egress allowlist](#egress-allowlist):

```json
{
  "domains": [
    ".github.com",
    ".some-plugin-api.com"
  ]
}
```

## Egress allowlist

The **single source of truth** for what the agent can reach on the network.
Lives in `~/.config/copilot-isolated/config.json` — this file is **never
mounted** into the container, so the agent cannot widen its own egress.

### Default domains (seeded on first run)

```
.github.com                         GitHub APIs, repos, auth
.githubusercontent.com              GitHub raw content
.githubcopilot.com                  Copilot inference
.api.githubcopilot.com              Copilot API
.npmjs.org / .npmjs.com             npm registry
pypi.org / .pythonhosted.org        Python packages
.playwright.azureedge.net           Playwright browsers
.nodejs.org                         Node.js downloads
.hashicorp.com                      Terraform
registry.terraform.io               Terraform providers
```

### Editing the allowlist

Edit `~/.config/copilot-isolated/config.json` and re-run — **no rebuild or
re-install** required:

```json
{
  "domains": [
    ".github.com",
    ".npmjs.org",
    ".my-internal-api.company.com"
  ]
}
```

### Syntax

Uses squid `dstdomain` semantics:
- **`.example.com`** — matches `example.com` AND all subdomains (`api.example.com`, etc.)
- **`example.com`** — matches that exact host only

**⚠️ Do not overlap entries** (e.g., both `github.com` and `.github.com`) — squid
refuses to start, which means no network (fails closed).

### Per-project domains

```json
{
  "domains": ["...global..."],
  "projects": {
    "/home/you/my-project": {
      "domains": [".project-specific-api.com"]
    }
  }
}
```

Global and per-project domains are composed additively.

## Dev-server ports

Expose container dev-server ports to the host (e.g., for testing a web app):

```json
{
  "ports": ["3000", "5173"],
  "projects": {
    "/home/you/my-webapp": {
      "ports": ["3000", "8080:8080"]
    }
  }
}
```

- **Bare port** (`"3000"`) — host port is auto-assigned from a deterministic
  per-project lane (20000–51999). Same project always gets the same host port.
- **Explicit** (`"8080:8080"`) — `HOST:CONTAINER`.

Ports bind to the host's **Tailscale IP** by default (reachable from other
tailnet clients). No Tailscale → falls back to `127.0.0.1`. Override with
`COPILOT_ISOLATED_BIND_IP`.

**Note:** The dev server inside the container must bind `0.0.0.0`, not
`localhost`, for the port forward to work.

## Read-only mounts

Mount additional host directories into the container (read-only, same path):

```json
{
  "mounts": ["/data/shared-libs", "/opt/company-tools"],
  "projects": {
    "/home/you/my-project": {
      "mounts": ["/data/datasets"]
    }
  }
}
```

This is useful for shared libraries, datasets, or reference code the agent
should be able to read but never modify.

## Project databases

The sandbox can auto-provision a **PostgreSQL** instance per project — useful for
full-stack projects that need a real database.

### Auto-detection (zero config)

If your project has a `DATABASE_URL` in `.env`, `.env.local`, or
`.env.development` that points to `localhost`, the sandbox automatically starts a
matching Postgres cluster:

```sh
# .env
DATABASE_URL=postgres://myapp:secret@localhost:5432/myapp_dev
```

### Explicit config

Create `.copilot-isolated.json` in your project root (gitignored):

```json
{
  "database": {
    "type": "postgres",
    "user": "myapp",
    "password": "secret",
    "name": "myapp_dev",
    "port": 5432
  }
}
```

### Opt-out

```json
{
  "database": false
}
```

Database data persists across sessions under `~/.copilot-isolated/pg/<project-key>/`.

## Security model

The guardrail is the container, not a permission prompt.

### Two-phase entrypoint

| Phase | Runs as | Does |
|---|---|---|
| 1 | `root` | Writes egress allowlist, starts squid, programs iptables firewall, creates config path symlinks, drops to agent |
| 2 | `agent` (uid 1000) | Verifies egress posture (fail-closed), assembles config from seeds, configures git/gh, optionally starts Postgres, runs `copilot --yolo` |

Capabilities (`NET_ADMIN`, `SETUID`, `SETGID`) are granted only to root in
phase 1 and vanish on the uid change — the agent process holds **none**.

### Egress chokepoint (two independent layers)

Both must agree for traffic to leave the container:

1. **iptables** (`OUTPUT` chain, default policy `DROP`) — only the `proxy` uid
   (squid) can reach the network (UDP/TCP 53 for DNS, TCP 80/443 for HTTP/S).
   The agent uid's packets to anything but loopback are silently dropped.
2. **squid** (listening on `127.0.0.1:3128`) — forwards only to hostnames in
   `/etc/squid/allowlist.txt`; `CONNECT` (HTTPS tunnel) restricted to port 443
   so the proxy cannot become a generic TCP relay.

The agent is forced through squid via `HTTP_PROXY`/`HTTPS_PROXY` env vars baked
into the image.

### Egress self-test (fail-closed boot gate)

Before launching Copilot, the entrypoint probes the actual agent uid:

| Check | Type | What it proves |
|---|---|---|
| Direct connection to `1.1.1.1:80` bypassing proxy | **HARD** (blocks boot) | iptables OUTPUT drop is working |
| Proxied request to `sandbox-egress-canary.invalid` | **HARD** (blocks boot) | squid deny-all is in force |
| Proxied request to `api.github.com/zen` | SOFT (warns) | Allowlisted host is reachable |

A firewall or squid misconfiguration launches **nothing** instead of silently
opening the box.

### Config isolation

| Host path | Mounted at | Access | Purpose |
|---|---|---|---|
| `~/.copilot` | `/seed` | read-only | Seed settings, plugins |
| `~/.config/gh` | `/seed-gh` | read-only | Auth tokens |
| `~/.copilot-isolated` | `/state` | read-write | Persistent sessions/logs |
| `$PWD` | `/workspace` | read-write | Your project |

The agent **cannot** write back to your host config — so it cannot plant hooks,
settings, plugins, or a malicious config that would run in your normal Copilot
sessions.

### Additional hardening

- `--cap-drop ALL` — no Linux capabilities for the agent process
- `--security-opt no-new-privileges` — cannot regain privileges via setuid binaries
- `--pids-limit 512` — prevents fork bombs
- `--memory 4g` — OOM kills rather than swapping the host
- Git `core.hooksPath` points to the sandbox's own pre-push guard

## Configuration reference

### Host-side config (`~/.config/copilot-isolated/config.json`)

**Never mounted into the container** — the agent cannot read or modify it.

```json
{
  "domains": [
    ".github.com",
    ".githubcopilot.com",
    ".npmjs.org"
  ],
  "projects": {
    "/absolute/path/to/project": {
      "domains": [".extra-api.com"],
      "mounts": ["/data/shared"],
      "ports": ["3000"]
    }
  },
  "mounts": ["/opt/global-tools"],
  "ports": []
}
```

| Key | Type | Description |
|---|---|---|
| `domains` | `string[]` | Global egress allowlist (squid dstdomain entries) |
| `mounts` | `string[]` | Global read-only host paths to mount |
| `ports` | `string[]` | Global dev-server ports to publish |
| `projects` | `object` | Per-launch-directory overrides (composed additively) |

### Env file (`~/.config/copilot-isolated/env`)

```sh
GH_TOKEN=github_pat_...
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com
# COPILOT_GITHUB_TOKEN=github_pat_...
```

### Per-project config (`/workspace/.copilot-isolated.json`)

Optional, gitignored. Only controls the database for now:

```json
{
  "database": {
    "type": "postgres",
    "user": "myapp",
    "name": "myapp_dev",
    "password": "secret",
    "port": 5432
  }
}
```

## Environment variables

Override the wrapper's defaults:

| Variable | Default | Purpose |
|---|---|---|
| `COPILOT_ISOLATED_IMAGE` | `copilot-sandbox:latest` | Docker image to use |
| `COPILOT_ISOLATED_ENV` | `~/.config/copilot-isolated/env` | Path to env file |
| `COPILOT_ISOLATED_COPILOT_DIR` | `~/.copilot` | Host Copilot config directory |
| `COPILOT_ISOLATED_GH_DIR` | `~/.config/gh` | Host gh config directory |
| `COPILOT_ISOLATED_STATE` | `~/.copilot-isolated` | Persistent sandbox state |
| `COPILOT_ISOLATED_CONFIG` | `~/.config/copilot-isolated/config.json` | Host-side config file |
| `COPILOT_ISOLATED_CPUS` | `1.5` | CPU limit for container |
| `COPILOT_ISOLATED_BIND_IP` | Tailscale IP / `127.0.0.1` | Address to bind published ports |

## Building

```sh
# Default build
docker build -t copilot-sandbox:latest .

# Pin a different Copilot CLI version
docker build -t copilot-sandbox:latest --build-arg COPILOT_CLI_VERSION=1.1.0 .

# Pin a different pnpm version
docker build -t copilot-sandbox:latest --build-arg PNPM_VERSION=12.0.0 .

# Pin a different Postgres major
docker build -t copilot-sandbox:latest --build-arg POSTGRES_VERSION=17 .
```

### What requires what

| Change | Action needed |
|---|---|
| Edit `Dockerfile`, `entrypoint.sh`, `squid.conf`, `git-guard/pre-push` | `docker build` (rebuild) |
| Edit `copilot-isolated` | `sudo install -m 755 ./copilot-isolated /usr/local/bin/copilot-isolated` (re-install wrapper) |
| Edit `~/.config/copilot-isolated/config.json` (egress, mounts, ports) | Nothing — just re-run |
| Edit `~/.config/copilot-isolated/env` (tokens, identity) | Nothing — just re-run |
| Install a plugin on the host | Nothing — just re-run |

## Updating

### Update Copilot CLI version

```sh
# Check latest version
npm info @github/copilot version

# Rebuild with new version
docker build -t copilot-sandbox:latest --build-arg COPILOT_CLI_VERSION=X.Y.Z .
```

### Update the wrapper

```sh
git pull
sudo install -m 755 ./copilot-isolated /usr/local/bin/copilot-isolated
```

## What's in the box

| Component | Version | Purpose |
|---|---|---|
| Node.js | 22 LTS | Runtime for Copilot CLI |
| GitHub Copilot CLI | 1.0.69 (pinned) | AI coding agent |
| squid | Debian bookworm | Domain-filtering forward proxy |
| iptables | Debian bookworm | Default-deny egress firewall |
| PostgreSQL | 16 (pinned) | Opt-in per-project databases |
| Terraform | Latest (HashiCorp repo) | Infrastructure as code |
| Playwright + Chromium | Latest | Browser automation & testing |
| GitHub CLI (gh) | Latest (GitHub repo) | GitHub operations (PRs, issues, auth) |
| Python 3 | Debian bookworm | General scripting |
| pnpm | 11.5.1 (pinned, via corepack) | Fast package management |
| ESLint | 9 (global fallback) | Linting when projects lack a local copy |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Host                                                   │
│                                                         │
│  ~/.config/copilot-isolated/config.json  (NEVER mounted)│
│  ~/.config/copilot-isolated/env          (--env-file)   │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Container (copilot-sandbox)                      │  │
│  │                                                   │  │
│  │  /seed     ← ~/.copilot (read-only)              │  │
│  │  /seed-gh  ← ~/.config/gh (read-only)            │  │
│  │  /state    ← ~/.copilot-isolated (read-write)    │  │
│  │  /workspace ← $PWD (read-write)                  │  │
│  │                                                   │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │  Agent (uid 1000, no capabilities)          │  │  │
│  │  │                                             │  │  │
│  │  │  copilot --yolo                             │  │  │
│  │  │      ↓ HTTP_PROXY                           │  │  │
│  │  │  squid (127.0.0.1:3128, allowlist only)     │  │  │
│  │  │      ↓ iptables (proxy uid only)            │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  │                                                   │  │
│  │  iptables: OUTPUT default DROP                    │  │
│  │            only 'proxy' uid → DNS/80/443          │  │
│  └───────────────────────────────────────────────────┘  │
│                        ↓                                │
│              Allowed domains only                        │
└─────────────────────────────────────────────────────────┘
```

## License

MIT
