# Obsidian MCP 写入后 Web 界面不可见：修复报告

- 日期：2026-10-26
- 环境：Windows + Docker Desktop，Compose 项目 `notes`
- 涉及容器：`ignis`（浏览器版 Obsidian，:8080）、`obsidian-mcp`（Streamable HTTP，:8811）
- Vault：`./vaults/test`，vault id `notes`

## TL;DR

MCP 写入文件成功，但 Web 文件树里完全看不到新目录。原因是两个问题叠加：

1. **权限不匹配**：MCP 容器以 root 运行，写出 `root:root 600` 的文件；ignis 以 `node`(uid 1000) 运行，扫描时遇到 `EACCES`，整次 vault 索引刷新失败。
2. **跨容器文件事件丢失**：Windows + Docker Desktop 的 bind mount 不传递其他容器的 inotify 事件，ignis 的 chokidar 收不到变化，缓存一直停留在旧状态。

修复方式：MCP 改为 `user: "1000:1000"`；vault 属主统一为 `1000:1000`；给 ignis 挂载一个把 chokidar 改为轮询的 watcher 补丁。

结果：MCP 新建笔记后 1–3 秒内自动出现在 Web 文件树，无需刷新页面。

## 1. 现象

通过 MCP 调用 `create_note` 创建 `new notes/mcp-usage-notes.md`，接口返回成功：

```json
{
  "path": "new notes/mcp-usage-notes.md",
  "etag": "b47a4f15...",
  "transaction_id": "75ecb9a5..."
}
```

但在 ignis Web 界面（`http://localhost:8080/?vault=test`）中：

- 文件树里没有 `new notes` 目录；
- 直接访问文件树 API 也查不到：

```bash
curl "http://127.0.0.1:8080/api/fs/tree?vault=test"
# 返回中只有 .obsidian、测试2.md、这是一个测试文件.md 等，没有 new notes
```

而容器内 `ls` 明确能看到文件。

## 2. 诊断过程

### 2.1 确认文件已落盘

```bash
docker exec ignis ls -la /vaults/test
```

输出：

```text
drwxr-xr-x 1 root root 512 ... new notes
-rw-r--r-- 1 node node  29 ... 测试2.md
-rw-r--r-- 1 node node   7 ... 这是一个测试文件.md
```

文件确实存在，问题不在 MCP 写入。

### 2.2 检查属主与权限

```bash
docker exec ignis stat -c "%u:%g %a %n" "/vaults/test/new notes" \
  "/vaults/test/new notes/mcp-usage-notes.md" /vaults/test/.obsidian-mcp
```

输出：

```text
0:0      755 /vaults/test/new notes
0:0      600 /vaults/test/new notes/mcp-usage-notes.md
0:0      700 /vaults/test/.obsidian-mcp
```

对比应用进程：

```bash
docker exec ignis sh -lc 'id node; tr "\0" " " < /proc/1/cmdline'
# uid=1000(node) gid=1000(node)
# /proc/1: node /app/apps/ignis-server/server/index.js
```

结论：ignis 以 uid 1000 运行，无法读取 root 私有文件/目录。

### 2.3 刷新接口直接报 EACCES

```bash
curl -X POST http://127.0.0.1:8080/api/vault/refresh \
  -H "Content-Type: application/json" -d '{"vault":"test"}'
```

返回：

```json
{ "error": "EACCES", "code": "EACCES" }
```

说明整次 `reconcileVault` 在遍历目录时被权限错误中断。

### 2.4 代码路径

ignis 源码中的关键逻辑：

- `server/routes/fs.js` 的 `GET /api/fs/tree` 直接读 `bootstrapCache`，不实时扫描磁盘。
- `server/cache/crawl.js` 的 `walkTree()` 用 `fs.readdir` + `fs.stat` 递归遍历；遇到不可读目录会抛错。
- `buildEntry()` 在 `watcher.isWatching(vaultId)` 为真时**直接信任缓存**，不比较目录 mtime：

```js
if (cached) {
  if (
    !(watcher.isWatching(vaultId) && !revalidate) &&
    !(await dirMtimesUnchanged(vaultPath, cached.dirMtimes))
  ) {
    notifyStaleEntryServed(vaultId);
  }
  return cached;
}
```

- 只有 `POST /api/vault/refresh`、重启、或 30 分钟一次的 `treeReconcile` 才会真正重建缓存。

### 2.5 跨容器 inotify 不可靠

`packages/server-core/src/watcher.js` 使用 chokidar 默认配置（未开启 `usePolling`）：

```js
const watcher = chokidar.watch(vaultPath, {
  persistent: true,
  ignoreInitial: true,
  awaitWriteFinish: { stabilityThreshold: 300, pollInterval: 100 },
  ignored: (fullPath) => isIgnoredPath(path.relative(vaultPath, fullPath)),
});
```

在 Docker Desktop 的 Windows bind mount 上，另一个容器（obsidian-mcp）写入文件时，ignis 容器内的 inotify 收不到事件。watcher 认为一切正常，缓存永远不会更新。

> 实测：即使手动触发 refresh 更新了服务端缓存，已连接的浏览器页面也不会自动刷新文件树；需要页面重载。开启轮询后才会真正实时。

## 3. 根因

1. **主因：UID 不一致。** MCP 以 root 写入 `600` 文件，ignis 以 node(1000) 读取 → `EACCES` → 索引刷新失败 → 新目录完全不出现。
2. **放大因素：watcher 失效。** 即使权限正确，跨容器 inotify 不触发，已运行的服务端和浏览器都不会感知新文件。

## 4. 修复

### 4.1 MCP 以 node 用户运行

`docker-compose.yml`：

```diff
 obsidian-mcp:
   image: node:22-bookworm-slim
   container_name: obsidian-mcp
+  user: "1000:1000"   # 与 ignis 的 node 用户一致
   command: >
     npx -y supergateway
     --stdio "npx -y obsidian-mcp@2 serve --vault notes=/data"
     ...
   volumes:
     - ./vaults/test:/data
-    - npm-cache:/root/.npm
+    - npm-cache:/home/node/.npm
   environment:
+    - HOME=/home/node
     - HTTP_PROXY=http://host.docker.internal:10808
```

注意：只改 `user` 而不改 npm 缓存位置会导致 npx 无法写 `/root/.npm`，表现为启动卡住或 `EACCES`。缓存目录必须给 uid 1000。

### 4.2 修正已有文件属主

```bash
docker exec -u 0 ignis chown -R 1000:1000 /vaults/test
```

同时确认 `.obsidian-mcp` 不再是 `root 700`。修复后：

```text
1000:1000 755 /vaults/test/new notes
1000:1000 644 /vaults/test/new notes/mcp-usage-notes.md
1000:1000 755 /vaults/test/.obsidian-mcp
```

### 4.3 给 ignis 挂载轮询版 watcher

新增 `patches/server-core-watcher.js`，内容来自镜像内 `/app/packages/server-core/src/watcher.js`，只修改 chokidar 选项：

```diff
   const watcher = chokidar.watch(vaultPath, {
     persistent: true,
     ignoreInitial: true,
+    usePolling: true,
+    interval: 1000,
+    binaryInterval: 1000,
     awaitWriteFinish: {
       stabilityThreshold: 300,
       pollInterval: 100,
     },
     ignored: (fullPath) => isIgnoredPath(path.relative(vaultPath, fullPath)),
   });
```

在 compose 中以只读方式覆盖：

```diff
   ignis:
     volumes:
       - ./vaults:/vaults
       - ./data:/app/data
       - obsidian-app:/app/obsidian-app
+      - ./patches/server-core-watcher.js:/app/packages/server-core/src/watcher.js:ro
```

### 4.4 手动刷新（无补丁时的兜底）

```bash
curl -X POST http://127.0.0.1:8080/api/vault/refresh \
  -H "Content-Type: application/json" \
  -d '{"vault":"test"}'
```

刷新后还需重载浏览器页面才能看到变化。

## 5. 验证

1. 检查 MCP 写入的属主：

```bash
docker exec -u 1000 ignis stat -c "%u:%g %a %n" \
  "/vaults/test/new notes/mcp-usage-notes.md"
# 1000:1000 644 ...
```

2. MCP 创建临时笔记 `new notes/zz-live2-test.md`，**不手动刷新**，3 秒后查询文件树：

```bash
curl -s "http://127.0.0.1:8080/api/fs/tree?vault=test" | grep zz-live2
# 命中 new notes/zz-live2-test.md
```

3. 浏览器文件树中同样出现该笔记（无需 F5）。

4. 用 `obsidian_delete_note(mode: permanent)` 清理全部临时文件；最终 `new notes` 下只剩正式笔记。

## 6. 变更清单

| 文件 | 变更 |
|---|---|
| `docker-compose.yml` | obsidian-mcp 增加 `user: "1000:1000"`；npm 缓存改为 `/home/node/.npm`；增加 `HOME=/home/node`；ignis 挂载 watcher 补丁 |
| `patches/server-core-watcher.js` | 新增；chokidar 开启 `usePolling`（1s） |
| `new notes/mcp-usage-notes.md` | 更新配置说明、实时同步说明、排障表与修复记录 |
| `docs/obsidian-mcp-visibility-fix.md` | 本报告 |
| `new notes/obsidian-mcp-visibility-fix.md` | 本报告的 MCP 副本 |

## 7. 注意事项与回滚

- **补丁与镜像版本耦合**：`patches/server-core-watcher.js` 是 `nobbe/ignis:latest`（Obsidian 1.14.4）中 `watcher.js` 的副本。升级镜像后应重新导出并只重做 polling 三行改动，否则可能因上游改动而失效。
- **重建 ignis 会触发依赖重装**：entrypoint 会执行 `npm install -g obsidian-headless`。本次因 better-sqlite3 预编译包下载/编译过慢，为尽快恢复服务中止了安装，因此 `ob` 当前不可用，headless sync 不可用。需要时单独安装：

```bash
docker exec -u 0 ignis npm install -g --prefix /usr/local obsidian-headless
```

- **回滚 watcher 补丁**：删除 `ignis.volumes` 中覆盖 `watcher.js` 的那一行并 `docker compose up -d ignis`。回滚后重新回到“需要手动 refresh + 重载页面”的行为。
- **不要回滚 UID 修复**：把 MCP 改回 root 会再次产生不可读文件。
- **安全**：MCP 无鉴权，`8811` 仅绑定 `127.0.0.1`，不要直接暴露公网。

## 8. 验收清单

- [x] MCP 创建文件后，磁盘属主为 `1000:1000`
- [x] `/api/vault/refresh` 不再返回 `EACCES`
- [x] 文件树 API 能看到 `new notes/mcp-usage-notes.md`
- [x] Web 界面能看到该笔记
- [x] MCP 新建笔记后 1–3 秒内自动出现在 Web 界面
- [x] 临时测试文件已清理
- [x] 配置与排障过程已写入笔记和本报告

## 9. 后续：便携化与版本固定

本报告描述的是修复当时的配置。之后 compose 已重构为可移植版本：

- 所有机器相关配置移到 `.env`：代理、端口、UID/GID、vault 路径、容器名
- `.env.example` 作为部署模板，代理默认留空
- `README.md` 提供快速部署步骤与常见坑
- 新增 `npm-cache-init`：启动时把全新命名卷 chown 给 `PUID:PGID`，避免 npx 无写权限
- 版本固定：ignis 使用 digest（Obsidian 1.14.4），Node 使用 `22.23.4-bookworm-slim`，supergateway `4.2.1`，obsidian-mcp `2.0.1`
- 升级 ignis 后需要重新适配 `patches/server-core-watcher.js`
