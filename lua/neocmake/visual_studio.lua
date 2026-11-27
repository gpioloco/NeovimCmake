local project = require("neocmake.project")
local task = require("neocmake.task")
local M = {}

local scripts = {
  x64 = "vcvars64.bat",
  x86 = "vcvars32.bat",
  arm64 = "vcvarsamd64_arm64.bat",
}

function M.windows()
  return vim.fn.has("win32") == 1
end

local function identity(choice)
  return choice and (choice.path:lower() .. "|" .. choice.arch) or ""
end

function M.label(choice)
  if not choice then
    return "Inherit Neovim environment"
  end
  return ("%s · %s · %s"):format(choice.label, choice.arch, choice.path)
end

local function script_dir(choice)
  return project.path(choice.path, "VC/Auxiliary/Build")
end

local function capture(p, choice)
  local dir = script_dir(choice)
  local script = scripts[choice.arch]
  assert(
    script and vim.uv.fs_stat(dir .. "/" .. script),
    "The selected Visual Studio tools are unavailable. Select another environment with :CMakeConfigureEnvironment."
  )
  -- Run the known batch filename from its installation directory. No paths or
  -- project input pass through cmd.exe's expression parser. /u makes SET emit
  -- UTF-16LE even when a toolchain or SDK lives under a non-ASCII path.
  local result = task.probe(p, {
    vim.env.ComSpec or "cmd.exe",
    "/d",
    "/u",
    "/v:off",
    "/c",
    "call .\\" .. script .. " >nul && set",
  }, { cwd = dir })
  assert(
    result.code == 0,
    ("Could not initialize %s (exit %d). Check the C++ tools and Windows SDK in Visual Studio Installer."):format(
      M.label(choice),
      result.code
    )
  )
  local env = {}
  local data = vim.iconv(result.stdout, "utf-16le", "utf-8")
  for line in data:gmatch("[^\r\n]+") do
    local k, v = line:match("^([^=]+)=(.*)$")
    if k then
      env[k:upper()] = v
    end
  end
  assert(
    env.LIB and env.LIB ~= "" and env.INCLUDE and env.INCLUDE ~= "" and env.PATH and env.PATH ~= "",
    "Visual Studio returned an incomplete developer environment. Check the C++ workload and Windows SDK."
  )
  assert(
    env.VSINSTALLDIR
      and vim.fs.normalize(env.VSINSTALLDIR, { expand_env = false }):lower() == choice.path:lower(),
    "Another Visual Studio installation is active. Start Neovim from a regular terminal and select the environment again."
  )
  assert(
    not env.VSCMD_ARG_TGT_ARCH or env.VSCMD_ARG_TGT_ARCH:lower() == choice.arch,
    "Visual Studio activated a different target architecture. Start Neovim from a regular terminal and select the environment again."
  )
  -- CMake's matching Visual Studio generator uses this hint to distinguish
  -- editions/instances of the same major version. Ninja finds cl via PATH.
  env["VS" .. choice.major .. "0COMNTOOLS"] = choice.path:gsub("/", "\\") .. "\\Common7\\Tools\\"
  -- Retain only differences from the parent. Never write the environment to disk.
  local delta = vim.empty_dict()
  for k, v in pairs(env) do
    if vim.env[k] ~= v then
      delta[k] = v
    end
  end
  return delta
end

function M.environment(p)
  if not M.windows() or not p.saved.visual_studio then
    return
  end
  if not p.vs_env then
    p.vs_env = capture(p, p.saved.visual_studio)
  end
  return p.vs_env
end

function M.merge(base, overrides)
  if not base then
    return overrides
  end
  -- vim.system merges its inherited environment by exact spelling. Preserve
  -- the parent's spelling so Windows receives only one Path/PATH entry.
  local spelling, env = {}, vim.empty_dict()
  for k in pairs(vim.fn.environ()) do
    spelling[k:upper()] = k
  end
  for _, values in ipairs({ base, overrides }) do
    for k, v in pairs(values) do
      env[spelling[k:upper()] or k:upper()] = v
    end
  end
  return env
end

local function discover(p)
  local program_files = vim.env["ProgramFiles(x86)"] or vim.env.ProgramFiles
  local exe = program_files and project.path(program_files, "Microsoft Visual Studio/Installer/vswhere.exe")
  if not exe or not vim.uv.fs_stat(exe) then
    exe = vim.fn.exepath("vswhere.exe")
  end
  if exe == "" then
    return {}, "vswhere.exe was not found. Install Visual Studio Installer or add vswhere.exe to PATH."
  end
  local result = task.probe(p, {
    exe,
    "-products",
    "*",
    "-requires",
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "-prerelease",
    "-sort",
    "-format",
    "json",
    "-utf8",
  }, { cwd = vim.fs.dirname(exe) })
  if result.code ~= 0 then
    return {}, "vswhere failed to enumerate Visual Studio installations"
  end
  local ok, instances = pcall(vim.json.decode, (result.stdout:gsub("^\239\187\191", "")))
  if not ok or not vim.islist(instances) then
    return {}, "vswhere returned an invalid installation list"
  end
  local choices = {}
  for _, instance in ipairs(instances) do
    local path = vim.fs.normalize(instance.installationPath, { expand_env = false })
    local major = instance.installationVersion:match("^%d+")
    for _, arch in ipairs({ "x64", "x86", "arm64" }) do
      local choice = {
        path = path,
        arch = arch,
        major = major,
        label = ("%s (%s)"):format(instance.displayName or "Visual Studio", instance.installationVersion),
      }
      if vim.uv.fs_stat(script_dir(choice) .. "/" .. scripts[arch]) then
        table.insert(choices, { name = identity(choice), label = M.label(choice), choice = choice })
      end
    end
  end
  return choices, "No Visual Studio C++ tools found. Install the Desktop development with C++ workload."
end

function M.select(p, options)
  assert(M.windows(), "Visual Studio developer environments are available on Windows")
  local choices, hint = discover(p)
  if #choices == 0 then
    vim.notify(hint, vim.log.levels.WARN)
  end
  table.insert(choices, 1, { name = "", label = M.label(nil) })
  local item = task.choose(
    p,
    options,
    choices,
    "Configure · Visual Studio environment",
    identity(p.saved.visual_studio)
  )
  local choice = item.choice
  -- Validate before replacing a working selection. A removed installation can
  -- always be cleared, even when the discovery tool is no longer installed.
  local env = choice and capture(p, choice) or nil
  if choice or p.saved.visual_studio then
    p.saved.visual_studio = choice or false
    p.vs_env, p.env, p.model = env, nil, nil
    project.save(p)
  end
end

-- CMake caches the compiler per build tree. Query the selected preset in view
-- mode so included presets and binaryDir macros are resolved by CMake itself.
local marker_file = "/CMakeFiles/neocmake-visual-studio"

function M.prepare(p, options, location)
  if not M.windows() or p.saved.visual_studio == nil then
    return
  end
  local script = vim.api.nvim_get_runtime_file("cmake/neocmake/build_directory.cmake", false)[1]
  local result = task.probe(
    p,
    vim.list_extend({ options.cmake, "-N", "--log-level=STATUS", "-C", script }, location),
    { cwd = p.root, env = M.merge(M.environment(p), nil) }
  )
  assert(result.code == 0, "Cannot inspect the CMake cache: " .. vim.trim(result.stderr or ""))
  local dir =
    assert(result.stdout:match("%-%- NeoCMake build directory: ([^\r\n]+)"), "Missing CMake build directory")
  if not vim.uv.fs_stat(dir .. "/CMakeCache.txt") then
    return dir, false
  end
  local previous = vim.uv.fs_stat(dir .. marker_file) and vim.fn.readfile(dir .. marker_file)[1] or ""
  if previous == identity(p.saved.visual_studio) then
    return dir, false
  end
  local item = task.choose(p, options, {
    { name = "fresh", label = "Re-detect compiler (CMake 3.24+ replaces CMakeCache.txt and CMakeFiles)" },
    { name = "reuse", label = "Keep cached compiler and apply environment" },
  }, "Visual Studio environment changed", nil)
  return dir, item.name == "fresh"
end

function M.record(p, dir)
  if p.saved.visual_studio then
    assert(
      vim.fn.writefile({ identity(p.saved.visual_studio) }, dir .. marker_file) == 0,
      "Cannot record build tree environment"
    )
  elseif vim.uv.fs_stat(dir .. marker_file) then
    assert(vim.uv.fs_unlink(dir .. marker_file))
  end
end

return M
