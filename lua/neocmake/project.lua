local M = {}
local uv, fs = vim.uv, vim.fs
local projects = {}

function M.path(base, path)
  return fs.normalize(
    vim.fn.isabsolutepath(path) == 1 and path or (base .. "/" .. path),
    { expand_env = false }
  )
end

function M.json(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

function M.has_presets(root)
  return uv.fs_stat(root .. "/CMakePresets.json") or uv.fs_stat(root .. "/CMakeUserPresets.json")
end

local function find_root(start)
  local top
  local dir = start
  while dir do
    if M.has_presets(dir) then
      return dir
    end
    if uv.fs_stat(dir .. "/CMakeLists.txt") then
      top = dir
    end
    if uv.fs_stat(dir .. "/.git") then
      break
    end
    local parent = fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return top
end

local function from_root(root)
  root = fs.normalize(uv.fs_realpath(root) or root, { expand_env = false })
  if not projects[root] then
    local state = M.path(vim.fn.stdpath("state"), "neocmake/" .. vim.fn.sha256(root) .. ".json")
    local ok, saved = pcall(M.json, state)
    projects[root] = {
      root = root,
      state = state,
      saved = ok and saved or {},
      log = {},
      ns = vim.api.nvim_create_namespace("neocmake/" .. root),
    }
  end
  return projects[root]
end

function M.for_buffer(buf)
  local root = vim.b[buf].neocmake_root
  if not root and vim.bo[buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" then
      root = find_root(fs.dirname(fs.normalize(name, { expand_env = false })))
    end
  end
  return root and from_root(root)
end

function M.current()
  return M.for_buffer(0)
    or from_root(assert(find_root(vim.fn.getcwd()), "Open a file inside a CMake project"))
end

function M.save(p)
  vim.fn.mkdir(fs.dirname(p.state), "p")
  local tmp = p.state .. "." .. uv.os_getpid()
  assert(vim.fn.writefile({ vim.json.encode(p.saved) }, tmp) == 0, "Cannot save CMake selections")
  assert(uv.fs_rename(tmp, p.state))
end

function M.query(dir)
  local query = dir .. "/.cmake/api/v1/query/client-neocmake/codemodel-v2"
  if uv.fs_stat(query) then
    return false
  end
  vim.fn.mkdir(fs.dirname(query), "p")
  assert(vim.fn.writefile({}, query) == 0, "Cannot write CMake File API query")
  return true
end

-- Some projects publish a restricted list of build types in the cache for
-- cmake-gui. Otherwise use CMake's standard types plus the current value.
function M.build_types(dir, current)
  local names = { "Debug", "Release", "RelWithDebInfo", "MinSizeRel", "" }
  for _, line in ipairs(vim.fn.readfile(dir .. "/CMakeCache.txt")) do
    local values = line:match("^CMAKE_BUILD_TYPE%-STRINGS:INTERNAL=(.+)$")
    if values then
      names = vim.split(values, ";", { plain = true, trimempty = true })
      break
    end
  end
  if not vim.tbl_contains(names, current) then
    table.insert(names, current)
  end
  return vim.tbl_map(function(name)
    return { name = name, label = name == "" and "(No build type)" or name }
  end, names)
end

function M.codemodel(dir, previous)
  local reply = dir .. "/.cmake/api/v1/reply/"
  local indices = {}
  for name in fs.dir(reply) do
    if name:match("^index%-.*%.json$") then
      table.insert(indices, name)
    end
  end
  table.sort(indices)
  assert(#indices > 0, "CMake File API reply missing. Configure again.")
  local path = reply .. indices[#indices]
  if previous and previous.index == path then
    return previous
  end
  local index = M.json(path)
  local response = index.reply["client-neocmake"]
  assert(response and response["codemodel-v2"], "CMake codemodel missing. Configure again.")
  local model = M.json(reply .. response["codemodel-v2"].jsonFile)
  model.index, model.generator = path, index.cmake.generator
  return model
end

function M.model(dir, previous)
  local model = M.codemodel(dir, previous)
  if model == previous then
    return previous
  end
  local reply = fs.dirname(model.index) .. "/"
  local configs = {}
  for _, cfg in ipairs(model.configurations) do
    local targets = {}
    for _, ref in ipairs(cfg.targets) do
      local t = M.json(reply .. ref.jsonFile)
      if not t.isGeneratorProvided then
        local target = { name = t.name, type = t.type }
        if t.type == "EXECUTABLE" then
          for _, artifact in ipairs(t.artifacts or {}) do
            if fs.basename(artifact.path) == t.nameOnDisk then
              target.path = M.path(dir, artifact.path)
              break
            end
          end
        end
        targets[t.name] = target
      end
    end
    table.insert(configs, { name = cfg.name, targets = targets })
  end
  return { configurations = configs, generator = model.generator, index = model.index }
end

return M
