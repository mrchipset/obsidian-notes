# Obsidian + MCP Deployment

**English** | [简体中文](README.zh-CN.md)

Deploy a browser-based Obsidian instance and an Obsidian MCP server with Docker Compose:

- `ignis`: the Obsidian Web UI at `http://127.0.0.1:8080`
- `obsidian-mcp`: wraps the stdio `obsidian-mcp` server as Streamable HTTP at `http://127.0.0.1:8811/mcp`
- Both share the same vault directory

For the complete authentication, public-exposure, and IP-range restriction design, see [AUTHENTICATION.md](./AUTHENTICATION.md) (currently in Chinese).

## Prerequisites

- Docker Engine / Docker Desktop with Compose v2.17 or later
- A real vault: the directory must contain `.obsidian/`
- Network access to the npm registry and GitHub on first start (to download Obsidian and npm packages)
- If the target machine needs a proxy, set `HTTP_PROXY` / `HTTPS_PROXY` in `.env`

## Quick Start

```bash
# 1. Generate the config
cp .env.example .env

# 2. Prepare a vault (example; you can also copy an existing vault)
mkdir -p vaults/test/.obsidian

# 3. Edit .env: confirm PUID/PGID, ports, vault path, and proxy settings
#    Set MCP_API_KEY (openssl rand -hex 32)
#    On Windows/macOS Docker Desktop, 1000 is usually fine

# 4. Start
docker compose up -d

# 5. Check
docker compose ps
curl http://127.0.0.1:8811/healthz
curl http://127.0.0.1:8080/api/vault/list
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
        "X-API-Key": "{env:MCP_API_KEY}"
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

## MCP Authentication

supergateway 4.2.1 natively supports a static API key. Compose enables it through `--apiKey`, so every MCP request must carry one of these headers:

- `X-API-Key: <MCP_API_KEY>`
- `Authorization: Bearer <MCP_API_KEY>`

The `/healthz` endpoint is not protected by the API key. It is intended for container-internal checks and must not be exposed publicly.

`MCP_API_KEY` lives only in `.env` (ignored by `.gitignore`); do not commit it. To rotate the key, update `.env` and restart `obsidian-mcp`. supergateway also accepts multiple keys at once, so you can add a new key before removing the old one.

Verify:

```bash
# No key: should return 401
curl -i http://127.0.0.1:8811/mcp

# With key: should no longer return 401
curl -i -H "X-API-Key: $MCP_API_KEY" http://127.0.0.1:8811/mcp
```

## .env Variables

| Variable | Default | Description |
|---|---|---|
| `PUID` / `PGID` | 1000 | Vault owner; must match between ignis and MCP |
| `IGNIS_BIND` / `IGNIS_PORT` | 127.0.0.1 / 8080 | Web UI bind address and port |
| `MCP_BIND` / `MCP_PORT` | 127.0.0.1 / 8811 | MCP bind address and port |
| `VAULT_ROOT` | ./vaults | Vault root mounted into ignis |
| `VAULT_DIR` | ./vaults/test | Single vault mounted into MCP; must be inside `VAULT_ROOT` |
| `VAULT_ID` | notes | `vault` parameter used by MCP tools |
| `MCP_API_KEY` | none (required) | supergateway static API key; `X-API-Key` or `Authorization: Bearer` |
| `DATA_DIR` | ./data | ignis application data |
| `WATCHER_PATCH` | ./patches/server-core-watcher.js | Polling watcher patch |
| `HTTP_PROXY` / `HTTPS_PROXY` | empty | Leave empty if no proxy is needed |
| `NO_PROXY` | localhost,... | Addresses that bypass the proxy |

All paths are relative to the directory containing `docker-compose.yml`.

## Pinned Versions

| Component | Pinned value |
|---|---|
| ignis | `nobbe/ignis@sha256:8faba277...` (Obsidian 1.14.4) |
| Node | `node:22.23.4-bookworm-slim` |
| supergateway | `4.2.1` |
| obsidian-mcp | `2.0.1` |

obsidian-mcp source: [StevenStavrakis/obsidian-mcp](https://github.com/StevenStavrakis/obsidian-mcp/tree/v2.0.1) (MIT).

When upgrading ignis, also check `patches/server-core-watcher.js`: it is copied from the image's `watcher.js` and adds only the three `usePolling` lines.

## Common Pitfalls

1. **UID mismatch on Linux**
   - Set `PUID/PGID` to the owner of the vault directory: `stat -c '%u:%g' vaults`.
   - Then run `sudo chown -R $PUID:$PGID vaults data`.
   - Symptom: ignis reports `EACCES`, and notes written by MCP do not appear in the web UI at all.

2. **A fresh npm-cache volume is not writable**
   - Named volumes are owned by root by default, while MCP runs as `PUID`.
   - Compose uses `npm-cache-init` to chown it once; if you remove that service, you must handle it yourself.

3. **Hard-coded proxy**
   - On another machine without `host.docker.internal:10808`, npx and Obsidian downloads can stall.
   - Regenerate `.env` from `.env.example` when moving machines; do not copy the local `.env`.

4. **Port or container name conflicts**
   - When running multiple deployments on one host, change `IGNIS_PORT`, `MCP_PORT`, `IGNIS_CONTAINER_NAME`, and `MCP_CONTAINER_NAME`.

5. **Slow first start**
   - Obsidian and npm packages must be downloaded; the entrypoint also tries to install `obsidian-headless`.
   - On a slow network it may stop at `[ignis] Installing obsidian-headless...`, and the web service is not up yet.
   - You can stop this optional install first to bring the service up:
     ```bash
     docker exec -u 0 ignis sh -c 'pkill -f "npm install obsidian-headless"'
     ```
   - The trade-off is that headless sync is unavailable; you can install it later with `docker exec -u 0 ignis npm install -g --prefix /usr/local obsidian-headless`.

6. **Missing `patches/server-core-watcher.js`**
   - Docker creates a missing bind source as a directory, which makes mounting to a file path fail.
   - Copy the whole project directory, or point `WATCHER_PATCH` at a real file.

## Directory Layout

```text
.
├── docker-compose.yml
├── .env.example
├── .env                 # local only, not committed
├── patches/
│   └── server-core-watcher.js
├── vaults/
│   └── test/
│       ├── .obsidian/
│       └── *.md
└── data/                # ignis runtime data
```

## Security

- `ignis` and MCP bind to `127.0.0.1` by default.
- MCP now requires `MCP_API_KEY`, but it is a static shared secret with no user identity, scopes, or audit.
- `ignis` has no built-in login or authentication; do not expose its port directly to the public internet.
- If you set `MCP_BIND=0.0.0.0`, put it behind a TLS reverse proxy, SSH tunnel, or Tailscale, and consider using supergateway `--tools` to limit the exposed tools.
- Do not commit `.env` to the repository (`.gitignore` already ignores it).

## License

MIT. See [LICENSE](./LICENSE).
