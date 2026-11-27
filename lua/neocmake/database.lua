local project = require("neocmake.project")
local vs = require("neocmake.visual_studio")
local task = require("neocmake.task")
local uv = vim.uv
local M = {}

local filename = "compile_commands.json"

local function saved_path(p, dir)
  return vim.fs.relpath(p.root, dir) or dir
end

local function remember(p, dir)
  local path = saved_path(p, dir)
  local history = p.saved.database_history or {}
  if not vim.tbl_contains(history, path) then
    table.insert(history, path)
    p.saved.database_history = history
  end
end

local function directory(p, override)
  return override and project.path(p.root, override) or p.saved.dir
end

function M.choose(p, options, path)
  if path == "" then
    local items = { { name = "auto", label = "Follow active CMake build" } }
    for _, value in ipairs(p.saved.database_history or {}) do
      local dir = project.path(p.root, value)
      if vim.fn.filereadable(vim.fs.joinpath(dir, filename)) == 1 then
        table.insert(items, { name = dir, label = value })
      end
    end
    table.insert(items, { name = "browse", label = "Enter file or directory…" })
    local current = p.saved.database_override and directory(p, p.saved.database_override) or "auto"
    local item = task.choose(p, options, items, "Configure · Clangd database", current)
    if item.name == "auto" then
      return nil
    end
    path = item.name == "browse" and task.input_path(p) or item.name
  end
  -- Windows Explorer's “Copy as path” includes quotes around the filename.
  path = path:match('^"(.*)"$') or path
  local dir = project.path(p.root, vim.fs.normalize(path, { expand_env = false }))
  local stat = assert(uv.fs_stat(dir), "Path does not exist: " .. dir)
  if stat.type ~= "directory" then
    local name = vim.fs.basename(dir)
    assert(
      stat.type == "file" and (name == filename or (vim.fn.has("win32") == 1 and name:lower() == filename)),
      "Select compile_commands.json or its directory"
    )
    dir = vim.fs.dirname(dir)
  end
  local file = vim.fs.joinpath(dir, filename)
  assert(vim.fn.filereadable(file) == 1, "Cannot read " .. file)
  return saved_path(p, dir)
end

-- Ninja Multi-Config emits several commands for each file. clangd takes a
-- single command, so use the entries for the selected configuration.
local function selected_commands(data, config)
  local rows = vim.json.decode(data)
  local result = {}
  for _, row in ipairs(rows) do
    local flags = row.command or table.concat(row.arguments or {}, " ")
    local variant = flags:gsub('\\?"', ""):match("[-/]DCMAKE_INTDIR=([^%s]+)")
    if not variant or variant == config then
      table.insert(result, row)
    end
  end
  return vim.json.encode(result) .. "\n"
end

local function move_buffers(p, client, replacement)
  if client.id == replacement.id or client:is_stopped() then
    return
  end
  local moved = false
  for _, buf in ipairs(vim.tbl_keys(client.attached_buffers)) do
    if project.for_buffer(buf) == p and vim.lsp.buf_attach_client(buf, replacement.id) then
      vim.lsp.buf_detach_client(buf, client.id)
      moved = true
    end
  end
  if moved and not next(client.attached_buffers) then
    client:stop()
  end
end

local function start_clangd(p, template)
  local config = vim.deepcopy(template.config)
  local previous = config._neocmake_visual_studio
  if previous then
    config.cmd_env = previous.original
    config._neocmake_visual_studio = nil
  end
  if p.clangd_env then
    config._neocmake_visual_studio = { original = config.cmd_env, active = p.clangd_env }
    config.cmd_env = vs.merge(p.clangd_env, config.cmd_env)
  end
  config.root_dir = p.root
  config.workspace_folders = { { name = p.root, uri = vim.uri_from_fname(p.root) } }
  config.init_options = config.init_options or vim.empty_dict()
  if not config._neocmake_database then
    config._neocmake_database = { original = config.init_options.compilationDatabasePath }
  end
  config.init_options.compilationDatabasePath = p.database_dir or config._neocmake_database.original

  -- Attach each buffer after initialization so didOpen precedes requests from
  -- its attach callbacks. The old client can serve navigation in the meantime.
  local original_init = config.on_init
  config.on_init = type(original_init) == "table" and vim.list_slice(original_init) or { original_init }
  table.insert(config.on_init, function(replacement)
    replacement.config.on_init = original_init
    if replacement.id ~= p.clangd_id then
      return replacement:stop()
    end
    for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
      move_buffers(p, client, replacement)
    end
  end)
  p.clangd_id = vim.lsp.start(config, {
    attach = false,
    reuse_client = function()
      return false
    end,
  })
end

local function reload_clangd(p, stale_client)
  if stale_client then
    local active = p.clangd_id and vim.lsp.get_client_by_id(p.clangd_id)
    if active and active ~= stale_client and not active:is_stopped() then
      if active.initialized then
        move_buffers(p, stale_client, active)
      end
    else
      start_clangd(p, stale_client)
    end
    return
  end
  p.clangd_id = nil
  for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
    for buf in pairs(client.attached_buffers) do
      if project.for_buffer(buf) == p then
        return start_clangd(p, client)
      end
    end
  end
end

-- LspAttach fires before Neovim finishes attaching the buffer to the client.
function M.on_attach(buf, client, restore)
  vim.schedule(function()
    if not client.attached_buffers[buf] or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local p = project.for_buffer(buf)
    if not p then
      return
    end
    local dir = directory(p, p.saved.database_override)
    if
      not p.model
      and not p.database_dir
      and not p.task
      and dir
      and (
        uv.fs_stat(vim.fs.joinpath(dir, filename)) or (p.saved.database_override and not p.database_warning)
      )
    then
      restore(p)
      return
    end
    local environment = client.config._neocmake_visual_studio
    local configured = (client.config.init_options or {}).compilationDatabasePath
    if
      (p.database_dir and configured ~= p.database_dir)
      or (
        (p.model or p.database_dir) and not vim.deep_equal(environment and environment.active, p.clangd_env)
      )
    then
      reload_clangd(p, client)
    end
  end)
end

local function write_atomic(dst, data)
  local fd, tmp = uv.fs_mkstemp(dst .. ".XXXXXX")
  assert(fd, tmp)
  local size, err = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if size ~= #data then
    uv.fs_unlink(tmp)
    error(err or "Incomplete compilation database write")
  end
  local ok, rename_error = uv.fs_rename(tmp, dst)
  if not ok then
    uv.fs_unlink(tmp)
    error(rename_error)
  end
end

function M.update(p, override, multi_config)
  local environment = p.vs_env and p.env
  local env_changed = not vim.deep_equal(p.clangd_env, environment)
  p.clangd_env = environment
  local dir = directory(p, override)
  local src = dir and vim.fs.joinpath(dir, filename)
  local stat = src and uv.fs_stat(src)
  if override then
    multi_config = nil
    if p.saved.dir and vim.fn.filereadable(vim.fs.joinpath(p.saved.dir, filename)) == 1 then
      remember(p, p.saved.dir)
    end
  end
  if not stat or stat.type ~= "file" then
    if p.database_dir or env_changed then
      p.database_dir, p.database_signature = nil, nil
      reload_clangd(p)
    end
    if override then
      return "Selected database is unavailable at "
        .. src
        .. ". Use :CMakeConfigureDatabase to choose another."
    end
    if dir then
      return "CMake produced no compile_commands.json. Use a Ninja or Makefiles generator for clangd."
    end
    return
  end
  remember(p, dir)

  local signature = table.concat({ src, stat.mtime.sec, stat.mtime.nsec, stat.size, multi_config or "" }, "|")
  if multi_config then
    -- Keep CMake's multi-config database intact. clangd needs one command per
    -- translation unit, so its configuration-specific view lives in the build tree.
    dir = project.path(dir, ".cmake/neocmake/" .. vim.fn.sha256(multi_config))
    local view = dir .. "/compile_commands.json"
    if signature ~= p.database_signature or not uv.fs_stat(view) then
      local data = selected_commands(vim.fn.readblob(src), multi_config)
      if not uv.fs_stat(view) or vim.fn.readblob(view) ~= data then
        vim.fn.mkdir(dir, "p")
        write_atomic(view, data)
      end
    end
  end
  if signature ~= p.database_signature or env_changed then
    p.database_dir, p.database_signature = dir, signature
    reload_clangd(p)
  end
end

return M
