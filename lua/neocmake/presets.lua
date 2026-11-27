-- CMake evaluates conditions and executes configure/build presets. Read the
-- metadata needed for the selectors and for processes without a --preset flag.
local project = require("neocmake.project")
local M = {}

local function expand(text, context, env, parent)
  return (
    text:gsub("%$(%a*){([^}]+)}", function(namespace, key)
      if namespace == "penv" then
        return parent(key)
      end
      if namespace == "env" then
        return env(key)
      end
      if namespace == "" then
        return context[key]
      end
    end)
  )
end

function M.metadata(root, developer_env)
  local function parent(key)
    return (developer_env and developer_env[key:upper()]) or vim.env[key] or ""
  end
  local builds, configs, visited = {}, {}, {}
  local context = {
    sourceDir = root,
    sourceParentDir = vim.fs.dirname(root),
    sourceDirName = vim.fs.basename(root),
    hostSystemName = vim.uv.os_uname().sysname,
    pathListSep = vim.fn.has("win32") == 1 and ";" or ":",
    dollar = "$",
  }
  if context.hostSystemName == "Windows_NT" then
    context.hostSystemName = "Windows"
  end
  local function read(file)
    if visited[file] then
      return
    end
    visited[file] = true
    local doc = project.json(file)
    for _, inc in ipairs(doc.include or {}) do
      context.fileDir = vim.fs.dirname(file)
      local path = expand(inc, context, parent, parent)
      read(project.path(vim.fs.dirname(file), path))
    end
    for _, preset in ipairs(doc.buildPresets or {}) do
      builds[preset.name] = preset
    end
    for _, preset in ipairs(doc.configurePresets or {}) do
      configs[preset.name] = { preset = preset, file = file, version = doc.version }
    end
  end
  for _, name in ipairs({ "CMakePresets.json", "CMakeUserPresets.json" }) do
    local file = project.path(root, name)
    if vim.uv.fs_stat(file) then
      read(file)
    end
  end

  local function parents(preset)
    local names = preset.inherits or {}
    return type(names) == "string" and { names } or names
  end

  local function field(name, key)
    local p = builds[name]
    if not p then
      return
    end
    if p[key] ~= nil then
      return p[key]
    end
    for _, parent in ipairs(parents(p)) do
      local value = field(parent, key)
      if value ~= nil then
        return value
      end
    end
  end

  local function build_info(name)
    return field(name, "configurePreset"), field(name, "configuration")
  end

  local function environment(name, generator)
    local definitions, seen = {}, {}
    local function inherit(id)
      if seen[id] then
        return
      end
      seen[id] = true
      local entry = configs[id]
      assert(entry, "Unknown configure preset " .. id)
      for k, value in pairs(entry.preset.environment or {}) do
        if not definitions[k] then
          definitions[k] = { value = value, origin = entry }
        end
      end
      for _, parent in ipairs(parents(entry.preset)) do
        inherit(parent)
      end
    end
    inherit(name)
    local resolved, visiting = vim.empty_dict(), {}
    local function resolve(k)
      local def = definitions[k]
      if not def or def.value == vim.NIL then
        return parent(k)
      end
      if resolved[k] then
        return resolved[k]
      end
      assert(not visiting[k], "Cycle in preset environment at " .. k)
      visiting[k] = true
      local file = def.origin.version >= 12 and def.origin.file or configs[name].file
      local scope = vim.tbl_extend("force", context, {
        presetName = name,
        generator = generator,
        fileDir = vim.fs.dirname(file),
      })
      resolved[k] = expand(def.value, scope, resolve, parent)
      visiting[k] = nil
      return resolved[k]
    end
    for k in pairs(definitions) do
      resolve(k)
    end
    return resolved
  end

  return { build = build_info, environment = environment }
end

function M.list(lines)
  local list = {}
  for _, line in ipairs(lines) do
    local name, label = line:match('^%s+"([^"]+)"%s*%-?%s*(.-)%s*$')
    if name then
      table.insert(list, { name = name, label = label == "" and name or (label .. "  [" .. name .. "]") })
    end
  end
  return list
end

return M
