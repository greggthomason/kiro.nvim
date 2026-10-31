-- Manual smoke test against the real agent:
--   nvim --headless -u tests/child_init.lua -l scripts/smoke.lua ["prompt"]
-- Sends one prompt through kiro.nvim's session layer and prints the transcript.
require("kiro").setup({ log = true })
local session = require("kiro").session()
local text = arg and arg[1] or "Reply with exactly the word: pong"

session:prompt({ { type = "text", text = text } }, text)
local ok = vim.wait(90000, function()
  return not session.busy
end, 50)

for _, e in ipairs(session.transcript) do
  io.stdout:write(("[%s] %s\n"):format(e.kind, e.text or e.title or ""))
end
io.stdout:write(("state=%s session_id=%s finished=%s\n"):format(session.state, tostring(session.session_id), tostring(ok)))
session:close()
vim.wait(300)
os.exit(ok and 0 or 1)
