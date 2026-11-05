# Obsidian + MCP Deployment

**English** | [简体中文](README.zh-CN.md)

Deploy a browser-based Obsidian instance and an Obsidian MCP server with Docker Compose:

- `ignis`: the Obsidian Web UI at `http://127.0.0.1:8880`
- `obsidian-mcp`: built from the [`obsidian-mcp-http`](https://github.com/mrchipset/obsidian-mcp-http) fork, which serves Streamable HTTP natively at `http://127.0.0.1:8811/mcp`
- Both share the same vault directory

For the complete authentication, public-exposure, and IP-range restriction design, see [AUTHENTICATION.md](./AUTHENTICATION.md) (currently in Chinese).

## Prerequisites

- Docker Engine / Docker Desktop with Compose v2.17 or later
- A local checkout of `obsidian-mcp-http` containing the `Dockerfile`; see [Get the source](#get-the-obsidian-mcp-http-source) and point `MCP_SOURCE_DIR` at it
- A real vault: the directory must contain `.obsidian/`
- Network access to the npm registry on the **first build** (the image compiles the TypeScript sources). Runtime needs no downloads.
- If the target machine needs a proxy, set `HTTP_PROXY` / `HTTPS_PROXY` in `.env`; compose passes them to the image build

## Get the obsidian-mcp-http Source

The image is built from a local checkout of `obsidian-mcp-http`; no npm packages are downloaded at runtime. The repository is published in two places with identical content — pick either one:

| Source | URL |
|---|---|
| Gitee (better for networks in mainland China) | <https://gitee.com/mrchip233/obsidian-mcp-http> |
| GitHub | <https://github.com/mrchipset/obsidian-mcp-http> |

Clone it next to this project (matching the default `MCP_SOURCE_DIR=../obsidian-mcp-http`):

```bash
# pick one
git clone https://gitee.com/mrchip233/obsidian-mcp-http.git ../obsidian-mcp-http
git clone https://github.com/mrchipset/obsidian-mcp-http.git ../obsidian-mcp-http
```

Any other location works too — just update `MCP_SOURCE_DIR` in `.env` (relative paths resolve from the directory containing `docker-compose.yml`).

Confirm the build context is complete:

```bash
ls ../obsidian-mcp-http/Dockerfile ../obsidian-mcp-http/package.json
ls ../obsidian-mcp-http/src
```

Without git, use "Clone/Download → Download ZIP" on the repository page and point `MCP_SOURCE_DIR` at the extracted directory. It must contain `Dockerfile`, `package.json`, and `src/` directly — no extra nesting level.

## Quick Start

```bash
# 1. Generate the config
cp .env.example .env

# 2. Prepare a vault (example; you can also copy an existing vault)
mkdir -p vaults/test/.obsidian

# 3. Edit .env:
#    - MCP_SOURCE_DIR: path to the obsidian-mcp-http checkout
#    - PUID/PGID, ports, vault path, proxy settings
#    - MCP_API_KEY (openssl rand -hex 32)

# 4. Build the MCP image and start
docker compose up -d --build

# 5. Check
docker compose ps
curl -i http://127.0.0.1:8811/mcp        # 401 without a token
curl -i http://127.0.0.1:8880/api/vault/list
```

MCP client configuration:

```json
{
  "mcp": {
    "obsidian": {
      "type": "remote",
      "url": "http://127.0.0.1:8811/mcp",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:MCP_API_KEY}"
      }
    }
  }
}
```

opencode does not automatically load `.env` from the project directory. Set `MCP_API_KEY` in the current shell before starting opencode (use the value from the same variable in `.env`):

```powershell
# PowerShell: run before starting opencode
$env:MCP_API_KEY = (Get-Content .env | Where-Object { $_ -match '^MCP_API_KEY=' }) -replace '^MCP_API_KEY=',''
opencode
```

```bash
# bash/zsh
export MCP_API_KEY="$(grep '^MCP_API_KEY=' .env | cut -d= -f2-)"
opencode
```

After changing `.env` or `opencode.json`, run `opencode reload` (or restart opencode) so the MCP client reconnects.

## MCP Authentication

The HTTP transport enforces a bearer token. Compose passes `MCP_API_KEY` to the container as `OBSIDIAN_MCP_HTTP_TOKEN`, so every request must carry:

```text
Authorization: Bearer <MCP_API_KEY>
```

`X-API-Key` is **not** supported by this transport. There is no unauthenticated health endpoint; `GET /mcp` without a token returns `401`, and the container healthcheck uses the HTTP response status instead.

`MCP_API_KEY` lives only in `.env` (ignored by `.gitignore`); do not commit it. Compose refuses to start when it is empty. The server supports a single token: to rotate, update `.env`, update the client, and restart `obsidian-mcp`.

Verify:

```bash
# No token: 401
curl -i http://127.0.0.1:8811/mcp

# With token: no longer 401
curl -i -X POST http://127.0.0.1:8811/mcp \
  -H "Authorization: Bearer $MCP_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0.0"}}}'
```

## Access from a VPN Subnet (Optional)

MCP and ignis bind to `127.0.0.1` by default. To let clients on another network (for example an OpenVPN `10.8.0.x` subnet) reach them, keep the Docker bindings unchanged and run a userspace TCP forwarder on the host that listens on the tun0 address:

- `deploy/vpn-port-forward.py`: dependency-free Python asyncio forwarder
- `deploy/vpn-port-forward.service`: systemd unit with a dedicated `vpn-forward` user, boot autostart, and lifecycle tied to `openvpn-client@gitea`

Install (using `10.8.0.6` as the example address):

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin vpn-forward
sudo install -m 755 deploy/vpn-port-forward.py /usr/local/bin/vpn-port-forward.py
sudo install -m 644 deploy/vpn-port-forward.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-port-forward
```

Requirements and matching changes:

- Set `LISTEN_HOST` in the script to this host's actual tun0 address.
- Set `MCP_ALLOWED_HOST=10.8.0.6` in `.env`, otherwise MCP rejects the request with 403; recreate `obsidian-mcp` afterwards.
- Match `openvpn-client@gitea` in the unit to your actual OpenVPN instance name.

Verify:

```bash
ss -ltnp | grep -E '10.8.0.6:(8880|8811)'
curl -i http://10.8.0.6:8811/mcp   # 401 means forwarding and Host validation both work
```

From a `10.8.0.x` client, open `http://10.8.0.6:8880` and `http://10.8.0.6:8811/mcp`. The forwarder listens only on tun0, so the public and VPC interfaces stay closed; ignis has no authentication, so every machine that can join the VPN can read and write the vault.

## .env Variables

| Variable | Default | Description |
|---|---|---|
| `PUID` / `PGID` | 1000 | Vault owner; must match between ignis and MCP |
| `IGNIS_BIND` / `IGNIS_PORT` | 127.0.0.1 / 8880 | Web UI bind address and port |
| `MCP_BIND` / `MCP_PORT` | 127.0.0.1 / 8811 | MCP bind address and port |
| `MCP_ALLOWED_HOST` | 127.0.0.1 | Extra `Host` header accepted by the HTTP transport; set the LAN IP/hostname when `MCP_BIND=0.0.0.0` |
| `VAULT_ROOT` | ./vaults | Vault root mounted into ignis |
| `VAULT_DIR` | ./vaults/test | Single vault mounted into MCP; must be inside `VAULT_ROOT` |
| `VAULT_ID` | notes | `vault` parameter used by MCP tools |
| `MCP_API_KEY` | none (required) | Bearer token for every MCP request |
| `MCP_SOURCE_DIR` | ../obsidian-mcp-http | Build context: local checkout of `obsidian-mcp-http` |
| `MCP_IMAGE` | obsidian-mcp-http:2.1.0 | Tag produced by `docker compose build obsidian-mcp` |
| `DATA_DIR` | ./data | ignis application data |
| `WATCHER_PATCH` | ./patches/server-core-watcher.js | Polling watcher patch |
| `HTTP_PROXY` / `HTTPS_PROXY` | empty | Leave empty if no proxy is needed; also used as build args |
| `NO_PROXY` | localhost,... | Addresses that bypass the proxy |

All relative paths are resolved from the directory containing `docker-compose.yml`.

## Pinned Versions

| Component | Pinned value |
|---|---|
| ignis | `nobbe/ignis@sha256:8faba277...` (Obsidian 1.14.4) |
| Node | `node:22.23.4-bookworm-slim` (build and runtime base) |
| obsidian-mcp-http | `2.1.0` (`MCP_IMAGE` tag, built from `MCP_SOURCE_DIR`) |

`obsidian-mcp-http` is a fork of [StevenStavrakis/obsidian-mcp](https://github.com/StevenStavrakis/obsidian-mcp/tree/v2.0.1) (MIT) that adds the Streamable HTTP transport. The upstream stdio server plus `supergateway` wrapper are no longer used.

When upgrading ignis, also check `patches/server-core-watcher.js`: it is copied from the image's `watcher.js` and adds only the three `usePolling` lines.

## Common Pitfalls

1. **UID mismatch on Linux**
   - Set `PUID/PGID` to the owner of the vault directory: `stat -c '%u:%g' vaults`.
   - Then run `sudo chown -R $PUID:$PGID vaults data`.
   - Symptom: ignis reports `EACCES`, and notes written by MCP do not appear in the web UI at all.

2. **Build context not found**
   - `MCP_SOURCE_DIR` must point at a checkout that contains `Dockerfile`, `package.json`, and `src/`.
   - A relative value is resolved from this compose file's directory. Use an absolute path if the checkout lives elsewhere.

3. **Host header rejected after binding to a LAN address**
   - The transport validates the `Host` header (DNS-rebinding guard).
   - When `MCP_BIND=0.0.0.0` and clients connect through a LAN IP or hostname, set `MCP_ALLOWED_HOST` to that value and recreate the container.

4. **Hard-coded proxy**
   - On another machine without `host.docker.internal:10808`, the image build and Obsidian downloads can stall.
   - Regenerate `.env` from `.env.example` when moving machines; do not copy the local `.env`.

5. **Port or container name conflicts**
   - When running multiple deployments on one host, change `IGNIS_PORT`, `MCP_PORT`, `IGNIS_CONTAINER_NAME`, and `MCP_CONTAINER_NAME`.

6. **Slow first start**
   - Obsidian and npm packages must be downloaded; the entrypoint also tries to install `obsidian-headless`.
   - On a slow network it may stop at `[ignis] Installing obsidian-headless...`, and the web service is not up yet.
   - You can stop this optional install first to bring the service up:
     ```bash
     docker exec -u 0 ignis sh -c 'pkill -f "npm install obsidian-headless"'
     ```
   - The trade-off is that headless sync is unavailable; you can install it later with `docker exec -u 0 ignis npm install -g --prefix /usr/local obsidian-headless`.

7. **Missing `patches/server-core-watcher.js`**
   - Docker creates a missing bind source as a directory, which makes mounting to a file path fail.
   - Copy the whole project directory, or point `WATCHER_PATCH` at a real file.

8. **Source changes are not picked up**
   - The image is built from `MCP_SOURCE_DIR`; rebuilding the container does not rebuild the image.
   - Run `docker compose build obsidian-mcp && docker compose up -d obsidian-mcp` after changing the fork.

## Directory Layout

```text
.
├── docker-compose.yml
├── .env.example
├── .env                 # local only, not committed
├── deploy/
│   ├── vpn-port-forward.py
│   └── vpn-port-forward.service
├── patches/
│   └── server-core-watcher.js
├── vaults/
│   └── test/
│       ├── .obsidian/
│       └── *.md
└── data/                # ignis runtime data

../obsidian-mcp-http/    # MCP source checkout (MCP_SOURCE_DIR)
├── Dockerfile
├── package.json
└── src/
```

## Security

- `ignis` and MCP bind to `127.0.0.1` by default.
- MCP requires a bearer token, but it is a static shared secret with no user identity, scopes, or audit.
- The native transport has no `--tools` whitelist; every configured tool is reachable with a valid token.
- `ignis` has no built-in login or authentication; do not expose its port directly to the public internet.
- If you set `MCP_BIND=0.0.0.0`, put it behind a TLS reverse proxy, SSH tunnel, or Tailscale, and set `MCP_ALLOWED_HOST`.
- Do not commit `.env` to the repository (`.gitignore` already ignores it).

## License

MIT. See [LICENSE](./LICENSE).
