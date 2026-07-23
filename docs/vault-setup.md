# Vault Context Setup (semantic search over your Obsidian vault)

Muya's **Vault Context** panel shows notes from your Obsidian vault that relate to
what you're doing. It works by semantic search (meaning, not keywords) over the
vault's embeddings.

Three things must be present on a machine for it to work. The setup script does
the first; you do the other two once.

| # | What | Who does it |
|---|------|-------------|
| 1 | The search engine (`smart-connections-mcp` + Python deps like torch) | `./scripts/setup-vault.sh` |
| 2 | The Obsidian **Smart Connections** plugin, indexed (writes `.smart-env/` in the vault) | you, in Obsidian |
| 3 | Point Muya at the vault folder | you, in Muya's Vault Source panel |

## One-command setup

From the Muya repo on the machine that needs it:

```bash
./scripts/setup-vault.sh
```

It installs the engine to `~/smart-connections-mcp`, builds a Python venv, installs
the deps, and **verifies** the venv can import `sentence_transformers` (the exact
check Muya makes before using it). Re-runnable anytime.

Override the location with `VAULT_MCP_DIR=/some/dir ./scripts/setup-vault.sh`.

## Then, in Obsidian

- Install/enable the **Smart Connections** community plugin.
- Let it index the vault. This creates a `.smart-env/` folder inside the vault.
  Without it, search returns nothing even when step 1 succeeded.

## Then, in Muya

- Open the **Vault Source** panel.
- Set the vault path (the folder containing `.obsidian/` and `.smart-env/`) — or
  let auto-detect find it — and press **Restart**.

## How Muya finds the Python interpreter

`vault.rs → resolve_python()` picks, in order:

1. `VAULT_PYTHON` — explicit override (env var), trusted as-is.
2. `<mcp_dir>/.venv/bin/python` — **only if** it actually has the deps installed
   (a broken/empty venv is skipped so it can't shadow a working install).
3. `/opt/homebrew/bin/python3.11` — legacy fallback (works only if the heavy deps
   are installed globally there — this was the original dev machine's accident).
4. `python3` on `PATH` — last resort.

`<mcp_dir>` defaults to `~/smart-connections-mcp`; override with `VAULT_MCP_DIR`.

## Why it failed on a second machine (the bug this fixes)

The app used to hard-require `/opt/homebrew/bin/python3.11` with the deps installed
**globally** there — which was true on the original machine by accident, but not
on a fresh one. Meanwhile the vendored `install.sh` built a `.venv` the app never
used. Now the app prefers a deps-verified `.venv`, and `setup-vault.sh` builds
exactly that — so setup is reproducible: clone → `./scripts/setup-vault.sh` → set
vault path.
