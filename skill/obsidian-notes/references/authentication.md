# MCP Authentication Reference

This reference covers the authentication settings needed by the `obsidian-notes` skill.

Canonical repo document: [`../../../AUTHENTICATION.md`](../../../AUTHENTICATION.md)

## What protects the MCP endpoint

The `obsidian-mcp-http` transport enforces a static bearer token configured with `--auth-token` or the `OBSIDIAN_MCP_HTTP_TOKEN` environment variable. Compose passes `MCP_API_KEY` through that environment variable.

Every MCP request must send:

```http
Authorization: Bearer <MCP_API_KEY>
```

`X-API-Key` is **not** supported. Requests without the token receive `401`.

## Required environment variable

The MCP server and the client both need `MCP_API_KEY`.

- Docker Compose reads it from `.env` and refuses to start when it is empty.
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
        "Authorization": "Bearer {env:MCP_API_KEY}"
      }
    }
  }
}
```

`"oauth": false` tells opencode this is a static token, not an OAuth server. Run `opencode reload` after editing the config.

## Health and verification

There is no unauthenticated `/healthz` endpoint. With a token configured, `GET /mcp` itself returns `401`, which still proves the service is listening.

Expected:

| Request | Status |
|---|---|
| `GET /mcp` without token | `401` |
| `POST /mcp` without token | `401` |
| `POST /mcp` with `Authorization: Bearer` | `200` |

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

When clients reach the container through a LAN address or hostname, set `MCP_ALLOWED_HOST` to that value; the transport validates the `Host` header.

## Key rotation

The server supports one token at a time. To rotate:

1. Update `MCP_API_KEY` in `.env` and the client environment.
2. Recreate the container: `docker compose up -d obsidian-mcp`.
3. Reload the client: `opencode reload`.

## Related docs

- Full auth and IP-restriction design: [`../../../AUTHENTICATION.md`](../../../AUTHENTICATION.md)
- MCP usage reference: [`mcp-usage-notes.md`](mcp-usage-notes.md)
