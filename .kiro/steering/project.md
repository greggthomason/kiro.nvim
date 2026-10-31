# kiro.nvim

A native Lua Neovim (0.12+) plugin that is an ACP (Agent Client Protocol) client for Kiro. It spawns
`kiro-cli acp` and speaks newline-delimited JSON-RPC 2.0 over stdio. Must stay compatible with lazy.nvim
and AstroNvim. No external Lua or runtime dependencies.

## Architecture

```
plugin/kiro.lua          user commands only (lazy-safe; requires happen on demand)
lua/kiro/init.lua        public API + singleton session/panel, setup(), keymaps, :checktime hook
lua/kiro/config.lua      defaults, validation, cwd, keymap resolution
lua/kiro/acp/rpc.lua     process spawn (vim.system), line framing, request/response matching
lua/kiro/acp/client.lua  ACP lifecycle: initialize, session/new|load, prompt, cancel; routes agent requests
lua/kiro/session.lua     state machine (disconnected/connecting/ready/prompting), transcript model, events
lua/kiro/permission.lua  session/request_permission via vim.ui.select
lua/kiro/context.lua     prompt blocks: text, resource_link, visual selection formatting
lua/kiro/ui/panel.lua    transcript + prompt windows, rendering (Panel.format is pure)
lua/kiro/health.lua      :checkhealth kiro
```

Data flow: commands -> `kiro` API -> `Session` -> `Client` -> `Rpc` <-> `kiro-cli acp`. Agent notifications flow
back `Rpc` -> `Client` -> `Session` (transcript + events) -> `Panel` (re-render, coalesced with vim.schedule).

## Conventions and gotchas

- Capabilities: the client advertises NO `fs` or `terminal` support (v1). Kiro edits files on disk itself; the
  session emits a `"files"` event after tool completion and turn end, and init.lua runs `:checktime`.
- All stdout/stderr/exit callbacks are wrapped in `vim.schedule`; never call `vim.fn`/`vim.api` from fast contexts.
- `Rpc._on_exit` calls `on_exit` BEFORE failing pending requests so session state is updated first. Failed
  in-flight requests carry `err.closed = true`; the exit handler is responsible for reporting the crash.
- Session reads `cmd`/`env` from config at connect time (so a later `setup()` works); `session_id` is read at
  creation. Giving `session_id` resumes through `session/load` (history is replayed as updates).
- ACP paths must be absolute, line numbers 1-based. Kiro sends `_kiro.dev/*` extension notifications; they are
  deliberately ignored.
- Keymaps are opt-in (`keymaps = false` by default).
- macOS: `/tmp` resolves to `/private/tmp`; do not compare raw `/tmp` paths in tests.
- Shell is fish: no heredocs in terminal commands.

## Testing

- `make test` runs the mini.test suite (clones mini.test into `.deps/` on first run; needs git + network once).
- Tests never need Kiro: `tests/fake_agent.lua` is a scripted ACP agent run with `nvim -l`. Prompt text selects
  behaviour: `slow`, `perm`, `blocks`, `die`, `bad`, anything else echoes with a plan and tool call.
- UI/command tests use child Neovim instances (`tests/child_init.lua`).
- Real-agent smoke test: `nvim --headless -u tests/child_init.lua -l scripts/smoke.lua "prompt"` (sends one
  real prompt to kiro-cli).
- Add or update tests with every behaviour change; run `make test` before finishing.

## Development workflow

The plugin is loaded from this directory via lazy.nvim `dir = ...`. Code changes take effect after restarting
Neovim (modules are cached and the session is a singleton). A broken edit can break the chat hosting the
session, so commit often and keep a terminal `kiro-cli chat` available as a fallback.

## Roadmap

Attach to existing sessions with a picker (`session/list` + `session/load`; the load path already exists),
buffer-aware `fs/read_text_file` / `fs/write_text_file`, diff review of proposed edits, terminal support.
