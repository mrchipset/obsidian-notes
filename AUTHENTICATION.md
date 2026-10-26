# Obsidian + MCP 鉴权与访问控制配置

本文是本仓库 `ignis + supergateway + obsidian-mcp` 部署的完整鉴权设计文档，覆盖：

- 当前已启用的 MCP 静态 API Key
- 公网暴露时的可选鉴权架构
- `ignis` 的 IP 网段限制与 Docker 网络注意事项
- 密钥生成、轮换、验证和排障

> 本文不包含任何真实密钥。实际密钥只放在 `.env`（已被 `.gitignore` 忽略）或 Docker secret 中。

---

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| MCP 是否已有鉴权 | 已有。supergateway 4.2.1 使用 `--apiKey`，所有 MCP 请求必须带 `X-API-Key` 或 `Authorization: Bearer` |
| 是否可以直接把 MCP 端口暴露公网 | 不建议。至少再加 TLS 反代/Cloudflare/Tailscale，并限制工具权限 |
| `ignis` 能否自己限制 `10.8.0.0/24`、`127.0.0.0/8` | **不能**。ignis 没有内置 IP ACL、登录或 trusted proxy |
| 推荐怎么限制 ignis 来源 IP | 在**宿主机**上跑 Caddy/Nginx 做 `remote_ip` / `allow`，再加宿主防火墙 |
| 为什么不能在 ignis 容器内限制 | Docker 会改写源 IP；Docker Desktop 下所有客户端通常都变成 `192.168.65.1` |
| `10.8.0.x` 是什么 | 常见于 OpenVPN 默认网段 `10.8.0.0/24`；Tailscale 默认是 `100.64.0.0/10`，不要混淆 |
| 单靠 IP 白名单是否足够 | 不够。ignis 没有认证，建议再加 Basic Auth / SSO / VPN 身份 |

推荐的安全分层：

```text
公网 / VPN 客户端
        │
        ▼
┌─────────────────────────────┐
│ 边缘层（任选其一）           │
│ Cloudflare Access           │
│ 或 宿主机 Caddy/Nginx       │
│ 或 Tailscale Serve          │
│ - TLS                       │
│ - 身份认证 / IP 白名单       │
└─────────────┬───────────────┘
              │
      ┌───────┴────────┐
      ▼                ▼
┌───────────┐    ┌──────────────────────────┐
│ ignis     │    │ supergateway :8811       │
│ :8080     │    │ - MCP_API_KEY            │
│ 无内置认证 │    │ - --tools 工具白名单      │
└───────────┘    └────────────┬─────────────┘
                              │ stdio
                              ▼
                     ┌──────────────────┐
                     │ obsidian-mcp     │
                     │ 读写 vault       │
                     └──────────────────┘
```

---

## 1. 组件与信任边界

| 组件 | 默认监听 | 是否有鉴权 | 职责 |
|---|---|---|---|
| `ignis` | `127.0.0.1:8080` | 无 | 浏览器版 Obsidian Web UI，直接读写 vault |
| `supergateway` | `127.0.0.1:8811` | 静态 API Key | 把 stdio MCP 包成 Streamable HTTP |
| `obsidian-mcp` | 容器内 stdio | 无网络监听 | 实际的 vault 读写工具 |
| MCP 客户端（opencode） | 本机 | 携带 API Key | 调用 MCP 工具 |

关键边界：

1. **ignis 边界**：Web UI 能直接读写整个 vault，且没有登录。必须依赖网络层/反代保护。
2. **MCP 边界**：supergateway 是唯一对外 MCP 入口；`obsidian-mcp` 不应直接监听网络。
3. **密钥边界**：`.env`、Docker secret、Cloudflare Tunnel token 都不应进入 Git。
4. **内容边界**：vault 里的笔记是不可信输入，可能包含提示注入内容，诱使模型调用删除/外泄工具。

---

## 2. 设计原则

### 2.1 默认不暴露

- `IGNIS_BIND=127.0.0.1`
- `MCP_BIND=127.0.0.1`

只有明确需要远程访问时，才通过反代、Cloudflare Tunnel 或 Tailscale 暴露，并且不要把源站端口直接发布到 `0.0.0.0`。

### 2.2 纵深防御

不要只依赖一层：

1. 边缘身份认证（Cloudflare Access / Caddy Basic Auth / SSO）
2. MCP API Key（supergateway `--apiKey`）
3. 工具白名单（supergateway `--tools`）
4. 宿主防火墙 / VPN ACL
5. 备份与审计

### 2.3 最小权限

MCP 工具集包含读取、创建、编辑、移动、删除。公网场景应优先只暴露只读工具：

```bash
--tools obsidian_list_vaults \
--tools obsidian_read_note \
--tools obsidian_search_vault
```

需要写入时再增加 `obsidian_create_note`、`obsidian_edit_note`。不要默认暴露 `obsidian_delete_note`。

> 注意：`obsidian-mcp` 2.x 启动时会检查 vault 的读写权限，单纯把 volume 挂成 `:ro` 会导致 `VAULT_PERMISSION_DENIED`。只读应通过 `--tools` 实现，而不是只读挂载。

### 2.4 Fail closed

- `MCP_API_KEY` 为空时，`docker compose` 应拒绝启动，而不是无鉴权运行。
- 当前 compose 使用 `${MCP_API_KEY:?MCP_API_KEY must be set in .env}`，未设置会直接报错。
- supergateway 的 `--apiKey` 为空、key 文件不可读或文件为空时也会停止启动。

### 2.5 密钥不进入 Git

- `.env` 已被 `.gitignore` 忽略。
- `opencode.json` 使用 `{env:MCP_API_KEY}` 插值，不写明文 key。
- 公网部署建议进一步使用 Docker secret + `--apiKeyFile`。

### 2.6 静态 key 的局限

`MCP_API_KEY` 是**共享静态密钥**，不是用户身份系统：

- 没有 per-user 身份
- 没有 scope
- 没有审计归属
- 泄漏后等于拿到整个 MCP 工具集权限

单用户个人 vault 可以接受；多人或高价值数据应使用 OAuth/SSO，或为每个用户部署独立实例。

---

## 3. 当前已实施的配置

### 3.1 `docker-compose.yml`

supergateway 启动命令中已加入：

```yaml
    command: >
      npx -y supergateway@${SUPERGATEWAY_VERSION:-4.2.1}
      --stdio "npx -y obsidian-mcp@${OBSIDIAN_MCP_VERSION:-2.0.1} serve --vault ${VAULT_ID:-notes}=/data"
      --outputTransport streamableHttp
      --port 8811
      --host 0.0.0.0
      --apiKey "${MCP_API_KEY:?MCP_API_KEY must be set in .env}"
      --healthEndpoint /healthz
```

要点：

- `--outputTransport streamableHttp`：显式使用 Streamable HTTP，而不是默认 SSE。
- `--host 0.0.0.0`：容器内监听所有接口，但 Compose 仍然只发布到 `127.0.0.1`。
- `--apiKey`：所有 MCP 请求都必须带 key。
- `--healthEndpoint /healthz`：健康检查路径**不受 API Key 保护**，只用于容器内部检查。

### 3.2 `.env` 与 `.env.example`

`.env.example` 增加：

```bash
# ===== MCP 鉴权 =====
# supergateway requires this key on every MCP request (X-API-Key or
# Authorization: Bearer). Generate with: openssl rand -hex 32
# Leave empty and compose refuses to start, to avoid accidental unauthenticated exposure.
MCP_API_KEY=
```

`.env` 中保存实际值，且不会被提交：

```bash
MCP_API_KEY=<64 位十六进制随机值>
```

生成方式：

```bash
openssl rand -hex 32
```

PowerShell：

```powershell
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
-join ($bytes | ForEach-Object { $_.ToString('x2') })
```

### 3.3 `opencode.json`

```json
{
  "$schema": "https://opencode.ai/config.json",
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

说明：

- 使用 `X-API-Key`，避免和边缘层的 `Authorization` 冲突。
- `"oauth": false`：告诉 opencode 这是静态 key，不要在 401 时尝试 OAuth 发现。
- opencode **不会自动读取项目目录下的 `.env`**；`{env:MCP_API_KEY}` 只从进程环境读取。

启动 opencode 前设置环境变量：

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

### 3.4 验证

```bash
# 无 key：应为 401
curl -i -X POST http://127.0.0.1:8811/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}'

# 带 key：应为 200
curl -i -X POST http://127.0.0.1:8811/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-API-Key: $MCP_API_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}'

# 健康检查：无 key 也是 200，这是设计行为
curl -i http://127.0.0.1:8811/healthz
```

预期：

| 请求 | 状态码 |
|---|---|
| `/mcp` 无 key | `401 Unauthorized` |
| `/mcp` 正确 key | `200 OK` |
| `/healthz` 无 key | `200 OK`（不要公网暴露） |

---

## 4. 公网暴露方案

### 4.1 方案对比

| 方案 | 鉴权方式 | 客户端能否带静态 header | 适合场景 | 复杂度 |
|---|---|---|---|---|
| **Cloudflare Tunnel + Access Service Token** | Access 策略 + Service Token | 是：`CF-Access-Client-Id` / `CF-Access-Client-Secret` | 推荐；无需开放入站端口 | 低 |
| **Caddy + HTTPS + Basic/Bearer** | Basic Auth 或 header matcher | 是：`Authorization` 或自定义 header | 不想依赖 Cloudflare | 低 |
| **Nginx + oauth2-proxy / Authelia** | OIDC / ForwardAuth | 视配置；CLI 需要 JWT 或 basic | 已有 IdP | 中 |
| **Traefik + ForwardAuth** | Authelia/Authentik/oauth2-proxy | 视配置 | 已有 Traefik/IdP | 中 |
| **Tailscale Serve** | WireGuard + tailnet ACL | 不需要应用 token | 客户端能进 tailnet | 低 |
| **Tailscale Funnel** | **无鉴权** | 不适用 | 不推荐单独使用 | 低 |
| **IBM ContextForge / mcp-auth-proxy / Azure APIM** | OAuth 2.1 / JWT / API key | 是 | 企业级、多用户 | 高 |

### 4.2 推荐：Cloudflare Tunnel + Access Service Token

目标架构：

```text
opencode
  │ HTTPS + CF-Access-Client-Id/Secret + X-API-Key
  ▼
Cloudflare Access（Service Auth）
  │ Tunnel
  ▼
cloudflared ── internal Docker network ──► supergateway:8811
                                              │
                                              ▼
                                        obsidian-mcp
```

优点：

- 源站不开放任何入站端口
- Cloudflare 负责 TLS、DDoS、访问策略和日志
- Service Token 适合非浏览器客户端
- 可以在前面再加 WAF / IP 规则

Compose 结构（示意）：

```yaml
services:
  obsidian-mcp:
    # 关键：不要写 ports:
    networks: [internal]
    command: >
      npx -y supergateway@4.2.1
      --stdio "npx -y obsidian-mcp@2.0.1 serve --vault notes=/data"
      --outputTransport streamableHttp
      --host 0.0.0.0
      --port 8811
      --apiKeyFile /run/secrets/mcp_api_key
      --tools obsidian_list_vaults
      --tools obsidian_read_note
      --tools obsidian_search_vault
    volumes:
      - "./vaults/test:/data"
    secrets:
      - mcp_api_key

  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    networks: [internal]

networks:
  internal:

secrets:
  mcp_api_key:
    file: ./secrets/mcp_api_key
```

Cloudflare 侧：

- Public hostname：`mcp.example.com`
- Path：`^/mcp$`
- Upstream：`http://obsidian-mcp:8811`
- Access 应用策略：**Service Auth**，只允许指定 Service Token
- 不要给 `/healthz` 创建公网路由

opencode 侧：

```json
{
  "mcp": {
    "obsidian": {
      "type": "remote",
      "url": "https://mcp.example.com/mcp",
      "oauth": false,
      "headers": {
        "CF-Access-Client-Id": "{env:CF_ACCESS_CLIENT_ID}",
        "CF-Access-Client-Secret": "{env:CF_ACCESS_CLIENT_SECRET}",
        "X-API-Key": "{env:MCP_API_KEY}"
      },
      "timeout": 120000
    }
  }
}
```

注意：

- Cloudflare 的 **managed OAuth** 要求源站校验 `Cf-Access-Jwt-Assertion`；supergateway 不校验，所以这套栈应使用 **Service Token**，不要直接开 managed OAuth 除非你在源站增加 JWT 校验。
- Cloudflare 看到的是公网出口 IP，**无法在边缘按 `10.8.0.0/24` 这种私有 VPN 网段限制**；私有网段限制要在 VPN 或宿主机上做。
- `CF_TUNNEL_TOKEN` 只放 `.env` 或密钥管理系统，不要提交。

### 4.3 自托管：Caddy + HTTPS + Basic Auth

适合有公网域名和 80/443 的宿主机。Caddy 应运行在**宿主机**上，而不是 Docker 容器里，这样才能看到真实客户端 IP。

```caddyfile
mcp.example.com {
    @denied not remote_ip 10.8.0.0/24 127.0.0.0/8
    respond @denied "Forbidden" 403

    basic_auth {
        user <bcrypt-hash>
    }

    # 不要暴露健康检查
    @health path /healthz
    respond @health 404

    reverse_proxy 127.0.0.1:8811 {
        header_up X-API-Key {env.MCP_INTERNAL_KEY}
        flush_interval -1
    }
}
```

生成 Basic Auth 哈希：

```bash
caddy hash-password --plaintext '你的密码'
```

客户端请求头：

```http
Authorization: Basic <base64(user:password)>
X-API-Key: <MCP_INTERNAL_KEY>
```

要点：

- `flush_interval -1` 关闭响应缓冲，避免 Streamable HTTP/SSE 卡住。
- 保持 `/mcp` 路径不变；Caddy 用 `handle`，不要用会剥前缀的 `handle_path`。
- 如果 Caddy 前面还有可信代理，使用 `client_ip` 而不是 `remote_ip`，并配置 `trusted_proxies`，否则客户端可以伪造 `X-Forwarded-For`。
- Basic Auth 必须配合 HTTPS，否则密码是明文传输。

如果不想用 Basic Auth，也可以用 Caddy `header` matcher 校验 Bearer token；token 建议通过环境变量注入，并注意 Caddy 版本对占位符的支持。

### 4.4 Nginx + oauth2-proxy / Authelia

适合已有 IdP 的环境。Nginx 负责 TLS 和 `allow/deny`，oauth2-proxy/Authelia 负责登录。

```nginx
location /mcp {
    allow 10.8.0.0/24;
    allow 127.0.0.0/8;
    deny all;

    proxy_pass http://127.0.0.1:8811;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
}
```

如果 Nginx 在另一个反代之后：

```nginx
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

否则 `allow`/`deny` 看到的是代理 IP，不是客户端 IP。

### 4.5 Tailscale Serve

如果客户端能加入 tailnet，这是最省心的方案：

```bash
tailscale serve --bg 8811
```

- 只有 tailnet 内设备能访问
- 身份由 WireGuard + tailnet ACL 控制
- 不需要应用层 token
- 后端仍应只监听 `127.0.0.1`

**不要用 Tailscale Funnel** 代替认证：Funnel 是公网无鉴权隧道，任何人拿到 URL 都能访问，除非你再加 `--apiKey` 或反代认证。

### 4.6 关于 MCP OAuth

当前 MCP 规范（2026-07-28）中授权是**可选**的：

- HTTP 传输建议遵循 MCP 授权规范。
- 如果使用 OAuth，授权服务器必须实现 OAuth 2.1。
- MCP 服务器应实现 RFC 9728 Protected Resource Metadata。
- 客户端应使用 RFC 8707 Resource Indicators，并校验 token audience。
- 2026-07-28 还涉及 `iss` 校验、客户端与授权服务器绑定、DCR → CIMD 等变化。

对本项目：

- 单用户静态 API Key 是允许的，不需要为了“合规”强行上 OAuth。
- 如果使用静态 key，客户端应设置 `oauth: false`，不要 advertise OAuth 发现。
- 如果要多用户、scope、审计，应使用真正的 MCP 授权网关，而不是只在 Caddy 上加一个 cookie 登录。

---

## 5. ignis 的 IP 网段限制

### 5.1 ignis 自身没有这个能力

当前镜像对应 **Ignis 0.8.18 / Obsidian 1.14.4**。结论：

- 没有内置登录
- 没有 IP allowlist
- 没有 trusted proxy 配置
- 没有 `HOST`/`BIND` 环境变量
- 没有按用户/来源的访问控制

相关环境变量：

| 变量 | 作用 | 是否是客户端 ACL |
|---|---|---|
| `PORT` | 监听端口 | 否 |
| `VAULT_ROOT` | vault 路径 | 否 |
| `DATA_ROOT` | 持久化数据 | 否 |
| `PUID` / `PGID` | 文件属主 | 否 |
| `WS_ORIGINS` | WebSocket 的 Origin 白名单 | 否，是 Origin 限制 |
| `PROXY_ALLOW_PRIVATE_HOSTS` | `/api/proxy` 的 SSRF 白名单 | 否，是服务端出站限制 |

因此，“只允许 `10.8.0.0/24` 和 `127.0.0.0/8`”必须在 ignis 外面实现。

### 5.2 Docker 会改写源 IP

| 访问路径 | ignis/反代容器内看到的源 IP |
|---|---|
| Linux 外部客户端 → 宿主机发布端口 → 容器 | 通常保留真实客户端 IP |
| Linux 宿主机 `127.0.0.1` → 发布端口 → 容器 | 变成 bridge 网关，例如 `172.17.0.1` |
| Docker Desktop（Windows/macOS）→ 任意客户端 | 通常变成 `192.168.65.1` |
| 反代容器 → ignis 容器 | 变成反代容器的 IP |
| 宿主机原生反代 → ignis 容器 | 看到真实客户端 IP |

结论：

- **不要在 ignis 容器内做 IP 白名单**
- **不要用容器内的 Caddy/Nginx 判断 `10.8.0.x`**，除非你确认源 IP 保留
- Docker Desktop 下源 IP 经常被折叠，最可靠的是宿主机反代/防火墙
- Linux 下如果必须直接发布 ignis 端口，Docker 会绕过 ufw 的 INPUT 规则，需要用 `DOCKER-USER` 链或宿主机反代

### 5.3 推荐架构：宿主机 Caddy + 防火墙

保持 ignis 只绑 `127.0.0.1:8080`：

```yaml
services:
  ignis:
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - WS_ORIGINS=https://ignis.example.com
      # 不要设置 PROXY_ALLOW_PRIVATE_HOSTS，除非插件确实需要
```

宿主机 Caddy：

```caddyfile
ignis.example.com {
    @denied not remote_ip 10.8.0.0/24 127.0.0.0/8
    respond @denied "Forbidden" 403

    basic_auth {
        user <bcrypt-hash>
    }

    reverse_proxy 127.0.0.1:8080
}
```

这样：

- VPN 客户端来源是 `10.8.0.x`，匹配 `10.8.0.0/24`
- 宿主机本机浏览器来源是 `127.0.0.1`，匹配 `127.0.0.0/8`
- 其他来源直接 403
- Basic Auth 再提供一层认证

> 如果 Caddy 前面还有 Cloudflare Tunnel、Tailscale Serve 或另一个反代，使用 `client_ip` + `trusted_proxies`，否则 `remote_ip` 看到的是代理 IP。

### 5.4 Nginx 等价配置

```nginx
server {
    listen 443 ssl;
    server_name ignis.example.com;

    location / {
        allow 10.8.0.0/24;
        allow 127.0.0.0/8;
        deny all;

        auth_basic "Ignis";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
```

### 5.5 宿主机防火墙

Windows（只允许 VPN 网段和本机访问 443）：

```powershell
New-NetFirewallRule `
  -DisplayName "Ignis HTTPS (VPN + localhost only)" `
  -Direction Inbound `
  -Action Allow `
  -Protocol TCP `
  -LocalPort 443 `
  -RemoteAddress @("10.8.0.0/24", "127.0.0.1") `
  -Profile Any
```

Windows 防火墙默认阻止入站；这条规则只放行指定来源。不要在后面再加一条宽泛的“Block 443”，因为 Windows 防火墙会先处理 Block 规则。

Linux ufw：

```bash
ufw default deny incoming
ufw allow from 10.8.0.0/24 to any port 443 proto tcp
# 本机回环通常已允许；如没有：
ufw allow in on lo
```

Linux nftables：

```bash
nft add rule inet filter input ip saddr 10.8.0.0/24 tcp dport 443 accept
nft add rule inet filter input tcp dport 443 drop
```

如果必须直接发布 Docker 端口而不是走宿主机反代，Docker 会绕过 ufw；需要在 `DOCKER-USER` 链里按原始端口过滤，并注意 DNAT 已经发生，通常要配合 `conntrack --ctorigdstport`。

### 5.6 `10.8.0.x` 与 Tailscale 的区别

- `10.8.0.0/24` 是 **OpenVPN 示例配置的默认网段**（`server 10.8.0.0 255.255.255.0`），也常见于手写 WireGuard。
- Tailscale 默认使用 `100.64.0.0/10`（RFC 6598 CGNAT），不是 `10.8.0.0/24`。
- 如果客户端是 Tailscale，应该用 **tailnet ACL / grants**，而不是在 Caddy 里写 `10.8.0.0/24`。
- 如果 `10.8.0.0/24` 是 Tailscale 的 subnet route，实际源 IP 可能是 `100.x` 或 subnet router 地址，需要看日志确认。

### 5.7 IP 白名单的局限

ignis 没有认证，所以：

- 同一 VPN 网段内任何被入侵的设备都能读写整个 vault
- 没有 per-user 审计
- 没有只读模式
- `/api/proxy` 可能被滥用为出站代理（默认阻止私有/回环地址，但仍应限制或禁用）
- `WS_ORIGINS` 默认接受任意 Origin，建议设置为确切的 HTTPS origin

因此：

1. IP 白名单是必要的
2. Basic Auth / SSO / VPN 身份是强烈建议的
3. 不要把 ignis 直接暴露到公网

---

## 6. 工具权限最小化

### 6.1 只读白名单

```bash
--tools obsidian_list_vaults
--tools obsidian_read_note
--tools obsidian_search_vault
```

适合：

- 让 AI 查询笔记
- 不希望 AI 修改/删除内容
- 公网暴露时的默认形态

### 6.2 读写白名单

```bash
--tools obsidian_list_vaults
--tools obsidian_read_note
--tools obsidian_search_vault
--tools obsidian_create_note
--tools obsidian_edit_note
--tools obsidian_move_note
```

不要加入：

- `obsidian_delete_note`
- 批量标签管理工具（除非确实需要）

### 6.3 提示注入风险

MCP 会把笔记内容返回给模型。如果笔记中包含恶意指令，模型可能被诱导：

- 删除笔记
- 修改内容
- 读取其他笔记并外泄
- 调用 `obsidian_create_note` 写入恶意内容

缓解：

- 只读工具白名单
- 不暴露删除工具
- 定期备份
- 不要把不可信来源的笔记直接喂给高权限 agent
- 对写入操作保留人工确认

---

## 7. 密钥与运维

### 7.1 生成

```bash
openssl rand -hex 32
```

要求：

- 至少 32 字节随机
- 不要使用密码、日期、项目名
- 不要多个环境复用同一个 key

### 7.2 存储

优先级：

1. Docker secret / 云密钥管理
2. `.env`（已被 gitignore）
3. 进程环境变量

不要：

- 写进 `docker-compose.yml`
- 写进 `opencode.json`
- 写进 README
- 提交到 Git
- 发到聊天/日志

### 7.3 轮换

supergateway 支持同时配置多个 `--apiKey`，可以无缝轮换：

1. 生成新 key
2. 在启动参数中同时保留新旧 key
3. 重启 `obsidian-mcp`
4. 更新 opencode / 其他客户端
5. 确认新 key 可用
6. 移除旧 key，再次重启

示例：

```bash
--apiKey "$OLD_MCP_API_KEY" \
--apiKey "$NEW_MCP_API_KEY"
```

如果使用 `--apiKeyFile`，文件中每行一个 key，同样支持并存。

### 7.4 泄漏处理

1. 立即轮换 `MCP_API_KEY`
2. 轮换 Cloudflare Service Token / Tunnel token
3. 检查 `docker compose logs`、Cloudflare Access 日志
4. 检查 vault 是否有异常修改/删除
5. 从备份恢复
6. 收紧工具白名单和网络访问

---

## 8. 排障

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `401 Unauthorized` | 没带 key / key 错误 / opencode 没读到环境变量 | 检查 `X-API-Key`，确认 `MCP_API_KEY` 在当前进程环境 |
| `400 Parse error: invalid JSON` | 客户端 JSON 被 shell 转义破坏 | 用文件 `--data-binary @file` 或 MCP Inspector 验证 |
| `403 Forbidden` | Caddy/Nginx IP 白名单或 Basic Auth 拒绝 | 检查客户端源 IP、`remote_ip`/`allow`、`trusted_proxies` |
| `404` / `502` | 路径被改写 / 上游地址错误 | 保持 `/mcp` 不变；检查 `reverse_proxy` 目标 |
| `/healthz` 无 key 也 200 | 设计如此，健康检查绕过 API Key | 不要公网暴露 `/healthz` |
| `524`（Cloudflare） | 代理读超时（约 125 秒） | 缩短工具调用、增加 keepalive、或调整边缘超时 |
| SSE 卡住/不流式 | 反代缓冲、超时太短 | Caddy `flush_interval -1`；Nginx `proxy_buffering off`、足够长的 `proxy_read_timeout` |
| 容器内看到的都是 `192.168.65.1` | Docker Desktop 源 IP 折叠 | 在宿主机反代/防火墙做限制 |
| `MCP_API_KEY must be set in .env` | `.env` 缺少变量 | 生成并写入 `.env`，再 `docker compose up -d` |
| opencode 连不上 | 没设置环境变量 / 没重启 | 设置 `MCP_API_KEY` 后重启 opencode |
| `VAULT_PERMISSION_DENIED` | vault 不可写 | 保持读写挂载；只读用 `--tools` 限制 |
| ignis 端口显示 `0.0.0.0` | 旧容器/旧 `.env` 未重建 | `docker compose up -d --force-recreate ignis`，确认 `IGNIS_BIND=127.0.0.1` |

---

## 9. 上线检查清单

### 本地/单机

- [ ] `.env` 已设置 `MCP_API_KEY`，且不是默认值
- [ ] `docker compose config --quiet` 通过
- [ ] `POST /mcp` 无 key 返回 401
- [ ] `POST /mcp` 带 key 返回 200
- [ ] `/healthz` 只在容器内部使用
- [ ] `ignis` 和 `obsidian-mcp` 都只绑定 `127.0.0.1`
- [ ] opencode 已设置 `MCP_API_KEY` 并重启
- [ ] `.env` 没有被 git 跟踪

### 公网 MCP

- [ ] Cloudflare Tunnel / Caddy / Tailscale 已启用
- [ ] 源站 MCP 端口没有直接发布到 `0.0.0.0`
- [ ] 边缘层有身份认证（Access Service Token / Basic Auth / SSO）
- [ ] TLS 正常
- [ ] `/healthz` 没有公网路由
- [ ] `--tools` 只暴露必要工具
- [ ] API key 与边缘 token 分开存储
- [ ] 已配置日志和告警
- [ ] 已测试 401/403/200
- [ ] 已有独立备份

### 公网 ignis（不推荐）

- [ ] 宿主机 Caddy/Nginx 做 `remote_ip` / `allow` 限制
- [ ] 宿主防火墙限制来源 CIDR
- [ ] 已加 Basic Auth / SSO
- [ ] `WS_ORIGINS` 设置为确切 HTTPS origin
- [ ] 未设置 `PROXY_ALLOW_PRIVATE_HOSTS`（除非必要）
- [ ] 确认源 IP 没有被 Docker Desktop 折叠
- [ ] 已接受“同网段设备可完全访问 vault”的风险

---

## 10. 参考

- supergateway（`--apiKey` / `--apiKeyFile` / `--tools`）：https://github.com/supercorp-ai/supergateway
- supergateway 4.2.0 release：https://github.com/supercorp-ai/supergateway/releases/tag/v4.2.0
- MCP Authorization 2026-07-28：https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
- MCP 安全考虑：https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations
- opencode MCP 配置：https://opencode.ai/docs/mcp-servers/
- Cloudflare Access Service Tokens：https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/
- Cloudflare managed OAuth：https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/
- Caddy `basic_auth`：https://caddyserver.com/docs/caddyfile/directives/basic_auth
- Caddy `remote_ip`：https://caddyserver.com/docs/caddyfile/matchers#remote-ip
- Caddy `reverse_proxy`：https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
- Nginx `allow/deny`：https://nginx.org/en/docs/http/ngx_http_access_module.html
- Nginx `realip`：https://nginx.org/en/docs/http/ngx_http_realip_module.html
- Docker packet filtering：https://docs.docker.com/engine/network/packet-filtering-firewalls/
- Ignis authentication：https://ignis.thiefling.com/docs/security/authentication/
- Ignis 仓库：https://github.com/Nystik-gh/ignis
- Tailscale Serve/Funnel：https://tailscale.com/docs/features/tailscale-serve
- Tailscale 保留地址：https://tailscale.com/docs/reference/reserved-ip-addresses
- OpenVPN 示例配置：https://github.com/OpenVPN/openvpn/blob/master/sample/sample-config-files/server.conf
- obsidian-mcp：https://github.com/StevenStavrakis/obsidian-mcp
