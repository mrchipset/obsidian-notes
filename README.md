# Obsidian + MCP 部署

用 Docker Compose 部署一套「浏览器版 Obsidian + Obsidian MCP」：

- `ignis`：浏览器访问的 Obsidian Web，默认 `http://127.0.0.1:8080`
- `obsidian-mcp`：把 stdio 型 obsidian-mcp 包成 Streamable HTTP，默认 `http://127.0.0.1:8811/mcp`
- 两者共用同一个 vault 目录

## 前置条件

- Docker Engine / Docker Desktop + Compose v2.17 以上
- 一个真实 vault：目录里必须有 `.obsidian/`
- 首次启动能访问 npm registry 和 GitHub（需要下载 Obsidian 与 npm 包）
- 如果目标机器需要代理，在 `.env` 里配置 `HTTP_PROXY` / `HTTPS_PROXY`

## 快速开始

```bash
# 1. 生成配置
cp .env.example .env

# 2. 准备 vault（示例；也可以复制已有 vault）
mkdir -p vaults/test/.obsidian

# 3. 编辑 .env：至少确认 PUID/PGID、端口、vault 路径、代理
#    Windows/macOS Docker Desktop 一般保持 1000 即可

# 4. 启动
docker compose up -d

# 5. 检查
docker compose ps
curl http://127.0.0.1:8811/healthz
curl http://127.0.0.1:8080/api/vault/list
```

MCP 客户端配置：

```json
{
  "mcp": {
    "obsidian": {
      "type": "remote",
      "url": "http://127.0.0.1:8811/mcp",
      "enabled": true
    }
  }
}
```

## .env 变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 1000 | vault 属主；ignis 与 MCP 必须一致 |
| `IGNIS_BIND` / `IGNIS_PORT` | 127.0.0.1 / 8080 | Web UI 绑定地址与端口 |
| `MCP_BIND` / `MCP_PORT` | 127.0.0.1 / 8811 | MCP 绑定地址与端口 |
| `VAULT_ROOT` | ./vaults | ignis 挂载的 vault 根目录 |
| `VAULT_DIR` | ./vaults/test | MCP 挂载的单个 vault，必须位于 `VAULT_ROOT` 内 |
| `VAULT_ID` | notes | MCP 工具里的 `vault` 参数 |
| `DATA_DIR` | ./data | ignis 应用数据 |
| `WATCHER_PATCH` | ./patches/server-core-watcher.js | 轮询 watcher 补丁 |
| `HTTP_PROXY` / `HTTPS_PROXY` | 空 | 不需要代理就留空 |
| `NO_PROXY` | localhost,... | 本地地址不走代理 |

所有路径都相对于 `docker-compose.yml` 所在目录。

## 版本固定

| 组件 | 固定值 |
|---|---|
| ignis | `nobbe/ignis@sha256:8faba277...`（Obsidian 1.14.4） |
| Node | `node:22.23.4-bookworm-slim` |
| supergateway | `4.2.1` |
| obsidian-mcp | `2.0.1` |

obsidian-mcp 源码：[StevenStavrakis/obsidian-mcp](https://github.com/StevenStavrakis/obsidian-mcp/tree/v2.0.1)（MIT）。

升级 ignis 时需要同步检查 `patches/server-core-watcher.js`：它是从镜像内 `watcher.js` 复制的，只多了 `usePolling` 三行。

## 常见坑

1. **Linux 上 UID 不一致**
   - 把 `PUID/PGID` 设成 vault 目录的属主：`stat -c '%u:%g' vaults`。
   - 然后 `sudo chown -R $PUID:$PGID vaults data`。
   - 症状：ignis 报 `EACCES`，MCP 写的笔记在 Web 里完全不出现。

2. **全新的 npm-cache 卷不可写**
   - 命名卷默认是 root 属主，而 MCP 以 `PUID` 运行。
   - compose 已用 `npm-cache-init` 一次性 chown；如果你删掉了这个服务，就要自己处理。

3. **代理写死**
   - 其他机器没有 `host.docker.internal:10808` 时，npx 和 Obsidian 下载会卡住。
   - 换机器时从 `.env.example` 重新生成 `.env`，不要直接复制本机的 `.env`。

4. **端口/容器名冲突**
   - 同机多套部署时修改 `IGNIS_PORT`、`MCP_PORT`、`IGNIS_CONTAINER_NAME`、`MCP_CONTAINER_NAME`。

5. **首次启动慢**
   - 需要下载 Obsidian 与 npm 包；entrypoint 还会尝试安装 `obsidian-headless`。
   - 网络不好时可能停在 `[ignis] Installing obsidian-headless...`，此时 Web 服务还没起来。
   - 可以先中止这个可选安装，让服务起来：
     ```bash
     docker exec -u 0 ignis sh -c 'pkill -f "npm install obsidian-headless"'
     ```
   - 代价是 headless sync 不可用；之后可单独执行 `docker exec -u 0 ignis npm install -g --prefix /usr/local obsidian-headless` 补装。

6. **缺 `patches/server-core-watcher.js`**
   - Docker 会把缺失的 bind 源建成目录，导致挂载到文件路径失败。
   - 整个项目目录一起复制，或把 `WATCHER_PATCH` 指向一个真实文件。

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
```

## 安全

- `ignis` 和 MCP 默认都只绑 `127.0.0.1`。
- MCP 没有鉴权；如果设置 `MCP_BIND=0.0.0.0`，请放到反代 / SSH 隧道 / 防火墙后面。
- 不要把 `.env` 提交到仓库（`.gitignore` 已忽略）。
