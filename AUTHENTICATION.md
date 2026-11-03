# Obsidian + MCP 鉴权与暴露设计

本文描述本仓库当前部署（`ignis` + 原生 Streamable HTTP 版 `obsidian-mcp`）的鉴权、边界和公网暴露方案。

> 与旧版的区别：MCP 已从「supergateway 包装 stdio」迁移到 `obsidian-mcp-http` 原生 HTTP transport。
> 旧文档中的 `X-API-Key`、`/healthz`、`--apiKey`、`--tools`、多 key 轮换等配置均已失效。

## 0. 结论摘要

| 项目 | 当前状态 |
|---|---|
| MCP 鉴权 | 原生 Bearer Token：`Authorization: Bearer <MCP_API_KEY>` |
| 其他鉴权头 | `X-API-Key` 不支持 |
| 健康检查 | 无独立 `/healthz`；无 token 的 `GET /mcp` 返回 `401` 即说明服务在监听 |
| 默认绑定 | `ignis` 与 MCP 都只绑 `127.0.0.1` |
| 公网暴露 | 默认禁止；必须叠加 TLS 反代 / Cloudflare Access / Tailscale |
| 多用户/scope/审计 | 没有；静态共享密钥 |
| 工具白名单 | 原生 transport 没有 `--tools`；持有 token 即可调用所有工具 |
| 密钥轮换 | 单 token，需客户端与服务端同步更新 |

## 1. 信任边界

```text
MCP 客户端（opencode / 其他）
        │ Authorization: Bearer <token>
        ▼
127.0.0.1:8811/mcp  （obsidian-mcp-http）
        │ 读写
        ▼
./vaults/test       （vault id = notes）
        ▲
        │ 同一目录
        ▼
ignis 127.0.0.1:8880 （无内置登录）
```

- **MCP 边界**：`obsidian-mcp` 是唯一 MCP 入口，直接监听 HTTP，不再有 supergateway。
- **ignis 边界**：ignis 没有登录，任何能访问 `8880` 的人都能读写 vault。
- **共享目录**：MCP 与 ignis 以同一 `PUID:PGID` 写文件；权限不一致会导致 ignis 索引失败。

## 2. 设计原则

### 2.1 默认不暴露

- `IGNIS_BIND=127.0.0.1`、`MCP_BIND=127.0.0.1`。
- 需要局域网/公网访问时，显式修改绑定，并同时配置 `MCP_ALLOWED_HOST`、反代和防火墙。

### 2.2 最小能力

- MCP 容器只挂载一个 vault（`VAULT_DIR`），不是整个 `VAULT_ROOT`。
- 容器以非 root `PUID:PGID` 运行。
- 原生 transport 不提供工具白名单；如果必须限制工具，需要在反代层做请求过滤，或维护自己的 fork。

### 2.3 Fail closed

- compose 使用 `${MCP_API_KEY:?...}`：`.env` 中为空时直接拒绝启动。
- MCP 的 `OBSIDIAN_MCP_HTTP_TOKEN` 为空时，transport 不启用鉴权；因此不要绕过 compose 直接启动容器。

### 2.4 密钥不进入 Git

- `MCP_API_KEY` 只放在 `.env`（`.gitignore` 已忽略）。
- 不要写进 `docker-compose.yml`、`opencode.json` 或镜像。
- `docker inspect` 可以看到环境变量；能访问 Docker daemon 的用户本来就拥有等价权限。

### 2.5 静态 token 的局限

- 没有用户身份、scope、过期时间、审计日志。
- 所有客户端共享同一个 token；泄露后必须整体轮换。
- 需要多用户/审计时，应在反代层接入 OAuth/OIDC，或改用支持 OAuth 的 MCP 网关。

## 3. 当前实施细节

### 3.1 `docker-compose.yml`

```yaml
obsidian-mcp:
  build:
    context: ${MCP_SOURCE_DIR}
    dockerfile: Dockerfile
  image: ${MCP_IMAGE}
  user: "${PUID:-1000}:${PGID:-1000}"
  command:
    - serve
    - --vault
    - ${VAULT_ID:-notes}=/data
    - --transport
    - http
    - --host
    - 0.0.0.0
    - --port
    - "8811"
    - --path
    - /mcp
    - --allowed-host
    - ${MCP_ALLOWED_HOST:-127.0.0.1}
  ports:
    - "${MCP_BIND:-127.0.0.1}:${MCP_PORT:-8811}:8811"
  volumes:
    - "${VAULT_DIR:-./vaults/test}:/data"
  environment:
    - OBSIDIAN_MCP_HTTP_TOKEN=${MCP_API_KEY:?MCP_API_KEY must be set in .env}
```

要点：

- `--host 0.0.0.0` 是容器内监听地址，宿主机仍由 `MCP_BIND` 限制。
- `--allowed-host` 是 DNS-rebinding 防护：客户端用哪个 `Host` 访问，就要把该主机名加进去。
- token 通过环境变量传入，不出现在命令行和 `docker ps` 的 command 中。

### 3.2 `.env` 与 `.env.example`

```dotenv
MCP_BIND=127.0.0.1
MCP_PORT=8811
MCP_ALLOWED_HOST=127.0.0.1
MCP_API_KEY=
MCP_SOURCE_DIR=../obsidian-mcp-http
MCP_IMAGE=obsidian-mcp-http:2.1.0
```

生成 key：

```bash
openssl rand -hex 32
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
        "Authorization": "Bearer {env:MCP_API_KEY}"
      }
    }
  }
}
```

opencode 不自动读取 `.env`，启动前设置进程环境变量：

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

修改配置后执行 `opencode reload`，或重启 opencode。

### 3.4 验证

```bash
# 无 token：401
curl -i http://127.0.0.1:8811/mcp

# 无 token 的 initialize：401
curl -i -X POST http://127.0.0.1:8811/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0.0"}}}'

# 带 token：200，返回 event-stream
curl -i -X POST http://127.0.0.1:8811/mcp \
  -H "Authorization: Bearer $MCP_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0.0"}}}'
```

也可运行：

```powershell
pwsh -File skill/obsidian-notes/scripts/check-mcp.ps1
```

## 4. 公网暴露方案

默认不要暴露。确需远程访问时，至少叠加一层 TLS 和一层独立鉴权。

### 4.1 方案对比

| 方案 | 适用场景 | 额外鉴权 | 备注 |
|---|---|---|---|
| Cloudflare Tunnel + Access Service Token | 有域名、希望零入站端口 | 是 | 推荐；源站仍需 Bearer |
| Caddy + HTTPS + Basic Auth / mTLS | 自有服务器 | 是 | 配置简单 |
| Nginx + oauth2-proxy / Authelia | 已有 SSO | 是 | 适合团队 |
| Tailscale Serve / Funnel | 个人设备 | 网络层 | 不暴露公网端口 |
| 直接端口映射 | 仅本机调试 | 否 | 禁止用于公网 |

### 4.2 Cloudflare Tunnel + Access Service Token

```yaml
# cloudflared 侧示意
ingress:
  - hostname: mcp.example.com
    service: http://127.0.0.1:8811
  - service: http_status:404
```

要求：

- Cloudflare Access 使用 **Service Token**（`CF-Access-Client-Id` / `CF-Access-Client-Secret`），不要只依赖 managed OAuth。
- 源站仍必须校验 Bearer Token；Cloudflare 的边界鉴权不能替代应用鉴权。
- 客户端请求公网域名时，`Host` 是 `mcp.example.com`，因此容器需要：
  ```dotenv
  MCP_BIND=127.0.0.1
  MCP_ALLOWED_HOST=mcp.example.com
  ```
  或者在反代里把 `Host` 改写成 `127.0.0.1:8811`。
- 不要把 `/mcp` 之外的路由暴露出去。

### 4.3 Caddy + HTTPS + Basic Auth / mTLS

```caddyfile
mcp.example.com {
    tls you@example.com
    basic_auth {
        user <bcrypt-hash>
    }
    reverse_proxy 127.0.0.1:8811 {
        header_up Host 127.0.0.1:8811
    }
}
```

- `header_up Host 127.0.0.1:8811` 可以让源站的 `--allowed-host` 保持默认。
- Basic Auth 之外仍要保留 Bearer Token；两层互不替代。

### 4.4 Nginx + oauth2-proxy / Authelia

```nginx
location /mcp {
    auth_request /oauth2/auth;
    proxy_pass http://127.0.0.1:8811;
    proxy_set_header Host 127.0.0.1:8811;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_set_header Authorization $http_authorization;
}
```

- `proxy_buffering off` 和较长的读超时用于 SSE。
- 必须显式转发 `Authorization`，否则 Bearer Token 会丢失。

### 4.5 Tailscale Serve

```bash
tailscale serve --bg 8811
```

- 只有 tailnet 内设备可访问。
- 仍然建议保留 Bearer Token，防止同 tailnet 内的其他设备误用。

## 5. ignis 的 IP 限制

ignis 没有内置登录，不能直接暴露公网。

### 5.1 绑定与反代

- 保持 `IGNIS_BIND=127.0.0.1`，通过 Caddy/Nginx 反代到 `8880`。
- 在反代层加 Basic Auth、mTLS 或 SSO。
- 如果必须直接监听局域网，至少用主机防火墙限制来源网段。

### 5.2 Docker 端口映射会改写来源 IP

Docker 的 NAT 会让容器看到的来源 IP 变成网关地址，按容器内 IP 做白名单通常无效。应在宿主机防火墙或反代层限制。

### 5.3 推荐结构：Caddy + 防火墙

```caddyfile
notes.example.com {
    tls you@example.com
    basic_auth {
        user <bcrypt-hash>
    }
    reverse_proxy 127.0.0.1:8880
}
```

### 5.4 主机防火墙

Windows 可用高级防火墙入站规则；Linux 可用 `ufw` / `nftables`：

```bash
sudo ufw allow from 10.8.0.0/24 to any port 8880 proto tcp
sudo ufw deny 8880/tcp
```

### 5.5 `10.8.0.x` / Tailscale 网段

Cloudflare 看到的是公网出口 IP，无法按 `10.8.x.x` 私有网段做限制。私有网段限制必须放在 VPN、Tailscale ACL 或主机防火墙上。

## 6. 只读与写入的风险

MCP 工具同时包含读写能力：

- 只读工具：`obsidian_list_vaults`、`obsidian_read_note`、`obsidian_search_vault`。
- 写入/破坏性工具：`create_note`、`edit_note`、`delete_note`、`move_note`、标签批量修改、`create_directory`。
- `delete_note` 默认进 `.obsidian-mcp/trash/`，只有显式 `permanent` 才不可恢复。

建议：

- 给 MCP 挂载专用 vault，不要挂载包含敏感内容的整个笔记库。
- 定期备份 `VAULT_DIR`。
- 客户端开启工具确认；不要让不可信 prompt 直接驱动写入工具。
- 写入前先 `read_note` 取 `etag`，并用 `if_match` 防并发覆盖。

## 7. 密钥运维

### 7.1 生成

```bash
openssl rand -hex 32
```

### 7.2 存储

- `.env`（本地，不提交）。
- CI/部署平台用 secret 管理；不要把 key 写进镜像层。

### 7.3 轮换

服务端只支持单个 token，无法无缝双 key 并存：

1. 生成新 key。
2. 更新 `.env` 的 `MCP_API_KEY`。
3. `docker compose up -d obsidian-mcp`。
4. 更新客户端环境变量并 `opencode reload`。
5. 旧 key 立即失效。

### 7.4 泄露处理

- 立即轮换 token。
- 检查 vault 是否有异常写入（`.obsidian-mcp` 事务日志、备份 diff）。
- 检查反代/防火墙日志中的异常来源。

## 8. 检查清单

部署前：

- [ ] `.env` 中 `MCP_API_KEY` 已设置且未提交
- [ ] `MCP_BIND` / `IGNIS_BIND` 保持 `127.0.0.1`（除非确有需要）
- [ ] `MCP_ALLOWED_HOST` 与客户端实际使用的 Host 一致
- [ ] `MCP_SOURCE_DIR` 指向含 `Dockerfile` 的 checkout
- [ ] vault 目录属主与 `PUID:PGID` 一致

部署后：

- [ ] `docker compose ps` 中 MCP 为 healthy
- [ ] 无 token 的 `GET /mcp` 返回 `401`
- [ ] 带 token 的 `initialize` 返回 `200`
- [ ] `opencode mcp list` 中 `obsidian` 为 connected
- [ ] `obsidian_list_vaults` 返回 `notes`

公网暴露时额外检查：

- [ ] TLS 终止在反代
- [ ] 反代有独立鉴权（Service Token / Basic Auth / SSO）
- [ ] 只暴露 `/mcp`，不暴露 ignis 或其他路径
- [ ] 防火墙限制来源
- [ ] 日志与告警可用

## 9. 参考

- 仓库 README：[`README.md`](./README.md)
- MCP 使用笔记：[`docs/mcp-usage-notes.md`](./docs/mcp-usage-notes.md)
- obsidian-mcp-http fork：<https://github.com/mrchipset/obsidian-mcp-http>
- 上游 obsidian-mcp：<https://github.com/StevenStavrakis/obsidian-mcp>
- MCP Streamable HTTP 规范：<https://modelcontextprotocol.io/specification>
