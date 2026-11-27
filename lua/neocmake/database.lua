local project = require("neocmake.project")
local vs = require("neocmake.visual_studio")
local uv = vim.uv
local M = {}

-- Ninja Multi-Config emits several commands for each file. clangd takes a
-- single command, so publish the entries for the selected configuration.
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

-- clangd caches both successful lookups and missing databases. Reattach the
-- project's open files immediately when the flags change, keeping the user's
-- command, capabilities and handlers. A client shared with other roots stays
-- attached to those buffers.
local function reload_clangd(p, stale_client)
  local replacement
  local clients = stale_client and { stale_client } or vim.lsp.get_clients({ name = "clangd" })
  for _, client in ipairs(clients) do
    local moved = false
    for _, buf in ipairs(vim.tbl_keys(client.attached_buffers)) do
      local path = vim.api.nvim_buf_get_name(buf)
      if vim.fs.relpath(p.root, path) then
        if not replacement then
          local config = vim.deepcopy(client.config)
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
          config.init_options.compilationDatabasePath = p.database_dir
          replacement = vim.lsp.start(config, {
            attach = false,
            reuse_client = function()
              return false
            end,
          })
          if not replacement then
            return
          end
        end
        moved = true
        vim.lsp.buf_detach_client(buf, client.id)
        vim.lsp.buf_attach_client(buf, replacement)
      end
    end
    if moved and not next(client.attached_buffers) then
      client:stop()
    end
  end
end

-- A project may keep its own root database. Point new clangd clients at the
-- active build tree too when the root copy belongs to the user.
function M.on_attach(event)
  local client = vim.lsp.get_client_by_id(event.data.client_id)
  if not client or client.name ~= "clangd" then
    return
  end
  local p = project.for_buffer(event.buf)
  local configured = (client.config.init_options or {}).compilationDatabasePath
  if not p or not p.model then
    return
  end
  local environment = client.config._neocmake_visual_studio
  local env_changed = not vim.deep_equal(environment and environment.active, p.clangd_env)
  if
    env_changed
    or (p.database_dir and (configured or p.database_dir ~= p.root) and configured ~= p.database_dir)
  then
    vim.schedule(function()
      if client.attached_buffers[event.buf] then
        reload_clangd(p, client)
      end
    end)
  end
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

function M.publish(p, config)
  local environment = p.vs_env and p.env
  local env_changed = not vim.deep_equal(p.clangd_env, environment)
  p.clangd_env = environment
  local src = p.saved.dir .. "/compile_commands.json"
  local dst = p.root .. "/compile_commands.json"
  local stat, dest = uv.fs_stat(src), uv.fs_lstat(dst)
  if not stat then
    if dest and dest.type == "file" and p.saved.database_hash == vim.fn.sha256(vim.fn.readblob(dst)) then
      assert(uv.fs_unlink(dst))
      p.saved.database_hash = nil
    end
    if p.database_dir or env_changed then
      p.database_dir, p.database_signature = nil, nil
      reload_clangd(p)
    end
    return "CMake produced no compile_commands.json. Use a Ninja or Makefiles generator for clangd."
  end
  local signature = table.concat({
    src,
    stat.mtime.sec,
    stat.mtime.nsec,
    stat.size,
    config,
    dest and dest.mtime.sec or "",
    dest and dest.mtime.nsec or "",
  }, "|")
  if signature == p.database_signature and not env_changed then
    return p.database_warning
  end

  local raw = vim.fn.readblob(src)
  local data = p.model.generator.multiConfig and selected_commands(raw, config) or raw
  local hash = vim.fn.sha256(data)
  local same_file = uv.fs_realpath(src) == uv.fs_realpath(dst)
  local previous = dest and dest.type == "file" and vim.fn.sha256(vim.fn.readblob(dst))
  local dir, warning = p.root, nil
  if previous ~= hash and not (same_file and raw == data) then
    if not dest or (not same_file and previous and previous == p.saved.database_hash) then
      write_atomic(dst, data)
      p.saved.database_hash = hash
    else
      dir = p.saved.dir
      if raw ~= data then
        dir = project.path(dir, ".cmake/neocmake/" .. vim.fn.sha256(config))
        vim.fn.mkdir(dir, "p")
        write_atomic(dir .. "/compile_commands.json", data)
      end
      warning = "Preserved " .. dst .. ". clangd will use " .. dir
    end
  end
  if p.active_hash ~= hash or p.database_dir ~= dir or env_changed then
    p.active_hash, p.database_dir = hash, dir
    reload_clangd(p)
  end
  p.database_signature = signature
  return warning
end

return M
