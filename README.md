# kiro.nvim

A native Lua [Agent Client Protocol](https://agentclientprotocol.com) client that connects Neovim to
[Kiro](https://kiro.dev). It spawns `kiro-cli acp`, speaks JSON-RPC 2.0 over stdio, and gives you a chat
panel inside Neovim.

- Neovim **0.12+**, no external runtime or Lua dependencies
- `kiro-cli` on your `$PATH` (and logged in)

## Install

### lazy.nvim

```lua
{
  "greggthomason/kiro.nvim",
  cmd = { "Kiro", "KiroToggle", "KiroAsk", "KiroSelection", "KiroCancel", "KiroRestart" },
  keys = {
    { "<leader>kk", "<Cmd>KiroToggle<CR>", desc = "Kiro: toggle panel" },
    { "<leader>ka", ":KiroAsk ", desc = "Kiro: ask" },
    { "<leader>ks", ":KiroSelection<CR>", mode = "x", desc = "Kiro: send selection" },
    { "<leader>kc", "<Cmd>KiroCancel<CR>", desc = "Kiro: cancel" },
  },
  opts = {},
}
```

### AstroNvim

Create `lua/plugins/kiro.lua` in your user config:

```lua
---@type LazySpec
return {
  "greggthomason/kiro.nvim",
  cmd = { "Kiro", "KiroToggle", "KiroAsk", "KiroSelection", "KiroCancel", "KiroRestart" },
  opts = {},
  specs = {
    {
      "AstroNvim/astrocore",
      opts = {
        mappings = {
          n = {
            ["<Leader>k"] = { desc = "Kiro" },
            ["<Leader>kk"] = { "<Cmd>KiroToggle<CR>", desc = "Toggle panel" },
            ["<Leader>ka"] = { ":KiroAsk ", desc = "Ask" },
            ["<Leader>kc"] = { "<Cmd>KiroCancel<CR>", desc = "Cancel" },
          },
          x = {
            ["<Leader>ks"] = { ":KiroSelection<CR>", desc = "Send selection" },
          },
        },
      },
    },
  },
}
```

Alternatively set `opts = { keymaps = true }` to let the plugin define the same default mappings itself.

## Configuration

Defaults (all optional):

```lua
require("kiro").setup({
  cmd = { "kiro-cli", "acp" }, -- agent command; add flags like "--agent", "name" here
  cwd = nil,                   -- string | function; default: current working directory
  env = nil,                   -- extra environment for the agent process
  session_id = nil,            -- resume an existing session (uses ACP session/load)
  log = false,                 -- write protocol traffic to stdpath("state")/kiro.log
  checktime = true,            -- run :checktime after tool calls / turns so buffers reload files Kiro edited
  notify = true,               -- vim.notify when a turn finishes or fails while the panel is hidden
  ui = {
    width = 0.6,               -- floating window size; <= 1: fraction of the editor, > 1: columns
    height = 0.8,              -- <= 1: fraction of the editor, > 1: lines (transcript + prompt, borders included)
    prompt_height = 6,         -- text lines in the prompt float
    border = "rounded",        -- any border style accepted by nvim_open_win, or "none"
  },
  keymaps = false,             -- true for defaults, or a table such as { toggle = "<leader>kk", cancel = false }
})
```

Default keymaps (when `keymaps = true`): `<leader>kk` toggle, `<leader>ka` ask, `<leader>ks` send selection
(visual mode), `<leader>kc` cancel. A `false` value in a `keymaps` table disables that one mapping.

## Usage

| Command                          | Description                                                                      |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `:Kiro [session-id]`             | Open the panel and focus the prompt; with a session id, resume that session (`session/load`) |
| `:KiroToggle`                    | Hide or show the panel (the session keeps running while hidden)                  |
| `:KiroAsk[!] {text}`             | Send a prompt now; `!` attaches the current file as a resource link              |
| `:'<,'>KiroSelection [text]`     | With text: send it with the fenced selection. Without: stage the selection in the prompt buffer so you can edit it |
| `:KiroCancel`                    | Cancel the running turn                                                          |
| `:KiroRestart [session-id]`      | Stop the agent and start fresh on the next prompt; with a session id, resume that session instead |

In the panel: `<C-s>` (insert or normal mode) or `<CR>` (normal mode) sends the prompt; in the transcript, `q`
hides the panel, `i` jumps to the prompt, and `<C-c>` (either buffer, normal mode) cancels.

The panel is a pair of centered floating windows (transcript above, prompt below). Hiding it (`q`, `:KiroToggle`,
or closing a float) only closes the windows: the Kiro session keeps running, a turn in progress continues, and
the transcript and any unsent prompt text are restored when you show it again with `:Kiro` or `:KiroToggle`.

When Kiro asks for permission to run a tool, a `vim.ui.select` menu shows the options the agent offers.
Dismissing it, or cancelling the turn, answers "cancelled".

`:checkhealth kiro` verifies the Neovim version and that the agent command is available.

## Scope (v1)

Chat with streamed responses, tool call and plan display, permission prompts, file/selection context.
The client advertises no `fs` or `terminal` capabilities, so Kiro reads and edits files through its own tools,
not through your buffers. With `checktime = true` (default) the plugin runs `:checktime` after tool calls and
turns, so unmodified buffers (with `autoread` set) pick up Kiro's edits. Planned: attaching to existing sessions from a picker (`session/list`), buffer-aware
file operations and diff review.

Session resume is already wired at the API level: `session_id` loads that session and replays its history into
the transcript.

## Development

```sh
make test   # runs the mini.test suite (fetches mini.test into .deps/ on first run)
nvim --headless -u tests/child_init.lua -l scripts/smoke.lua "your prompt"   # smoke test against real kiro-cli
```

The tests run against `tests/fake_agent.lua`, a scripted ACP agent, so Kiro is not needed.
