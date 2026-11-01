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

--- Wait inside the child until the Lua expression is truthy.
local function wait_for(expr)
  local ok = child.lua_get(("vim.wait(8000, function() return %s end, 10)"):format(expr))
  eq(ok, true)
end

local function transcript_text()
  return child.lua_get("table.concat(vim.api.nvim_buf_get_lines(require('kiro').panel().tbuf, 0, -1, false), '\\n')")
end

T["panel"] = MiniTest.new_set()

T["panel"]["open creates floating transcript and prompt windows"] = function()
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 1)
  child.cmd("Kiro")
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 3)
  local info = child.lua_get([[(function()
    local p = require('kiro').panel()
    local tc, pc = vim.api.nvim_win_get_config(p.twin), vim.api.nvim_win_get_config(p.pwin)
    return {
      tft = vim.bo[p.tbuf].filetype, tbt = vim.bo[p.tbuf].buftype, tmod = vim.bo[p.tbuf].modifiable,
      pmod = vim.bo[p.pbuf].modifiable, focus_is_prompt = vim.api.nvim_get_current_win() == p.pwin,
      floats = tc.relative == "editor" and pc.relative == "editor",
      prompt_below = vim.api.nvim_win_get_position(p.pwin)[1] > vim.api.nvim_win_get_position(p.twin)[1],
      inside = tc.col >= 0 and pc.row + pc.height + 2 <= vim.o.lines,
      winbar = vim.wo[p.twin].winbar,
    }
  end)()]])
  eq(info.tft, "markdown")
  eq(info.tbt, "nofile")
  eq(info.tmod, false)
  eq(info.pmod, true)
  eq(info.focus_is_prompt, true)
  eq(info.floats, true)
  eq(info.prompt_below, true)
  eq(info.inside, true)
  eq(info.winbar:find("disconnected", 1, true) ~= nil, true)
end

T["panel"]["hiding keeps the session, transcript and unsent prompt; reopening restores them"] = function()
  child.cmd("KiroAsk first")
  wait_for("not require('kiro').session().busy and #require('kiro').session().transcript > 1")
  local sid = child.lua_get("require('kiro').session().session_id")
  child.lua("require('kiro').panel():set_prompt('draft text')")
  child.cmd("KiroToggle") -- hide
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 1)
  eq(child.lua_get("require('kiro').session().state"), "ready")
  child.cmd("KiroToggle") -- unhide
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 3)
  eq(child.lua_get("require('kiro').session().session_id"), sid)
  eq(child.lua_get("require('kiro').panel():get_prompt()"), "draft text")
  eq(transcript_text():find("Echo: first", 1, true) ~= nil, true)
end

T["panel"]["a turn keeps running while hidden and shows up on unhide"] = function()
  child.cmd("KiroAsk slow")
  wait_for("require('kiro').session().state == 'prompting'")
  child.cmd("KiroToggle")
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 1)
  eq(child.lua_get("require('kiro').session().state"), "prompting")
  child.cmd("KiroCancel")
  wait_for("not require('kiro').session().busy")
  child.cmd("KiroToggle")
  eq(transcript_text():find("## You\nslow", 1, true) ~= nil, true)
end

T["panel"]["floats are repositioned when the editor is resized"] = function()
  child.cmd("Kiro")
  local before = child.lua_get("vim.api.nvim_win_get_config(require('kiro').panel().twin).width")
  child.o.columns = 40
  child.cmd("doautocmd VimResized")
  local after = child.lua_get("vim.api.nvim_win_get_config(require('kiro').panel().twin).width")
  eq(after < before, true)
end

T["panel"]["opening twice does not duplicate windows; toggle closes"] = function()
  child.cmd("Kiro")
  child.cmd("Kiro")
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 3)
  child.cmd("KiroToggle")
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 1)
  child.cmd("KiroToggle")
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 3)
end

T["panel"]["sending from the prompt buffer streams a reply and clears the prompt"] = function()
  child.cmd("Kiro")
  child.lua("require('kiro').panel():set_prompt('hello\\nworld')")
  child.type_keys("<C-s>")
  wait_for("require('kiro').session().state == 'ready' and not require('kiro').session().busy")
  local text = transcript_text()
  eq(text:find("## You\nhello\nworld", 1, true) ~= nil, true)
  eq(text:find("## Kiro", 1, true) ~= nil, true)
  eq(text:find("Echo: hello\nworld", 1, true) ~= nil, true)
  eq(text:find("- tool: Reading file (completed)", 1, true) ~= nil, true)
  eq(text:find("- [x] Think", 1, true) ~= nil, true)
  eq(child.lua_get("require('kiro').panel():get_prompt()"), "")
  -- only one "## Kiro" heading per agent turn
  local _, count = text:gsub("## Kiro", "")
  eq(count, 1)
end

T["panel"]["empty prompt is not sent"] = function()
  child.cmd("Kiro")
  child.type_keys("<C-s>")
  eq(child.lua_get("#require('kiro').session().transcript"), 0)
end

T["panel"]["<CR> in normal mode sends"] = function()
  child.cmd("Kiro")
  child.lua("require('kiro').panel():set_prompt('via enter')")
  child.type_keys("<Esc>", "<CR>")
  wait_for("not require('kiro').session().busy and #require('kiro').session().transcript > 1")
  eq(transcript_text():find("Echo: via enter", 1, true) ~= nil, true)
end

T["panel"]["closing one panel window closes the other"] = function()
  child.cmd("Kiro")
  child.lua("vim.api.nvim_win_close(require('kiro').panel().twin, true)")
  wait_for("#vim.api.nvim_list_wins() == 1")
end

T["panel"]["q in the transcript closes the panel"] = function()
  child.cmd("Kiro")
  child.lua("vim.api.nvim_set_current_win(require('kiro').panel().twin)")
  child.type_keys("q")
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 1)
end

T["panel"]["errors are shown in the transcript"] = function()
  child.lua("require('kiro').setup({ cmd = { 'definitely-not-a-real-binary-xyz' } })")
  child.cmd("KiroAsk hi")
  wait_for("not require('kiro').session().busy")
  eq(transcript_text():find("**Error:** failed to start", 1, true) ~= nil, true)
end

T["format"] = MiniTest.new_set()

T["format"]["renders every entry kind"] = function()
  local Panel = require("kiro.ui.panel")
  local out = Panel.format({
    { kind = "user", text = "q" },
    { kind = "thought", text = "hmm" },
    { kind = "agent", text = "a\nb" },
    { kind = "error", text = "bad\nmore" },
    { kind = "info", text = "note" },
  })
  eq(out, { "## You", "q", "", "## Kiro", "> hmm", "", "a", "b", "", "> **Error:** bad", "> more", "", "> note", "" })
end

T["notify"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Record vim.notify calls inside the child.
      child.lua([[_G.notes = {}
        vim.notify = function(msg, level) table.insert(_G.notes, { msg = msg, level = level }) end]])
    end,
  },
})

local function notes()
  return child.lua_get("_G.notes")
end

T["notify"]["finished turn while hidden notifies"] = function()
  child.cmd("KiroAsk hello")
  child.cmd("KiroToggle") -- hide while the turn runs
  wait_for("not require('kiro').session().busy")
  wait_for("#_G.notes > 0")
  local n = notes()
  eq(#n, 1)
  eq(n[1].msg:find("finished responding", 1, true) ~= nil, true)
  eq(n[1].level, vim.log.levels.INFO)
end

T["notify"]["no notification while the panel is visible"] = function()
  child.cmd("KiroAsk hello")
  wait_for("not require('kiro').session().busy and #require('kiro').session().transcript > 1")
  child.lua_get("vim.wait(100, function() return false end)")
  eq(#notes(), 0)
end

T["notify"]["cancelled turn does not notify"] = function()
  child.cmd("KiroAsk slow")
  wait_for("require('kiro').session().state == 'prompting'")
  child.cmd("KiroToggle")
  child.cmd("KiroCancel")
  wait_for("not require('kiro').session().busy")
  child.lua_get("vim.wait(100, function() return false end)")
  eq(#notes(), 0)
end

T["notify"]["notify = false silences it"] = function()
  child.lua("require('kiro').setup({ cmd = ..., notify = false })", { H.fake_cmd() })
  child.cmd("KiroAsk hello")
  child.cmd("KiroToggle")
  wait_for("not require('kiro').session().busy")
  child.lua_get("vim.wait(100, function() return false end)")
  eq(#notes(), 0)
end

T["notify"]["agent crash while hidden notifies with an error"] = function()
  child.cmd("KiroAsk die")
  child.cmd("KiroToggle")
  wait_for("#_G.notes > 0")
  local n = notes()
  eq(n[#n].level, vim.log.levels.ERROR)
end

return T
