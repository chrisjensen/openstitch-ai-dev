# claude-opensnitch

Process-scoped OpenSnitch rules for a headless Linux dev box. Default-deny outbound, per-tool allowlists, designed so a malicious npm/pip/cargo postinstall can't phone home even though `node`/`python3` are otherwise trusted.

## Quickstart

1. **Install the daemon** (Ubuntu 24.04):
   ```bash
   sudo apt install opensnitch
   ```

2. **Install rules** (copies into `/etc/opensnitchd/`, never overwrites):
   ```bash
   git clone <this-repo> ~/src/claude-opensnitch
   cd ~/src/claude-opensnitch
   sudo ./install.sh
   ```

3. **Audit before enforcing.** The shipped config is `DefaultAction: deny`; flip it to `allow` for the first 24–48h so nothing breaks while you confirm the rules cover real workflows:
   ```bash
   sudo sed -i 's/"DefaultAction": "deny"/"DefaultAction": "allow"/' /etc/opensnitchd/default-config.json
   sudo systemctl restart opensnitch
   ```
   Run normal workflows (claude, npm install, cargo build, aws s3, git push). Then check what the rules **would have** denied:
   ```bash
   journalctl -u opensnitch --since "24 hours ago" | grep -iE "denied|drop"
   ```

4. **Enforce.** Flip back to deny and restart:
   ```bash
   sudo sed -i 's/"DefaultAction": "allow"/"DefaultAction": "deny"/' /etc/opensnitchd/default-config.json
   sudo systemctl restart opensnitch
   ```

5. **(Optional) Interactive prompts via [ostui](https://github.com/xlfe/ostui)** — a TUI that replaces the Qt GUI, ideal for headless SSH. Build, run in tmux, and the daemon will route prompts to it for any novel flow:
   ```bash
   git clone https://github.com/xlfe/ostui ~/src/ostui && cd ~/src/ostui && make build
   tmux new -s ostui './ostui --socket unix:///tmp/osui.sock --default-action deny'
   ```

## Layout

```
default-config.json     # daemon config (Server.Address, DefaultAction, LogLevel)
lists/*.txt             # domain allowlists, one host per line
rules/NNN-name.json     # rules, numeric prefix orders evaluation
install.sh              # copy-only installer; never overwrites
```

## Tuning rules

- **Add a domain to an existing list**: edit `lists/foo-domains.txt`, then replace the live copy. The installer never overwrites, so you must remove the live file first:
  ```bash
  sudo rm /etc/opensnitchd/lists/foo-domains.txt && sudo ./install.sh
  ```
  Daemon hot-reloads on file change — no restart needed for list edits.
- **Add a new rule**: drop a new `rules/NNN-name.json`, re-run `sudo ./install.sh`.
- **Edit an existing rule**: remove the live copy, re-run installer.
- **Find what's being denied**: `journalctl -u opensnitch -f | grep -i deny`.

## What's covered out of the box

| Rule | Process | Destination |
|---|---|---|
| `000-loopback` | any | `127.0.0.0/8`, `::1` |
| `001-dns-to-stub` | any | `127.0.0.53:53` (systemd-resolved only) |
| `010/011-system-*` | `apt`, `snapd` | Ubuntu/Snap mirrors |
| `020/021-git/gh` | `git`, `git-remote-https`, `gh` | GitHub |
| `030-npm-fetch` | `node` running `npm`/`pnpm`/`yarn`/`npx` | npm registry |
| `050-cargo` | `rustup` (covers cargo, rustc) | crates.io, rust-lang.org |
| `060-uv`, `061-pip` | `uv`, `python3 -m pip` | PyPI |
| `070-aws-cli` | aws CLI v2 | regional `*.amazonaws.com` |
| `080a/b-claude-*` | `node` running Claude Code | Anthropic + WebFetch allowlist |
| `081a/b-user-node-*` | `node` running scripts under `~/src/` | LLM APIs + S3 |
| `090-docker-daemon` | `dockerd`, `containerd` | Docker Hub, ghcr.io |

Everything else: denied.

## Caveats

- **Hard-coded paths**: rules pin to `/home/chris/` and the current nvm/aws-cli/Claude versions. Adapt before deploying on another box or after major upgrades.
- **Native postinstalls** (sharp, esbuild, node-gyp) that fetch prebuilts from `github.com/releases` will be denied. Either pre-fetch, or add a scoped allow.
- **Containers**: traffic from Docker containers is attributed to `dockerd`, not the in-container process. Layer in-container egress separately if needed.
- **Cmdline-based rules are fragile** — Claude Code or nvm upgrades may shift paths and need rule updates.
