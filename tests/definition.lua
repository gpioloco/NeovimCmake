-- Run inside the configured editor or in a fresh process with the saved build.
local root, dir = ...
if not root then
  root, dir = arg[2], arg[3]
  vim.opt.rtp:prepend(arg[1])
  require("neocmake").setup()
  vim.lsp.config(
    "clangd",
    { cmd = { "clangd", "--background-index" }, filetypes = { "cpp" }, root_dir = root }
  )
  vim.lsp.enable("clangd")
end
vim.cmd.edit(vim.fn.fnameescape(root .. "/src/extended.cpp"))
if vim.bo.filetype == "" then
  vim.bo.filetype = "cpp"
end
local buf = vim.api.nvim_get_current_buf()
local db = dir .. "/compile_commands.json"
local original = vim.fn.readblob(db)
local def = root .. "/src/base.cpp"

local client
assert(
  vim.wait(10000, function()
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "clangd" })) do
      if c.initialized and (c.config.init_options or {}).compilationDatabasePath == dir then
        client = c
        return true
      end
    end
  end),
  "clangd did not restore the nested build database"
)

-- The call needs CMake's include directory. Finding its out-of-line definition
-- also requires clangd to index base.cpp, which the fresh session has never opened.
assert(vim.fn.search("base_value", "w") > 0)
local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
assert(
  vim.wait(12000, function()
    local reply = client:request_sync("textDocument/definition", params, 2000, buf)
    for _, loc in ipairs(reply and reply.result or {}) do
      if vim.fs.normalize(vim.uri_to_fname(loc.uri)) == def then
        return true
      end
    end
  end, 100),
  "clangd did not resolve the call to src/base.cpp"
)
if next(vim.fn.maparg("gd", "n", false, true)) then
  vim.api.nvim_feedkeys("gd", "mx", false)
else
  vim.lsp.buf.definition()
end
assert(
  vim.wait(3000, function()
    return vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == def
  end),
  "Go to definition did not open src/base.cpp"
)
assert(not vim.uv.fs_lstat(root .. "/compile_commands.json"))
assert(vim.fn.readblob(db) == original)
