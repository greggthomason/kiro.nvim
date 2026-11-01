local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/child_init.lua" })
      child.lua("require('kiro').setup({ cmd = ... })", { H.fake_cmd() })
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local function wait_for(expr)
  eq(child.lua_get(("vim.wait(8000, function() return %s end, 10)"):format(expr)), true)
end

local function transcript_text()
  return child.lua_get("table.concat(vim.api.nvim_buf_get_lines(require('kiro').panel().tbuf, 0, -1, false), '\\n')")
end

local function idle()
  wait_for("#require('kiro').session().transcript > 0 and not require('kiro').session().busy")
end

T["commands are registered"] = function()
  for _, name in ipairs({ "Kiro", "KiroToggle", "KiroAsk", "KiroSelection", "KiroCancel", "KiroRestart" }) do
    eq(child.fn.exists(":" .. name), 2)
  end
end

T["KiroAsk sends without stealing focus"] = function()
  local before = child.lua_get("vim.api.nvim_get_current_win()")
  child.cmd("KiroAsk what is this")
  idle()
  eq(child.lua_get("vim.api.nvim_get_current_win()"), before)
  eq(transcript_text():find("Echo: what is this", 1, true) ~= nil, true)
end

T["KiroAsk! attaches the current file as a resource link"] = function()
  local file = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "return 1" }, file)
  child.cmd("edit " .. vim.fn.fnameescape(file))
  child.cmd("KiroAsk! blocks")
  idle()
  local text = transcript_text()
  eq(text:find("[attached: ", 1, true) ~= nil, true)
  local blocks = child.lua_get([[(function()
    for _, e in ipairs(require('kiro').session().transcript) do
      if e.kind == 'agent' and e.text:find('^blocks:') then return vim.json.decode(e.text:sub(8)) end
    end
  end)()]])
  eq(blocks[1], { type = "text", text = "blocks" })
  eq(blocks[2].type, "resource_link")
  eq(vim.startswith(blocks[2].uri, "file:///"), true)
  eq(vim.endswith(blocks[2].uri, vim.fs.basename(file)), true)
  vim.fn.delete(file)
end

T["KiroAsk! on an unnamed buffer warns and sends text only"] = function()
  child.cmd("KiroAsk! blocks")
  idle()
  local n = child.lua_get([[(function()
    for _, e in ipairs(require('kiro').session().transcript) do
      if e.kind == 'agent' and e.text:find('^blocks:') then return #vim.json.decode(e.text:sub(8)) end
    end
  end)()]])
  eq(n, 1)
end

T["KiroCancel interrupts a long-running turn"] = function()
  child.cmd("KiroAsk slow")
  wait_for("require('kiro').session().state == 'prompting'")
  wait_for("#require('kiro').session().transcript >= 2")
  child.cmd("KiroCancel")
  wait_for("not require('kiro').session().busy")
  eq(transcript_text():find("> Cancelled", 1, true) ~= nil, true)
end

T["KiroCancel with nothing running is harmless"] = function()
  child.cmd("KiroCancel")
  eq(child.lua_get("require('kiro').session().state"), "disconnected")
end

T["KiroSelection with an instruction sends the fenced selection"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1", "local y = 2", "return x + y" })
  child.bo.filetype = "lua"
  child.cmd("2,3KiroSelection explain")
  idle()
  local text = transcript_text()
  eq(text:find("explain", 1, true) ~= nil, true)
  eq(text:find("lines 2-3", 1, true) ~= nil, true)
  eq(text:find("```lua\nlocal y = 2\nreturn x + y\n```", 1, true) ~= nil, true)
end

T["KiroSelection without an instruction stages the selection in the prompt"] = function()
  child.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta" })
  child.cmd("1,2KiroSelection")
  local prompt = child.lua_get("require('kiro').panel():get_prompt()")
  eq(prompt:find("alpha\nbeta", 1, true) ~= nil, true)
  eq(child.lua_get("vim.api.nvim_get_current_win() == require('kiro').panel().pwin"), true)
  eq(child.lua_get("#require('kiro').session().transcript"), 0)
end

T["KiroSelection with an empty selection does nothing"] = function()
  child.cmd("KiroSelection explain")
  eq(child.lua_get("require('kiro').session().state"), "disconnected")
  eq(child.lua_get("#require('kiro').session().transcript"), 0)
end

T["the winbar shows an animated spinner while thinking"] = function()
  child.cmd("Kiro")
  child.cmd("KiroAsk slow")
  wait_for("require('kiro').session().state == 'prompting'")
  local function winbar()
    return child.lua_get("vim.wo[require('kiro').panel().twin].winbar")
  end
  -- A spinner glyph is present while prompting.
  local bar = winbar()
  eq(bar:find("thinking", 1, true) ~= nil, true)
  eq(bar:find("[|/%-\\]") ~= nil, true)
  -- The frame advances on its timer.
  wait_for(([[(function()
    return vim.wo[require('kiro').panel().twin].winbar ~= %q
  end)()]]):format(bar))
  child.cmd("KiroCancel")
  wait_for("not require('kiro').session().busy")
  -- Idle winbar has no spinner glyph.
  local idle_bar = winbar()
  eq(idle_bar:find("ready", 1, true) ~= nil, true)
  eq(idle_bar:find("[|/\\]") == nil, true)
end

T["KiroRestart starts over with a fresh session"] = function()
  child.cmd("KiroAsk one")
  idle()
  child.cmd("KiroRestart")
  eq(child.lua_get("require('kiro').session().state"), "disconnected")
  child.cmd("KiroAsk two")
  wait_for("not require('kiro').session().busy and require('kiro').session().state == 'ready'")
  eq(transcript_text():find("Echo: two", 1, true) ~= nil, true)
end

T["Kiro with a session id resumes that session via session/load"] = function()
  child.cmd("Kiro resume-123")
  eq(child.lua_get("require('kiro').session().session_id"), "resume-123")
  -- The next prompt connects with session/load, so replayed history appears.
  child.cmd("KiroAsk hello")
  wait_for("not require('kiro').session().busy and require('kiro').session().state == 'ready'")
  eq(child.lua_get("require('kiro').session().session_id"), "resume-123")
  local text = transcript_text()
  eq(text:find("old answer", 1, true) ~= nil, true)
  eq(text:find("Echo: hello", 1, true) ~= nil, true)
end

T["KiroRestart with a session id resumes that session"] = function()
  child.cmd("KiroAsk one")
  idle()
  child.cmd("KiroRestart resume-456")
  eq(child.lua_get("require('kiro').session().state"), "disconnected")
  eq(child.lua_get("require('kiro').session().session_id"), "resume-456")
  child.cmd("KiroAsk two")
  wait_for("not require('kiro').session().busy and require('kiro').session().state == 'ready'")
  eq(transcript_text():find("old answer", 1, true) ~= nil, true)
end

T["open buffers are refreshed when a turn finishes (checktime)"] = function()
  local file = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "before" }, file)
  child.o.autoread = true
  child.cmd("edit " .. vim.fn.fnameescape(file))
  -- Simulate Kiro editing the file on disk (bump mtime so the change is detectable).
  vim.fn.writefile({ "after" }, file)
  local future = os.time() + 5
  vim.uv.fs_utime(file, future, future)
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { "before" })
  child.cmd("KiroAsk hi")
  idle()
  wait_for("vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'after'")
  vim.fn.delete(file)
end

T["checktime = false leaves buffers alone"] = function()
  child.lua("require('kiro').setup({ cmd = ..., checktime = false })", { H.fake_cmd() })
  local file = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "before" }, file)
  child.o.autoread = true
  child.cmd("edit " .. vim.fn.fnameescape(file))
  vim.fn.writefile({ "after" }, file)
  local future = os.time() + 5
  vim.uv.fs_utime(file, future, future)
  child.cmd("KiroAsk hi")
  idle()
  eq(child.api.nvim_buf_get_lines(0, 0, -1, false), { "before" })
  vim.fn.delete(file)
end

T["keymaps"] = MiniTest.new_set()

T["keymaps"]["are not defined by default"] = function()
  eq(child.lua_get("vim.fn.maparg('<leader>kk', 'n') == ''"), true)
end

T["keymaps"]["are defined when enabled, and individually disableable"] = function()
  child.lua("require('kiro').setup({ cmd = ..., keymaps = { cancel = false, ask = '<leader>zz' } })", { H.fake_cmd() })
  eq(child.lua_get("vim.fn.maparg('<leader>kk', 'n', false, true).desc"), "Kiro: toggle panel")
  eq(child.lua_get("vim.fn.maparg('<leader>zz', 'n', false, true).desc"), "Kiro: ask")
  eq(child.lua_get("vim.fn.maparg('<leader>ks', 'x', false, true).desc"), "Kiro: send selection")
  eq(child.lua_get("vim.fn.maparg('<leader>kc', 'n') == ''"), true)
end

T["health"] = MiniTest.new_set()

T["health"]["check runs without errors"] = function()
  child.lua("require('kiro').setup({ cmd = ... })", { { "nvim" } })
  eq(child.lua_get("pcall(require('kiro.health').check)"), true)
end

return T
