local context = require("kiro.context")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() vim.cmd("silent! %bwipeout!") end,
  },
})

local function setup_buf(lines, name, ft)
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  if name then vim.api.nvim_buf_set_name(0, name) end
  if ft then vim.bo.filetype = ft end
end

T["linewise selection from a range"] = function()
  setup_buf({ "one", "two", "three", "four" }, "/tmp/kiro_ctx_a.lua", "lua")
  local sel = context.get_selection(2, 3)
  eq(sel.text, "two\nthree")
  eq(sel.line1, 2)
  eq(sel.line2, 3)
  eq(vim.endswith(sel.path, "/kiro_ctx_a.lua"), true)
  eq(sel.filetype, "lua")
end

T["reversed and out-of-range ranges are normalised"] = function()
  setup_buf({ "a", "b" }, "/tmp/kiro_ctx_b.txt")
  eq(context.get_selection(2, 1).text, "a\nb")
  eq(context.get_selection(1, 99).line2, 2)
  eq(context.get_selection(5, 6), nil)
end

T["empty or whitespace selection is nil"] = function()
  setup_buf({ "", "   ", "x" }, "/tmp/kiro_ctx_c.txt")
  eq(context.get_selection(1, 2), nil)
end

T["charwise visual selection uses the exact region"] = function()
  setup_buf({ "hello world" }, "/tmp/kiro_ctx_d.txt")
  vim.cmd("normal! 0wve\27")
  local sel = context.get_selection(1, 1)
  eq(sel.text, "world")
end

T["unnamed buffer has no path"] = function()
  setup_buf({ "x = 1" })
  local sel = context.get_selection(1, 1)
  eq(sel.path, nil)
  eq(context.format_selection(sel):find("[No Name]", 1, true) ~= nil, true)
  eq(context.current_file(), nil)
end

-- @file mentions ---------------------------------------------------------------

local function make_tree()
  local root = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h"))
  root = root .. "/kiro_mentions_" .. vim.uv.hrtime()
  vim.fn.mkdir(root .. "/src/sub", "p")
  vim.fn.writefile({ "a" }, root .. "/README.md")
  vim.fn.writefile({ "b" }, root .. "/src/main.lua")
  vim.fn.writefile({ "c" }, root .. "/src/other.lua")
  vim.fn.writefile({ "h" }, root .. "/.hidden")
  return root
end

T["extract_mentions resolves existing files only"] = function()
  local root = make_tree()
  local got = context.extract_mentions("see @README.md and @src/main.lua, plus @nope.txt and @src/sub", root)
  eq(got, { root .. "/README.md", root .. "/src/main.lua" })
  vim.fn.delete(root, "rf")
end

T["extract_mentions ignores emails, strips punctuation, de-duplicates"] = function()
  local root = make_tree()
  local got = context.extract_mentions("mail a@README.md? no. Check (@README.md). @README.md again\n@src/other.lua!", root)
  eq(got, { root .. "/README.md", root .. "/src/other.lua" })
  vim.fn.delete(root, "rf")
end

T["complete_paths lists files and dirs, hides dotfiles, descends into dirs"] = function()
  local root = make_tree()
  eq(context.complete_paths("", root), { "README.md", "src/" })
  eq(context.complete_paths("s", root), { "src/" })
  eq(context.complete_paths("src/", root), { "src/main.lua", "src/other.lua", "src/sub/" })
  eq(context.complete_paths("src/m", root), { "src/main.lua" })
  eq(context.complete_paths(".", root), { ".hidden" })
  eq(context.complete_paths("missing/", root), {})
  vim.fn.delete(root, "rf")
end

T["complete_paths offers open buffers first"] = function()
  local root = make_tree()
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/src/other.lua"))
  eq(context.complete_paths("", root), { "src/other.lua", "README.md", "src/" })
  vim.fn.delete(root, "rf")
end

T["build_prompt links @mentions once when cwd is given"] = function()
  local root = make_tree()
  local blocks = context.build_prompt("look at @README.md @README.md", { cwd = root })
  eq(#blocks, 2)
  eq(blocks[2].uri, vim.uri_from_fname(root .. "/README.md"))
  -- an explicitly attached file is not linked twice
  blocks = context.build_prompt("look at @README.md", { cwd = root, file = root .. "/README.md" })
  eq(#blocks, 2)
  -- without cwd, mentions are left as plain text
  eq(#context.build_prompt("look at @README.md"), 1)
  vim.fn.delete(root, "rf")
end

T["format_selection includes path, range and a safe fence"] = function()
  local out = context.format_selection({
    text = "print('```')", path = "/a/b.lua", line1 = 3, line2 = 5, filetype = "lua",
  })
  eq(out, "/a/b.lua (lines 3-5):\n````lua\nprint('```')\n````")
  local single = context.format_selection({ text = "x", path = "/a/b.lua", line1 = 7, line2 = 7, filetype = "" })
  eq(single:find("(line 7)", 1, true) ~= nil, true)
end

T["file_link has an absolute file URI"] = function()
  local link = context.file_link("/tmp/some file.lua")
  eq(link.type, "resource_link")
  eq(link.uri, "file:///tmp/some%20file.lua")
  eq(link.name, "some file.lua")
  local rel = context.file_link("README.md")
  eq(vim.startswith(rel.uri, "file:///"), true)
end

T["build_prompt adds a link only when a file is given"] = function()
  eq(context.build_prompt("hi"), { { type = "text", text = "hi" } })
  local blocks = context.build_prompt("hi", { file = "/tmp/x.lua" })
  eq(#blocks, 2)
  eq(blocks[2].type, "resource_link")
end

T["special buffers are not files"] = function()
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_name(0, "/tmp/kiro_special")
  eq(context.current_file(), nil)
end

return T
