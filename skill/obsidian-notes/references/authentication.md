# MCP Authentication Reference

This reference covers the authentication settings needed by the `obsidian-notes` skill.

Canonical repo document: [`../../../AUTHENTICATION.md`](../../../AUTHENTICATION.md)

## What protects the MCP endpoint

supergateway 4.2.1 supports a static API key:

- `--apiKey "<key>"`
- `--apiKeyFile /run/secrets/mcp_api_key`
- environment variables `SUPERGATEWAY_API_KEY` / `SUPERGATEWAY_API_KEY_FILE`

Every MCP request must send one of:

```http
X-API-Key: <MCP_API_KEY>
```

or:

```http
Authorization: Bearer <MCP_API_KEY>
```

The `X-API-Key` form is preferred for this deployment because it avoids conflicts with edge authentication headers.

## Required environment variable

The MCP server and the client both need `MCP_API_KEY`.

- Docker Compose reads it from `.env`.
- opencode reads it from the **process environment**; it does not load `.env` automatically.

Set it before starting opencode:

```powershell
# PowerShell
$env:MCP_API_KEY = (Get-Content .env | Where-Object { $_ -match '^MCP_API_KEY=' }) -replace '^MCP_API_KEY=',''
opencode
```

```bash
# bash/zsh
export MCP_API_KEY="$(grep '^MCP_API_KEY=' .env | cut -d= -f2-)"
opencode
```

## Client configuration

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

`"oauth": false` tells opencode this is a static key, not an OAuth server.

## Health and verification

The health endpoint is **not** protected by the API key:

```bash
curl http://127.0.0.1:8811/healthz
```

Expected:

| Request | Status |
|---|---|
| `GET /healthz` | `200` |
| `POST /mcp` without key | `401` |
| `POST /mcp` with key | `200` |

Run the skill's check script:

```powershell
pwsh -File skill/obsidian-notes/scripts/check-mcp.ps1
```

or, on Windows PowerShell 5.1:

```powershell
powershell -ExecutionPolicy Bypass -File skill/obsidian-notes/scripts/check-mcp.ps1
```

## Public exposure

Do not expose port `8811` directly to the public internet. If remote access is required:

- Put it behind Cloudflare Tunnel + Access service tokens, or
- Put it behind a TLS reverse proxy with authentication, or
- Use Tailscale Serve.

Cloudflare Access cannot enforce a private `10.8.x.x` CIDR because Cloudflare sees the public egress IP. Enforce private VPN ranges at the VPN or host firewall.

## Key rotation

supergateway accepts multiple keys at once:

```bash
--apiKey "$OLD_MCP_API_KEY" \
--apiKey "$NEW_MCP_API_KEY"
```

Rotate by adding the new key, restarting the MCP service, updating clients, then removing the old key.

## Related docs

- Full auth and IP-restriction design: [`../../../AUTHENTICATION.md`](../../../AUTHENTICATION.md)
- MCP usage reference: [`mcp-usage-notes.md`](mcp-usage-notes.md)
