# Obsidian MCP 使用笔记

本文记录当前环境里 Obsidian MCP 的配置方式，以及可调用的接口。内容基于本机 `docker-compose.yml`、`opencode.json` 与实际挂载的 MCP 工具整理。

## 1. 整体架构

```
客户端 (opencode / 其他 MCP Client)
        │  Streamable HTTP
        ▼
http://127.0.0.1:8811/mcp        <- supergateway 包装层
        │  stdio
        ▼
obsidian-mcp@2 serve --vault notes=/data
        │  读写
        ▼
./vaults/test  (即 vault id = notes)
        ▲
        │ 同一个目录
        ▼
ignis (浏览器版 Obsidian)  http://127.0.0.1:8080
```

- `obsidian-mcp` 本身是 stdio 型 MCP Server，不能直接给远程客户端用。
- `supergateway` 把它转成 Streamable HTTP，暴露在 `8811` 端口。
- 同一个 compose 文件里的 `ignis`（`nobbe/ignis`，端口 `8080`）是浏览器版 Obsidian，与 MCP 共用同一个 vault 目录。
- vault id 由启动参数 `--vault notes=/data` 决定，所以工具里传的 `vault` 都是 `notes`。

## 2. 服务端配置（docker-compose.yml + .env）

编排已参数化：`docker-compose.yml` 只保留结构，机器相关配置全部放在 `.env`。

```bash
cp .env.example .env   # 然后按目标机器修改
```

关键变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PUID` / `PGID` | 1000 | vault 属主；ignis 与 MCP 必须一致 |
| `IGNIS_BIND` / `IGNIS_PORT` | 127.0.0.1 / 8080 | Web UI 绑定地址与端口 |
| `MCP_BIND` / `MCP_PORT` | 127.0.0.1 / 8811 | MCP 绑定地址与端口 |
| `VAULT_ROOT` / `VAULT_DIR` | ./vaults / ./vaults/test | ignis 看整个根目录，MCP 只看其中一个 vault |
| `VAULT_ID` | notes | MCP 工具里的 `vault` 参数 |
| `DATA_DIR` | ./data | ignis 应用数据 |
| `WATCHER_PATCH` | ./patches/server-core-watcher.js | 轮询 watcher 补丁 |
| `HTTP_PROXY` / `HTTPS_PROXY` | 空 | 不需要代理就留空 |
| `IGNIS_IMAGE` | `nobbe/ignis@sha256:8faba...` | 固定 digest（Obsidian 1.14.4） |
| `NODE_IMAGE` | `node:22.23.4-bookworm-slim` | 固定 Node 版本 |
| `SUPERGATEWAY_VERSION` | 4.2.1 | npm 包固定版本 |
| `OBSIDIAN_MCP_VERSION` | 2.0.1 | npm 包固定版本 |

MCP 核心片段：

```yaml
obsidian-mcp:
  image: ${NODE_IMAGE}
  user: "${PUID:-1000}:${PGID:-1000}"
  depends_on:
    npm-cache-init:
      condition: service_completed_successfully
  command: >
    npx -y supergateway@${SUPERGATEWAY_VERSION}
    --stdio "npx -y obsidian-mcp@${OBSIDIAN_MCP_VERSION} serve --vault ${VAULT_ID}=/data"
    --outputTransport streamableHttp
    --port 8811
    --host 0.0.0.0
    --healthEndpoint /healthz
  volumes:
    - "${VAULT_DIR}:/data"
    - npm-cache:/home/node/.npm
```

`npm-cache-init` 是一次性服务，启动时把命名卷 chown 给 `PUID:PGID`。否则全新卷是 root 属主，而 MCP 以非 root 运行，npx 会因无法写缓存而启动失败。

```yaml
npm-cache-init:
  image: ${NODE_IMAGE}
  user: "0:0"
  volumes:
    - npm-cache:/cache
  command: ["sh", "-c", "chown -R ${PUID:-1000}:${PGID:-1000} /cache"]
  restart: "no"
```

要点：

- **挂载目录必须包含 `.obsidian` 目录**，否则不会被识别为 vault。
- **UID 必须对齐（最关键）**：ignis 以 `PUID` 运行。如果 MCP 以 root 写入，文件会是 `root:root 600`，ignis 扫描时会报 `EACCES`，导致整个 vault 的索引刷新失败，新笔记在 Web 界面**完全不出现**。让 MCP 也使用相同的 `PUID:PGID`。
- **npm 缓存要给非 root 用户**：挂到 `/home/node/.npm`，并设置 `HOME=/home/node`；不要再用 `/root/.npm`。
- **端口默认只绑本机**：MCP 没有鉴权，`127.0.0.1` 最安全。若确需局域网访问，改 `MCP_BIND=0.0.0.0` 并加反代/防火墙。
- 健康检查：`GET http://127.0.0.1:8811/healthz`，`200` 即正常。

启动与检查：

```bash
docker compose up -d
docker compose ps
curl http://127.0.0.1:8811/healthz
```

## 2.1 Web 界面实时同步（Docker Desktop）

在 Windows/macOS + Docker Desktop 的 bind mount 上，跨容器的 inotify 事件不可靠：MCP 写入文件后，ignis 里的 chokidar 收不到事件，缓存不会更新，Web 界面就看不到新笔记。

解决办法是给 ignis 挂一个只读的 watcher 补丁，把 chokidar 改成轮询。路径由 `WATCHER_PATCH` 控制：

```yaml
ignis:
  volumes:
    - "${VAULT_ROOT}:/vaults"
    - "${WATCHER_PATCH}:/app/packages/server-core/src/watcher.js:ro"
```

补丁内容只是在 `chokidar.watch()` 的选项里加了：

```js
usePolling: true,
interval: 1000,
binaryInterval: 1000,
```

效果：MCP 写入后约 1–3 秒，Web 界面的文件树会自动出现新笔记，无需刷新页面。

如果是原生 Linux 部署，inotify 正常，补丁可以保留（每秒轮询，开销很小），也可以去掉这行挂载。补丁与 ignis 版本耦合，升级 `IGNIS_IMAGE` 后需要重新导出并重做这三行改动。

如果没有这个补丁，也可以手动触发一次服务端刷新，然后重新加载页面：

```bash
curl -X POST http://127.0.0.1:8080/api/vault/refresh \
  -H "Content-Type: application/json" \
  -d '{"vault":"test"}'
```

## 3. 客户端配置（opencode.json）

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "obsidian": {
      "type": "remote",
      "url": "http://127.0.0.1:8811/mcp",
      "enabled": true
    }
  }
}
```

工具名会带上服务器前缀，实际调用形如 `obsidian_obsidian_read_note`（MCP server 名 `obsidian` + 工具名 `obsidian_read_note`）。

如果是只支持 stdio 的客户端（如 Claude Desktop），可以跳过 supergateway，直接配置：

```json
{
  "mcpServers": {
    "obsidian": {
      "command": "npx",
      "args": ["-y", "obsidian-mcp@2", "serve", "--vault", "notes=/绝对路径/vaults/test"]
    }
  }
}
```

## 4. 可用接口

所有工具都需要 `vault` 参数（本环境固定为 `notes`）。路径一律是**相对 vault 根目录**、使用正斜杠 `/`，禁止绝对路径和 `..`。

### 4.1 Vault 与目录

| 工具 | 参数 | 说明 |
|---|---|---|
| `obsidian_list_vaults` | 无 | 列出已配置的 vault id，不返回宿主路径 |
| `obsidian_create_directory` | `vault`, `path`, `recursive`(默认 true) | 创建目录；已存在则报错 |

### 4.2 读取与写入

| 工具 | 参数 | 说明 |
|---|---|---|
| `obsidian_read_note` | `vault`, `path`, `cursor?`, `max_chars?`(1–25000, 默认 20000) | 分页读取 Markdown；返回 `etag`、`has_more`、`cursor` |
| `obsidian_create_note` | `vault`, `path`, `content?`, `create_parents?`(默认 true) | 原子创建，不覆盖已有文件；自动建父目录 |
| `obsidian_edit_note` | `vault`, `path`, `operation`(`append`/`prepend`/`replace`), `content`, `if_match?` | 按字节追加/前置/整体替换，从不删除文件 |
| `obsidian_delete_note` | `vault`, `path`, `mode`(`trash`/`permanent`), `reason?`, `backlink_action?`(`preserve`/`mark_broken`), `if_match?`, `confirm_path?` | 默认进 MCP 回收站（可恢复）；永久删除必须传 `mode: permanent` 且 `confirm_path` 与路径一致 |
| `obsidian_move_note` | `vault`, `source`, `destination`, `update_links?`(默认 true), `if_match?` | 移动/重命名，目标已存在则拒绝；可同步更新无歧义的反向链接 |

### 4.3 搜索（全文搜索）

| 工具 | 参数 | 说明 |
|---|---|---|
| `obsidian_search_vault` | `vault`, `query`, `mode`(`content`/`filename`/`both`/`tag`), `scope?`, `limit?`(1–200, 默认 50), `cursor?`, `case_sensitive?` | 按正文、文件名或标签搜索；返回带游标的分页结果 |

**`mode=content` 就是全文搜索，也是默认值。**

- 源码仓库：[StevenStavrakis/obsidian-mcp](https://github.com/StevenStavrakis/obsidian-mcp)（MIT）
- 当前固定版本 v2.0.1：[tag v2.0.1](https://github.com/StevenStavrakis/obsidian-mcp/tree/v2.0.1)（commit `6d46b24`）
- 实现文件：[`src/utils/search.ts`](https://github.com/StevenStavrakis/obsidian-mcp/blob/v2.0.1/src/utils/search.ts)

#### 参数

| 参数 | 说明 |
|---|---|
| `query` | 要查找的文本，1–1000 字符 |
| `mode` | `content`（正文，默认）/ `filename`（相对路径）/ `both` / `tag` |
| `scope` | 可选，限定到某个 vault 子目录 |
| `case_sensitive` | 默认 `false`，忽略大小写 |
| `limit` | 每页 1–200，默认 50 |
| `cursor` | 用上一页的 `next_cursor` 翻页；游标与 query/scope/mode/case_sensitive 绑定 |

#### 行为

- 遍历 `scope` 下所有 `.md` 文件，逐个读取，按行做**字面量包含匹配**（`line.includes(query)`）。
- 一行最多返回一条匹配；`line` 是正文行号（从 1 开始），`snippet` 是该行 trim 后最多 300 字符。
- `mode=filename` 匹配的是相对路径，包含目录名；`line` 为 0。
- `mode=both` 会同时返回文件名匹配和正文行匹配。
- `mode=tag` 匹配标签本身或子标签（`query/` 前缀），默认忽略大小写。
- 隐藏文件和目录、符号链接会被跳过；只搜 Markdown，不搜附件、PDF、Canvas。
- 不可读的文件会跳过，并在 `warnings[]` 中列出。
- 响应总大小约 25,000 字符封顶，因此可能未到 `limit` 就提前分页。

返回结构示例：

```json
{
  "matches": [
    {
      "path": "new notes/obsidian-mcp-visibility-fix.md",
      "kind": "content",
      "line": 259,
      "snippet": "- **重建 ignis 会触发依赖重装**：entrypoint 会执行 `npm install -g obsidian-headless`。本次因 better-sqlite3 ..."
    }
  ],
  "count": 1,
  "has_more": false,
  "warnings": []
}
```

#### 限制

- **不支持正则**，也不支持 Obsidian 原生搜索语法（`path:`、`file:`、`tag:`、`line:`、`/regex/` 等）。
- **多词是整串匹配**：`"docker compose"` 只匹配连续出现的这两个词，不是 `docker AND compose`。
- **没有分词、排序、模糊匹配或词干处理**，结果按路径和行号顺序返回。
- **没有倒排索引**：每次搜索都线性扫描所有 Markdown，大 vault 会慢。
- 不支持搜索 PDF、图片、附件、Canvas。

#### 示例

全文搜索（限定目录）：

```json
{
  "vault": "notes",
  "query": "better-sqlite3",
  "mode": "content",
  "scope": "new notes",
  "case_sensitive": false,
  "limit": 50
}
```

文件名 + 正文一起搜：

```json
{
  "vault": "notes",
  "query": "mcp",
  "mode": "both",
  "limit": 50
}
```

按标签搜：

```json
{
  "vault": "notes",
  "query": "project/active",
  "mode": "tag"
}
```

实际使用建议：

- 多关键词先拆成多次单关键词搜索，再在结果里取交集。
- 已知目录时用 `scope`，能明显减少扫描量。
- 结果多时把 `next_cursor` 原样传给 `cursor`，不要改写。

### 4.4 标签

| 工具 | 参数 | 说明 |
|---|---|---|
| `obsidian_add_tags` | `vault`, `paths[]`(≤500), `tags[]`(≤100), `location`(`frontmatter`/`content`/`both`, 默认 frontmatter), `position`(`start`/`end`), `normalization`(`preserve`/`lowercase`/`kebab`), `expected_etags?` | 多笔记原子批量加标签 |
| `obsidian_remove_tags` | `vault`, `paths[]`, `tags?`, `patterns?`(支持单个 `*` 通配), `location`(默认 both), `include_children?`, `normalization?`, `expected_etags?` | 批量删标签；`tags` 与 `patterns` 至少给一个 |
| `obsidian_manage_tags` | `operation`(`add`/`remove`), `vault`, `paths[]`, `tags?`, `patterns?`, `location?`, `position?`, `include_children?`, `normalization?`, `expected_etags?` | 上面两个工具的统一入口 |
| `obsidian_rename_tag` | `vault`, `old_tag`, `new_tag`, `location`(默认 both), `include_children?`, `normalization?`, `expected_etags?` | 全库重命名标签，单事务完成 |

## 5. 并发与安全要点

- **先读后写**：修改前先 `read_note` 拿 `etag`，写入时传 `if_match`，避免覆盖并发修改。
- **删除可恢复**：默认进 `.obsidian-mcp/trash/`，同时写 `.json` 元数据记录 `original_path` 和 `deleted_at`。只有显式 `permanent` 才不可恢复。
- **路径校验**：工具会拒绝绝对路径、反斜杠、`.` / `..` 段和保留目录（如 `.obsidian`）。
- **批量操作是原子的**：多笔记标签操作若任一失败则全部回滚。
- **无鉴权**：MCP 端口只绑 `127.0.0.1`；不要直接暴露到公网。

## 6. 常见操作示例

创建笔记：

```json
{
  "vault": "notes",
  "path": "new notes/example.md",
  "content": "# 示例\n\n正文内容\n",
  "create_parents": true
}
```

追加内容（带并发保护）：

```json
{
  "vault": "notes",
  "path": "new notes/example.md",
  "operation": "append",
  "content": "\n- 新增一行\n",
  "if_match": "<read_note 返回的 etag>"
}
```

移动并修复反链：

```json
{
  "vault": "notes",
  "source": "new notes/example.md",
  "destination": "archive/example.md",
  "update_links": true
}
```

## 7. 排障

| 现象 | 排查方向 |
|---|---|
| 客户端连不上 | 容器是否启动：`docker compose ps`；`curl http://127.0.0.1:8811/healthz` |
| 看不到 vault | 挂载目录缺少 `.obsidian`，或 `--vault` 参数与工具里的 `vault` 不一致 |
| 写入报冲突 | `if_match` 与最新 `etag` 不匹配，重新读取后重试 |
| 路径被拒绝 | 使用了绝对路径、反斜杠或 `..`；改成 vault 内相对路径 |
| 容器内拉包失败 | 代理变量是否生效（`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`） |
| Web 界面看不到 MCP 新写的笔记 | 1) 检查文件属主：必须是 `PUID:PGID` 且 ignis 可读；2) 有 root 文件时 refresh 会返回 `EACCES`；3) 确认 watcher 轮询补丁已挂载；4) 手动 refresh 并重载页面 |
| `/api/vault/refresh` 返回 `EACCES` | vault 里有 `root:root 600` 的文件/目录，执行 `docker exec -u 0 ignis chown -R $PUID:$PGID /vaults/test` |
| 全新部署时 MCP 启动失败 / npm 报 EACCES | 确认 `npm-cache-init` 已执行：它负责把 `npm-cache` 卷 chown 给 `PUID:PGID` |
| 重建 ignis 卡在 `Installing obsidian-headless` | 这是可选依赖，可中止让服务先起来：`docker exec -u 0 ignis sh -c 'pkill -f "npm install obsidian-headless"'`；之后 headless sync 暂不可用 |

### 本次问题的修复命令

```bash
# 1. 修正已有文件的属主
docker exec -u 0 ignis chown -R 1000:1000 /vaults/test

# 2. 重建 MCP，使其以 1000:1000 写入
docker compose up -d obsidian-mcp

# 3. 让 ignis 重新扫描（有轮询补丁时通常不需要）
curl -X POST http://127.0.0.1:8080/api/vault/refresh \
  -H "Content-Type: application/json" \
  -d '{"vault":"test"}'
```

## 8. 本次修复记录

- 现象：MCP 写入 `new notes/mcp-usage-notes.md` 成功，但 Web 界面完全看不到该目录。
- 根因 1：MCP 容器以 root 运行，写出 `root:root 600` 文件；ignis 以 node(1000) 运行，爬取目录时 `EACCES`，整次索引刷新失败。
- 根因 2：Docker Desktop 的 bind mount 不传递跨容器 inotify 事件，即使权限正确，已打开的页面也不会自动出现新文件。
- 修复：MCP 改为 `user: "1000:1000"` + npm 缓存挂到 `/home/node/.npm`；vault 属主统一为 `1000:1000`；ignis 挂载轮询版 watcher 补丁。
- 结果：MCP 新建笔记后 1–3 秒内自动出现在 Web 文件树中，无需刷新页面。
