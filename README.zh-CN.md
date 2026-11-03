# Obsidian + MCP 部署

[English](README.md) | **简体中文**

用 Docker Compose 部署一套「浏览器版 Obsidian + Obsidian MCP」：

- `ignis`：浏览器访问的 Obsidian Web，默认 `http://127.0.0.1:8880`
- `obsidian-mcp`：从 [`obsidian-mcp-http`](https://github.com/mrchipset/obsidian-mcp-http) fork 构建，原生提供 Streamable HTTP，默认 `http://127.0.0.1:8811/mcp`
- 两者共用同一个 vault 目录

鉴权、公网暴露和 IP 网段限制的完整设计见 [AUTHENTICATION.md](./AUTHENTICATION.md)。

## 前置条件

- Docker Engine / Docker Desktop + Compose v2.17 以上
- 一份包含 `Dockerfile` 的 `obsidian-mcp-http` 本地 checkout；用 `MCP_SOURCE_DIR` 指向它
- 一个真实 vault：目录里必须有 `.obsidian/`
- **首次构建**能访问 npm registry（镜像会编译 TypeScript 源码）；运行时不再下载任何 npm 包
- 如果目标机器需要代理，在 `.env` 里配置 `HTTP_PROXY` / `HTTPS_PROXY`；compose 会把它们传给镜像构建

## 快速开始

```bash
# 1. 生成配置
cp .env.example .env

# 2. 准备 vault（示例；也可以复制已有 vault）
mkdir -p vaults/test/.obsidian

# 3. 编辑 .env：
#    - MCP_SOURCE_DIR：obsidian-mcp-http checkout 的路径
#    - PUID/PGID、端口、vault 路径、代理
#    - MCP_API_KEY（openssl rand -hex 32）
#    Windows/macOS Docker Desktop 一般保持 1000 即可

# 4. 构建 MCP 镜像并启动
docker compose up -d --build

# 5. 检查
docker compose ps
curl -i http://127.0.0.1:8811/mcp        # 不带 token 应为 401
curl -i http://127.0.0.1:8880/api/vault/list
```

MCP 客户端配置：

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

opencode 不会自动读取项目目录下的 `.env`，启动前需要在当前 shell 里设置 `MCP_API_KEY`（值取自 `.env` 中的同名变量）：

```powershell
# PowerShell：启动 opencode 前执行
$env:MCP_API_KEY = (Get-Content .env | Where-Object { $_ -match '^MCP_API_KEY=' }) -replace '^MCP_API_KEY=',''
opencode
```

```bash
# bash/zsh
export MCP_API_KEY="$(grep '^MCP_API_KEY=' .env | cut -d= -f2-)"
opencode
```

修改 `.env` 或 `opencode.json` 后，执行 `opencode reload`（或重启 opencode）让 MCP 客户端重新连接。

## MCP 鉴权

HTTP transport 使用 Bearer Token 鉴权。compose 把 `MCP_API_KEY` 以 `OBSIDIAN_MCP_HTTP_TOKEN` 传给容器，因此所有 MCP 请求必须携带：

```text
Authorization: Bearer <MCP_API_KEY>
```

该 transport **不支持** `X-API-Key`。也没有免鉴权的健康检查端点：不带 token 的 `GET /mcp` 返回 `401`，容器健康检查改用 HTTP 响应状态判断。

`MCP_API_KEY` 只放在 `.env`（已被 `.gitignore` 忽略），不要提交到仓库；为空时 compose 会拒绝启动。服务端只支持单个 token：轮换时同时修改 `.env` 和客户端配置，然后重启 `obsidian-mcp`。

验证：

```bash
# 无 token：401
curl -i http://127.0.0.1:8811/mcp

# 带 token：不应再是 401
curl -i -X POST http://127.0.0.1:8811/mcp \
  -H "Authorization: Bearer $MCP_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0.0"}}}'
```

## .env 变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 1000 | vault 属主；ignis 与 MCP 必须一致 |
| `IGNIS_BIND` / `IGNIS_PORT` | 127.0.0.1 / 8880 | Web UI 绑定地址与端口 |
| `MCP_BIND` / `MCP_PORT` | 127.0.0.1 / 8811 | MCP 绑定地址与端口 |
| `MCP_ALLOWED_HOST` | 127.0.0.1 | HTTP transport 额外接受的 `Host` 头；`MCP_BIND=0.0.0.0` 时改成局域网 IP/主机名 |
| `VAULT_ROOT` | ./vaults | ignis 挂载的 vault 根目录 |
| `VAULT_DIR` | ./vaults/test | MCP 挂载的单个 vault，必须位于 `VAULT_ROOT` 内 |
| `VAULT_ID` | notes | MCP 工具里的 `vault` 参数 |
| `MCP_API_KEY` | 无（必须设置） | 所有 MCP 请求的 Bearer Token |
| `MCP_SOURCE_DIR` | ../obsidian-mcp-http | 构建上下文：`obsidian-mcp-http` 本地 checkout |
| `MCP_IMAGE` | obsidian-mcp-http:2.1.0 | `docker compose build obsidian-mcp` 生成的镜像 tag |
| `DATA_DIR` | ./data | ignis 应用数据 |
| `WATCHER_PATCH` | ./patches/server-core-watcher.js | 轮询 watcher 补丁 |
| `HTTP_PROXY` / `HTTPS_PROXY` | 空 | 不需要代理就留空；同时作为构建参数 |
| `NO_PROXY` | localhost,... | 本地地址不走代理 |

所有相对路径都相对于 `docker-compose.yml` 所在目录。

## 版本固定

| 组件 | 固定值 |
|---|---|
| ignis | `nobbe/ignis@sha256:8faba277...`（Obsidian 1.14.4） |
| Node | `node:22.23.4-bookworm-slim`（构建与运行时基础镜像） |
| obsidian-mcp-http | `2.1.0`（`MCP_IMAGE` tag，从 `MCP_SOURCE_DIR` 构建） |

`obsidian-mcp-http` 是 [StevenStavrakis/obsidian-mcp](https://github.com/StevenStavrakis/obsidian-mcp/tree/v2.0.1)（MIT）的 fork，新增了 Streamable HTTP transport。已不再使用上游 stdio server + `supergateway` 包装层。

升级 ignis 时需要同步检查 `patches/server-core-watcher.js`：它是从镜像内 `watcher.js` 复制的，只多了 `usePolling` 三行。

## 常见坑

1. **Linux 上 UID 不一致**
   - 把 `PUID/PGID` 设成 vault 目录的属主：`stat -c '%u:%g' vaults`。
   - 然后 `sudo chown -R $PUID:$PGID vaults data`。
   - 症状：ignis 报 `EACCES`，MCP 写的笔记在 Web 里完全不出现。

2. **找不到构建上下文**
   - `MCP_SOURCE_DIR` 必须指向包含 `Dockerfile`、`package.json` 和 `src/` 的 checkout。
   - 相对路径从 compose 文件所在目录解析；checkout 在别处时请写绝对路径。

3. **绑定局域网地址后 Host 头被拒**
   - transport 会校验 `Host` 头（防 DNS rebinding）。
   - `MCP_BIND=0.0.0.0` 且客户端通过局域网 IP/主机名访问时，把 `MCP_ALLOWED_HOST` 设为该值并重建容器。

4. **代理写死**
   - 其他机器没有 `host.docker.internal:10808` 时，镜像构建和 Obsidian 下载会卡住。
   - 换机器时从 `.env.example` 重新生成 `.env`，不要直接复制本机的 `.env`。

5. **端口/容器名冲突**
   - 同机多套部署时修改 `IGNIS_PORT`、`MCP_PORT`、`IGNIS_CONTAINER_NAME`、`MCP_CONTAINER_NAME`。

6. **首次启动慢**
   - 需要下载 Obsidian 与 npm 包；entrypoint 还会尝试安装 `obsidian-headless`。
   - 网络不好时可能停在 `[ignis] Installing obsidian-headless...`，此时 Web 服务还没起来。
   - 可以先中止这个可选安装，让服务起来：
     ```bash
     docker exec -u 0 ignis sh -c 'pkill -f "npm install obsidian-headless"'
     ```
   - 代价是 headless sync 不可用；之后可单独执行 `docker exec -u 0 ignis npm install -g --prefix /usr/local obsidian-headless` 补装。

7. **缺 `patches/server-core-watcher.js`**
   - Docker 会把缺失的 bind 源建成目录，导致挂载到文件路径失败。
   - 整个项目目录一起复制，或把 `WATCHER_PATCH` 指向一个真实文件。

8. **源码改动没有生效**
   - 镜像从 `MCP_SOURCE_DIR` 构建；只重启容器不会重新构建镜像。
   - 修改 fork 后执行 `docker compose build obsidian-mcp && docker compose up -d obsidian-mcp`。

## 目录结构

```text
.
├── docker-compose.yml
├── .env.example
├── .env                 # 本地生成，不提交
├── patches/
│   └── server-core-watcher.js
├── vaults/
│   └── test/
│       ├── .obsidian/
│       └── *.md
└── data/                # ignis 运行时数据

../obsidian-mcp-http/    # MCP 源码 checkout（MCP_SOURCE_DIR）
├── Dockerfile
├── package.json
└── src/
```

## 安全

- `ignis` 和 MCP 默认都只绑 `127.0.0.1`。
- MCP 要求 Bearer Token，但它是静态共享密钥，没有用户身份、scope 或审计。
- 原生 transport 没有 `--tools` 白名单；持有有效 token 即可调用所有已配置工具。
- `ignis` 本身没有任何内置登录/鉴权；不要直接把它的端口暴露到公网。
- 如果设置 `MCP_BIND=0.0.0.0`，请放到 TLS 反代 / SSH 隧道 / Tailscale 后面，并设置 `MCP_ALLOWED_HOST`。
- 不要把 `.env` 提交到仓库（`.gitignore` 已忽略）。

## License

MIT，详见 [LICENSE](./LICENSE)。
