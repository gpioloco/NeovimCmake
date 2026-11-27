-- nvim --headless -u NONE -i NONE -l tests/visual_studio.lua
-- Run two independent Neovims against one state directory. Substitute discovery
-- and the SDK, but run the project's configure, build, launch and install.
local repo = vim.fn.getcwd()
vim.opt.rtp:prepend(repo)
local phase, tmp = arg[1], arg[2]
if not phase then
  tmp = vim.fs.normalize(vim.fn.tempname()) .. " (VS environments)"
  vim.fn.mkdir(tmp, "p")
  local ok, err = pcall(function()
    for _, step in ipairs({ "select", "restore" }) do
      local result = vim
        .system({
          vim.v.progpath,
          "--headless",
          "-u",
          "NONE",
          "-i",
          "NONE",
          "-l",
          repo .. "/tests/visual_studio.lua",
          step,
          tmp,
        }, { env = { XDG_STATE_HOME = tmp .. "/state" } })
        :wait(60000)
      assert(result.code == 0, (result.stderr or "") .. (result.stdout or ""))
    end
  end)
  vim.fn.delete(tmp, "rf")
  assert(ok, err)
  print(
    "PASS Visual Studio selection, restart, preset environment, configure/build/run/install, cache switch and reset"
  )
  return
end

local project = require("neocmake.project")
local vs = require("neocmake.visual_studio")
local task = require("neocmake.task")
local plugin = require("neocmake")
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.fn.writefile(lines, path) == 0)
end
local root = tmp .. "/project"
local instances = {}
local function token(n)
  return "test=SDK" .. n
end
for i, name in ipairs({ "Professional", "Build Tools" }) do
  local path = vim.fs.normalize(tmp .. "/Program Files (x86)/" .. name)
  instances[i] = { displayName = name, installationVersion = "18.0." .. i, installationPath = path }
  if phase == "select" then
    write(path .. "/VC/Auxiliary/Build/vcvars32.bat", { "@exit /b 1" })
    write(path .. "/VC/Auxiliary/Build/vcvars64.bat", {
      "@echo off",
      'set "NEOCMAKE_SDK_PROBE=' .. token(i) .. '"',
      'set "LIB=sdk-lib;%LIB%"',
      'set "INCLUDE=sdk-include;%INCLUDE%"',
      'set "PATH=%~dp0;%PATH%"',
      'set "VSINSTALLDIR=%~dp0..\\..\\..\\"',
      'set "VSCMD_ARG_TGT_ARCH=x64"',
    })
  end
end
local installer = tmp .. "/Installer home"
local locator = installer .. "/Microsoft Visual Studio/Installer/vswhere.exe"
local prompt_name = "Configure · Visual Studio environment"
local cache_prompt = "Visual Studio environment changed"
if phase == "select" then
  write(locator, {})
  write(root .. "/CMakePresets.json", {
    vim.json.encode({
      version = 4,
      configurePresets = {
        {
          name = "dev",
          generator = "Ninja",
          binaryDir = "${sourceDir}/out",
          installDir = "${sourceDir}/stage",
          environment = { NEOCMAKE_PRESET_PROBE = "$penv{NEOCMAKE_SDK_PROBE}-preset" },
        },
      },
      buildPresets = { { name = "build-dev", configurePreset = "dev" } },
    }),
  })
  write(root .. "/CMakeLists.txt", {
    "cmake_minimum_required(VERSION 3.23)",
    "project(probe LANGUAGES CXX)",
    'file(WRITE "${CMAKE_BINARY_DIR}/configure.txt" "$ENV{NEOCMAKE_PRESET_PROBE}")',
    'add_custom_target(build_env ALL COMMAND "${CMAKE_COMMAND}" -DOUT=${CMAKE_BINARY_DIR}/build.txt -P "${CMAKE_SOURCE_DIR}/probe.cmake" VERBATIM)',
    "add_executable(probe main.cpp)",
    'install(CODE [[file(WRITE "${CMAKE_INSTALL_PREFIX}/install.txt" "$ENV{NEOCMAKE_PRESET_PROBE}")]])',
  })
  write(root .. "/probe.cmake", { 'file(WRITE "${OUT}" "$ENV{NEOCMAKE_PRESET_PROBE}")' })
  write(root .. "/main.cpp", {
    "#include <cstdio>",
    "#include <cstdlib>",
    'int main() { if (auto p = std::getenv("NEOCMAKE_PRESET_PROBE")) std::puts(p); }',
  })
end
vim.env.NEOCMAKE_SDK_PROBE = nil
vim.env["ProgramFiles(x86)"] = installer
local native_windows = vs.windows()
vs.windows = function()
  return true
end
local probe, captures = task.probe, 0
task.probe = function(p, cmd, options)
  if cmd[1] == locator then
    assert(vim.tbl_contains(cmd, "-prerelease") and vim.tbl_contains(cmd, "-products"))
    return { code = 0, stdout = vim.json.encode(instances) }
  end
  if cmd[1] == (vim.env.ComSpec or "cmd.exe") then
    captures = captures + 1
    for i, instance in ipairs(instances) do
      if options.cwd == instance.installationPath .. "/VC/Auxiliary/Build" then
        if native_windows then
          return probe(p, cmd, options)
        end
        if cmd[#cmd]:find("vcvars32.bat", 1, true) then
          return { code = 1 }
        end
        assert(cmd[#cmd] == "call .\\vcvars64.bat >nul && set" and vim.tbl_contains(cmd, "/u"))
        local lines = {
          "Path=" .. options.cwd .. ":" .. vim.env.PATH,
          "INCLUDE=sdk-include",
          "LIB=sdk-lib",
          "VSINSTALLDIR=" .. instance.installationPath .. "/",
          "VSCMD_ARG_TGT_ARCH=x64",
          "NEOCMAKE_SDK_PROBE=" .. token(i),
          "UNICODE_PROBE=Grüße",
          "=C:=ignored",
        }
        return { code = 0, stdout = vim.iconv(table.concat(lines, "\r\n"), "utf-8", "utf-16le") }
      end
    end
    error("Wrong vcvars working directory " .. options.cwd)
  end
  return probe(p, cmd, options)
end
local answers = {}
plugin.setup({
  select = function(items, options, callback)
    local answer = table.remove(answers, 1)
    assert(answer and answer[1] == options.prompt, "Unexpected prompt " .. options.prompt)
    if answer[2] == false then
      return callback(nil)
    end
    for _, item in ipairs(items) do
      if item.name == answer[2] then
        return callback(item)
      end
    end
    error("Missing choice " .. answer[2])
  end,
})
vim.cmd.edit(vim.fn.fnameescape(root .. "/main.cpp"))
local source = vim.api.nvim_get_current_buf()
local p = project.current()
local function action(name, response, expected_error)
  answers = response or {}
  local ok, err = pcall(vim.cmd, name)
  assert(ok or expected_error, err)
  assert(
    vim.wait(30000, function()
      return not p.task
    end, 10),
    name .. " timed out"
  )
  if expected_error then
    assert(p.error and p.error:find(expected_error, 1, true), tostring(p.error))
  else
    assert(not p.error, tostring(p.error) .. "\n" .. table.concat(p.log, "\n"))
  end
  assert(#answers == 0, name .. " skipped picker")
end
local first = instances[1].installationPath:lower() .. "|x64"
local second = instances[2].installationPath:lower() .. "|x64"
local function contents(file)
  return table.concat(vim.fn.readfile(file), "\n")
end
if phase == "select" then
  assert(vim.fn.maparg("<leader>mv", "n"):find("CMakeConfigureEnvironment", 1, true))
  action("CMakeConfigureEnvironment", { { prompt_name, first } })
  assert(p.saved.visual_studio.path == instances[1].installationPath)
  assert(not contents(p.state):find(token(1), 1, true))
  assert(vim.env.NEOCMAKE_SDK_PROBE == nil)
  action("CMakeConfigureEnvironment", { { prompt_name, false } })
  assert(captures == 1)
  action(
    "CMakeConfigureEnvironment",
    { { prompt_name, instances[2].installationPath:lower() .. "|x86" } },
    "Could not initialize"
  )
  assert(
    p.saved.visual_studio.path == instances[1].installationPath and p.vs_env.NEOCMAKE_SDK_PROBE == token(1)
  )
  write(tmp .. "/another project/CMakeLists.txt", {})
  vim.cmd.edit(vim.fn.fnameescape(tmp .. "/another project/CMakeLists.txt"))
  assert(plugin.status().visual_studio == nil)
  return
end
assert(p.saved.visual_studio.path == instances[1].installationPath and not p.vs_env)
local has_clangd = vim.fn.executable("clangd") == 1
if has_clangd then
  vim.bo.filetype = "cpp"
  vim.lsp.start({
    name = "clangd",
    cmd = { "clangd" },
    root_dir = root,
    cmd_env = { NEOCMAKE_CLIENT_PROBE = "original" },
  })
end
local function check_clangd(sdk)
  if not has_clangd then
    return
  end
  assert(
    vim.wait(8000, function()
      for _, client in ipairs(vim.lsp.get_clients({ name = "clangd", bufnr = source })) do
        local env = client.config.cmd_env
        if
          client.initialized
          and env
          and env.NEOCMAKE_SDK_PROBE == sdk
          and env.NEOCMAKE_CLIENT_PROBE == "original"
        then
          return true
        end
      end
    end),
    "clangd did not receive the selected environment"
  )
end
action("CMakeConfigure", { { "Configure preset", "dev" } })
check_clangd(token(1))
local expected = token(1) .. "-preset"
assert(captures == 1 and contents(root .. "/out/configure.txt") == expected)
if not native_windows then
  assert(p.vs_env.UNICODE_PROBE == "Grüße")
end
action("CMakeBuildPreset", { { "Build preset", "build-dev" } })
action("CMakeBuild")
assert(contents(root .. "/out/build.txt") == expected)
action("CMakeRun", { { "Run target", "probe" } })
local terminal = vim.api.nvim_get_current_buf()
assert(
  vim.wait(3000, function()
    return table.concat(vim.api.nvim_buf_get_lines(terminal, 0, -1, false)):find(expected, 1, true)
  end),
  "missing developer environment in launched executable"
)
vim.cmd.close()
vim.fn.mkdir(root .. "/stage", "p")
action("CMakeBuildInstall " .. vim.fn.fnameescape(root .. "/stage"))
assert(contents(root .. "/stage/install.txt") == expected and captures == 1)
local cache = root .. "/out/CMakeCache.txt"
-- An existing cache from before installing the plugin has no environment marker.
assert(vim.uv.fs_unlink(root .. "/out/CMakeFiles/neocmake-visual-studio"))
action("CMakeConfigure", { { cache_prompt, "reuse" } })
local before = contents(cache)
action("CMakeConfigureEnvironment", { { prompt_name, second } })
action("CMakeConfigure", { { cache_prompt, false } })
assert(before == contents(cache))
action("CMakeConfigure", { { cache_prompt, "fresh" } })
check_clangd(token(2))
assert(contents(root .. "/out/configure.txt") == token(2) .. "-preset")
assert(not table.concat(p.log):find("UNICODE_PROBE", 1, true))
p.vs_env = nil
vim.fn.delete(instances[2].installationPath .. "/VC/Auxiliary/Build/vcvars64.bat")
action("CMakeConfigure", nil, "Select another environment")
action("CMakeConfigureEnvironment", { { prompt_name, "" } })
action("CMakeConfigure", { { cache_prompt, "reuse" } })
check_clangd(nil)
assert(contents(root .. "/out/configure.txt") == "-preset")
assert(not vim.uv.fs_stat(root .. "/out/CMakeFiles/neocmake-visual-studio"))
assert(not p.saved.visual_studio and not p.vs_env and vim.env.NEOCMAKE_SDK_PROBE == nil)
