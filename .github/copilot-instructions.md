# Repository instructions for Copilot

## Commands

- Build the sandbox image: `docker build -t copilot-sandbox:latest .`
- Build with pinned tool overrides:
  - `docker build -t copilot-sandbox:latest --build-arg COPILOT_CLI_VERSION=1.1.0 .`
  - `docker build -t copilot-sandbox:latest --build-arg PNPM_VERSION=12.0.0 .`
  - `docker build -t copilot-sandbox:latest --build-arg POSTGRES_VERSION=17 .`
- Install the host wrapper after changing `copilot-isolated`: `sudo install -m 755 ./copilot-isolated /usr/local/bin/copilot-isolated`

## Architecture

This project runs `copilot --yolo` inside a hardened Docker container. The host-side `copilot-isolated` wrapper validates Docker/jq prerequisites, scaffolds the user env/config files, computes the per-project identity, composes egress domains, read-only mounts, and dev-server port mappings, then launches the image with `/workspace` mounted read-write and host Copilot/GitHub config mounted as read-only seeds.

The container starts through `entrypoint.sh` in two phases. Phase 1 runs as root only long enough to write `/etc/squid/allowlist.txt` from `SANDBOX_ALLOWLIST`, start squid, program a default-deny iptables policy that lets only the `proxy` uid reach DNS/HTTP/HTTPS, allow configured inbound dev-server ports, and drop to the `agent` user. Phase 2 runs as `agent`, verifies direct egress is blocked and non-allowlisted proxy egress is denied, assembles writable Copilot state from `/seed` and `/state`, seeds `gh` auth, installs the sandbox git hook path, optionally starts a per-project Postgres cluster, then execs `copilot --yolo`.

`squid.conf` is the domain-filtering chokepoint: it listens only on `127.0.0.1:3128`, allows destinations listed in `/etc/squid/allowlist.txt`, denies everything else, and logs to stdout/stderr. `git-guard/pre-push` is a convenience guard installed through global `core.hooksPath`; it blocks pushes to `main` and `master`, but branch protection is still the real enforcement.

## Repository-specific conventions

- Treat `~/.config/copilot-isolated/config.json` as the single source of truth for egress, mounts, and ports. The wrapper reads it, but never mounts it into the container; do not move host-controlled security policy into image files or workspace-readable files.
- Preserve the fail-closed security posture. Firewall/proxy startup failures and hard egress self-test failures should exit before Copilot starts; optional conveniences such as Postgres setup may warn and continue.
- Keep host configuration isolated. `/seed` and `/seed-gh` are read-only inputs; mutable Copilot sessions, logs, pnpm store, and database files belong under `/state`.
- Do not commit secrets or local runtime config. `.gitignore` covers env files, token-like files, and `.copilot-isolated/` state.
- Changes to `Dockerfile`, `entrypoint.sh`, `squid.conf`, or `git-guard/pre-push` require rebuilding the image. Changes to `copilot-isolated` require reinstalling the wrapper.
- Keep Dockerfile tool versions reproducible through build args. If changing `POSTGRES_VERSION`, also update runtime paths in `Dockerfile` and `entrypoint.sh` that currently reference PostgreSQL 16 explicitly.
- For egress domains, use squid `dstdomain` semantics from the README: `.example.com` matches the apex and subdomains, while `example.com` matches only that exact host. Avoid overlapping entries such as both `.github.com` and `github.com`.
- Dev-server ports are configured on the host side. The wrapper publishes Docker ports and passes container ports through `SANDBOX_PORTS`; the entrypoint only opens matching inbound iptables rules.
- `.copilot-isolated.json` in a target project controls only the optional project database behavior; keep it local and uncommitted.

## MCP servers

If adding MCP support for this sandbox, configure/install servers on the host side and make their runtime domains explicit in `~/.config/copilot-isolated/config.json`; do not rely on the agent being able to widen egress from inside `/workspace`. GitHub MCP is the most relevant default for repo, issue, and PR work. Playwright or Context7 MCP can also fit the image's bundled browser/docs tooling, but keep any required credentials in host config or the env file, not in this repository.
