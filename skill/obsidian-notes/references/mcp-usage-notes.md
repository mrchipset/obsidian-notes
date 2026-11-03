# Obsidian MCP Usage Reference

This reference summarizes the `obsidian-mcp-http` 2.1.0 toolset. The server is built from the local fork and exposes Streamable HTTP natively; supergateway is no longer used.

Canonical repo document: [`../../../docs/mcp-usage-notes.md`](../../../docs/mcp-usage-notes.md)

## Architecture

```text
MCP client (opencode)
        │ Streamable HTTP + Authorization: Bearer
        ▼
http://127.0.0.1:8811/mcp
        │
        ▼
obsidian-mcp serve --vault notes=/data --transport http
        │
        ▼
vault mounted at /data
```

- MCP server name: `obsidian`
- Vault id: `notes`
- Endpoint: `http://127.0.0.1:8811/mcp`
- No `/healthz`; an unauthenticated `GET /mcp` returning `401` means the service is listening
- Tools require a `vault` parameter. In this deployment it is `notes`.

## Tool catalog

### Vault and directories

| Tool | Main parameters | Notes |
|---|---|---|
| `obsidian_list_vaults` | none | Lists configured vault ids; does not return host paths |
| `obsidian_create_directory` | `vault`, `path`, `recursive` | Creates a directory; fails if it already exists |

### Read and write

| Tool | Main parameters | Notes |
|---|---|---|
| `obsidian_read_note` | `vault`, `path`, `cursor?`, `max_chars?` | Returns `etag`, `has_more`, `cursor`; `max_chars` is 1–25000 |
| `obsidian_create_note` | `vault`, `path`, `content?`, `create_parents?` | Atomic create; refuses to overwrite an existing note |
| `obsidian_edit_note` | `vault`, `path`, `operation`, `content`, `if_match?` | `operation` is `append`, `prepend`, or `replace` |
| `obsidian_delete_note` | `vault`, `path`, `mode`, `reason?`, `backlink_action?`, `if_match?`, `confirm_path?` | Defaults to trash; permanent deletion needs `mode: permanent` and matching `confirm_path` |
| `obsidian_move_note` | `vault`, `source`, `destination`, `update_links?`, `if_match?` | Refuses to overwrite an existing destination; can update unambiguous backlinks |

### Search

| Tool | Main parameters | Notes |
|---|---|---|
| `obsidian_search_vault` | `vault`, `query`, `mode`, `scope?`, `limit?`, `cursor?`, `case_sensitive?` | `mode`: `content`, `filename`, `both`, `tag` |

Search details:

- `mode=content` is full-text search and the default.
- Matching is literal `line.includes(query)`, not regex.
- Obsidian search syntax such as `path:`, `file:`, `tag:`, `/regex/` is not supported.
- A multi-word query is one contiguous phrase, not `AND`.
- `mode=filename` matches the relative path and returns `line: 0`.
- `mode=both` returns both filename and content matches.
- Hidden files, symlinks, PDFs, images, attachments, and Canvas files are skipped.
- Results are capped around 25,000 characters per response, so pagination can happen before `limit`.
- Use `next_cursor` unchanged as `cursor` on the next request.

### Tags

| Tool | Main parameters | Notes |
|---|---|---|
| `obsidian_add_tags` | `vault`, `paths[]`, `tags[]`, `location`, `position`, `normalization`, `expected_etags?` | Atomic batch add |
| `obsidian_remove_tags` | `vault`, `paths[]`, `tags?`, `patterns?`, `location`, `include_children?`, `normalization?`, `expected_etags?` | At least one of `tags` or `patterns` is required |
| `obsidian_manage_tags` | `operation`, `vault`, `paths[]`, ... | Unified add/remove entry point |
| `obsidian_rename_tag` | `vault`, `old_tag`, `new_tag`, ... | Renames a tag across the vault in one transaction |

## Common patterns

### Search then read

```json
{
  "vault": "notes",
  "query": "docker compose",
  "mode": "content",
  "scope": "new notes",
  "limit": 20
}
```

Then:

```json
{
  "vault": "notes",
  "path": "new notes/mcp-usage-notes.md"
}
```

### Read before edit

1. `obsidian_read_note` returns an `etag`.
2. Pass that value as `if_match` to `obsidian_edit_note`.
3. If the edit returns a conflict, re-read and retry.

```json
{
  "vault": "notes",
  "path": "new notes/example.md",
  "operation": "append",
  "content": "\n- New line\n",
  "if_match": "<etag from read_note>"
}
```

### Create a note

```json
{
  "vault": "notes",
  "path": "new notes/example.md",
  "content": "# Example\n\nBody\n",
  "create_parents": true
}
```

### Move and fix backlinks

```json
{
  "vault": "notes",
  "source": "new notes/example.md",
  "destination": "archive/example.md",
  "update_links": true
}
```

### Delete safely

Prefer the default trash mode:

```json
{
  "vault": "notes",
  "path": "new notes/example.md",
  "mode": "trash",
  "reason": "duplicate"
}
```

Permanent deletion requires explicit user confirmation:

```json
{
  "vault": "notes",
  "path": "new notes/example.md",
  "mode": "permanent",
  "confirm_path": "new notes/example.md"
}
```

## Path validation

The server rejects:

- absolute paths
- backslashes
- empty or `.` / `..` segments
- reserved directories such as `.obsidian`
- symlinks and junctions

Use relative paths with forward slashes only.

## Errors

| Error | Meaning | Fix |
|---|---|---|
| `401 Unauthorized` | Missing or wrong bearer token | Set `MCP_API_KEY`, send `Authorization: Bearer`, restart opencode |
| `403 Forbidden` | `Host` header rejected | Set `MCP_ALLOWED_HOST` and recreate the container |
| `if_match` conflict | Note changed since it was read | Re-read, use the new `etag` |
| `VAULT_PERMISSION_DENIED` | Vault is not writable by the container | Fix owner/permissions |
| Path rejected | Absolute path, backslash, or `..` | Use a relative vault path |
| Connection refused | MCP service is not running | Start the Docker service |

## Related docs

- Authentication and public exposure: [`authentication.md`](authentication.md)
- Full repo auth design: [`../../../AUTHENTICATION.md`](../../../AUTHENTICATION.md)
