-- Run from the repository root with nvim --headless -u NONE -c 'luafile tests/integration.lua'
-- Omit -u NONE and set NEOCMAKE_LOCAL_LSP=1 to test the configured clangd client.
local repo = vim.fn.getcwd()
local tmp = vim.fn.tempname() .. " cmake integration"
local root = tmp .. "/workflow"
local api = vim.api
vim.opt.rtp:prepend(repo)
vim.fn.mkdir(root, "p")
for _, file in ipairs({ "CMakeLists.txt", "CMakePresets.json", "src", "include" }) do
  local original = repo .. "/examples/workflow/" .. file
  local operation = vim.fn.isdirectory(original) == 1 and "copy_directory" or "copy"
  local result = vim.system({ "cmake", "-E", operation, original, root .. "/" .. file }):wait()
  assert(result.code == 0, result.stderr)
end
-- Give the release tree a flag the already-open debug buffer has never seen.
local fixture = root .. "/CMakePresets.json"
local preset_file = require("neocmake.project").json(fixture)
preset_file.configurePresets[1].environment = { NEOCMAKE_PARENT = "${presetName}" }
preset_file.configurePresets[3].environment = { NEOCMAKE_RUN = "$env{NEOCMAKE_PARENT}-run" }
preset_file.configurePresets[3].cacheVariables.CMAKE_CXX_FLAGS = "-DNEOCMAKE_RELEASE_PROBE=73"
vim.fn.writefile({ vim.json.encode(preset_file) }, fixture)
local app_file = root .. "/src/hello_base.cpp"
local app = vim.fn.readfile(app_file)
table.insert(app, 1, "#include <cstdlib>")
table.insert(app, #app, '    if (auto env = std::getenv("NEOCMAKE_RUN")) std::cout << env;')
vim.fn.writefile(app, app_file)
local plugin = require("neocmake")
local answers = {}
local choices = {}
local function picker(items, opts, callback)
  choices[opts.prompt] = vim.tbl_map(function(x)
    return x.name or "DEFAULT"
  end, items)
  local name = table.remove(answers, 1)
  for _, item in ipairs(items) do
    if item.name == name then
      callback(item)
      return
    end
  end
  error("Missing picker choice " .. tostring(name) .. " in " .. vim.inspect(choices))
end

local function wait_for(check, message)
  assert(vim.wait(30000, check, 25), message)
end

local p
local function action(name, expected_error)
  vim.cmd(name)
  wait_for(function()
    return not p.task
  end, "Timed out in " .. name)
  if expected_error then
    assert(p.error, "Expected " .. name .. " to fail")
  else
    assert(not p.error, p.error)
  end
end

local function run()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit("src/base.cpp")
  local base = api.nvim_get_current_buf()
  local project = require("neocmake.project")
  p = project.current()
  assert(p.root == root)
  plugin.setup({ prefix = "<F8>" })
  assert(vim.fn.maparg("<F8>b", "n") ~= "")
  vim.cmd.CMakeConfigurePreset()
  wait_for(function()
    return vim.api.nvim_win_get_config(0).relative == "editor"
  end, "Missing floating preset selector")
  local labels = api.nvim_buf_get_lines(0, 0, -1, false)
  assert(#labels == 2 and labels[1]:match("Debug"), vim.inspect(labels))
  api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  wait_for(function()
    return not p.task
  end, "Picker did not complete")
  assert(not p.error, p.error)
  plugin.setup({ prefix = "<F7>", select = picker })
  assert(vim.fn.maparg("<F8>b", "n") == "" and vim.fn.maparg("<F7>b", "n") ~= "")
  assert(p.saved.dir == root .. "/out/debug", vim.inspect(p.saved))
  assert(vim.fn.filereadable(root .. "/compile_commands.json") == 1)
  local db = project.json(root .. "/compile_commands.json")
  assert(#db == 4 and db[1].command:match("GREETING_BASE_VALUE=21"))

  local function assert_preview(text)
    local buf = api.nvim_get_current_buf()
    assert(buf == p.preview_buf and vim.bo[buf].buftype == "terminal")
    wait_for(function()
      local content = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false))
      return content:find(text, 1, true) and content:find("Press any key to close", 1, true)
    end, "Missing terminal output: " .. text)
    vim.cmd.stopinsert()
    vim.cmd.close()
    assert(api.nvim_get_current_buf() == base, "The source window should regain focus")
  end
  assert_preview("Build files have been written")
  for key, group in pairs({ p = "Configure", P = "Build", t = "Build", k = "Build", l = "Run", r = "Run" }) do
    local map = vim.fn.maparg("<F7>" .. key, "n", false, true)
    assert(vim.startswith(map.desc, group) and vim.startswith(map.rhs, "<Cmd>CMake" .. group))
  end
  answers = { "Release" }
  action("CMakeBuildConfiguration")
  assert_preview("CMAKE_BUILD_TYPE:STRING=Release")
  assert(p.model.configurations[1].name == "Release" and p.saved.dir == root .. "/out/debug")
  assert(project.json(root .. "/compile_commands.json")[1].command:find("-DNDEBUG", 1, true))
  action("CMakeConfigure")
  assert(p.model.configurations[1].name == "Release")
  assert_preview("CMAKE_BUILD_TYPE:STRING=Release")
  answers = { "Debug" }
  action("CMakeConfiguration") -- Pre-existing command alias.
  assert_preview("CMAKE_BUILD_TYPE:STRING=Debug")

  answers = { "debug-build", "base", "hello_extended" }
  action("CMakeBuildPreset")
  assert(vim.deep_equal(choices["Build preset"], { "DEFAULT", "debug-build" }))
  action("CMakeBuildTarget")
  assert(#choices["Build target"] == 5)
  action("CMakeBuild")
  assert_preview("Build complete")
  local build_log = vim.deepcopy(p.log)
  action("CMakeRunTarget")
  assert(vim.deep_equal(build_log, p.log), "A selector discarded the build output")
  action("CMakeLog")
  assert(vim.deep_equal(api.nvim_buf_get_lines(0, 0, -1, false), build_log))
  vim.cmd.close()
  assert(vim.deep_equal(choices["Run target"], { "hello_base", "hello_extended" }))
  action("CMakeRun")
  local terminal = api.nvim_get_current_buf()
  wait_for(function()
    return table.concat(api.nvim_buf_get_lines(terminal, 0, -1, false)):find("extended: 42", 1, true)
  end, "Missing terminal output")
  vim.cmd.stopinsert()
  vim.cmd.close()
  assert(p.saved.target == "base")
  action("CMakeBuildInstall")
  assert_preview("Installing:")
  for _, app in ipairs({ "hello_base", "hello_extended" }) do
    local result = vim.system({ root .. "/stage/debug/bin/" .. app }):wait()
    assert(result.code == 0 and result.stdout:match(app == "hello_base" and "21" or "42"))
  end

  local source = root .. "/src/base.cpp"
  local original = vim.fn.readfile(source)
  api.nvim_buf_set_lines(base, -1, -1, false, { "int invalid = neocmake_missing_symbol;" })
  action("CMakeBuild", true)
  assert_preview("neocmake_missing_symbol")
  local ds = vim.diagnostic.get(base, { namespace = p.ns })
  assert(
    #ds > 0 and ds[1].lnum == #original and ds[1].message:find("neocmake_missing_symbol"),
    vim.inspect(ds)
  )
  local qf = vim.fn.getqflist({ id = p.qfid, items = 1 }).items
  assert(qf[1].bufnr == base and qf[1].lnum == #original + 1, vim.inspect(qf))
  api.nvim_buf_set_lines(base, 0, -1, false, original)
  action("CMakeBuild")
  assert_preview("Build complete")
  assert(#vim.diagnostic.get(base, { namespace = p.ns }) == 0)
  assert(#vim.fn.getqflist({ id = p.qfid, items = 1 }).items == 0)
  api.nvim_set_current_buf(base)
  answers = { "release", "hello_base" }
  action("CMakeConfigurePreset")
  assert_preview("Build files have been written")
  action("CMakeRun")
  local second = api.nvim_get_current_buf()
  wait_for(function()
    local text = table.concat(api.nvim_buf_get_lines(second, 0, -1, false))
    return text:find("base: 21", 1, true) and text:find("release-run", 1, true)
  end, "Missing base program output")
  vim.cmd.stopinsert()
  vim.cmd.close()
  api.nvim_set_current_buf(base)
  assert(project.json(root .. "/compile_commands.json")[1].directory == root .. "/out/release")

  if vim.env.NEOCMAKE_LOCAL_LSP then
    wait_for(function()
      return #vim.lsp.get_clients({ bufnr = base, name = "clangd" }) > 0
    end, "Local config did not attach clangd")
    local client = vim.lsp.get_clients({ bufnr = base, name = "clangd" })[1]
    wait_for(function()
      return client.initialized
    end, "clangd did not initialize")
    -- Trigger a fresh parse and query a symbol supplied exclusively by CMake.
    api.nvim_buf_set_lines(base, -1, -1, false, { "int probe = NEOCMAKE_RELEASE_PROBE;" })
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(base) },
      position = { line = api.nvim_buf_line_count(base) - 1, character = 18 },
    }
    local info = client:request_sync("textDocument/hover", params, 8000, base)
    assert(
      info and info.result and vim.inspect(info.result):find("73", 1, true),
      "clangd did not see -DNEOCMAKE_RELEASE_PROBE=73: " .. vim.inspect(info)
    )
    api.nvim_buf_set_lines(base, -2, -1, false, {})
    print("Local clangd picked up Release compiler flags in the open buffer")
  end
  -- Exercise an included, inherited user build preset and Ninja Multi-Config.
  vim.fn.writefile({
    vim.json.encode({
      version = 4,
      configurePresets = {
        { name = "multi", generator = "Ninja Multi-Config", binaryDir = "${sourceDir}/out/multi" },
      },
      buildPresets = {
        { name = "multi-base", hidden = true, configurePreset = "multi", configuration = "Release" },
      },
    }),
  }, root .. "/multi.json")
  vim.fn.writefile({
    vim.json.encode({
      version = 4,
      include = { "multi.json" },
      buildPresets = {
        { name = "multi-release", inherits = "multi-base" },
      },
    }),
  }, root .. "/CMakeUserPresets.json")
  answers = { "multi", "multi-release" }
  action("CMakePreset")
  action("CMakeBuildPreset")
  local multi_db = project.json(root .. "/compile_commands.json")
  assert(#multi_db == 4 and multi_db[1].command:find("Release", 1, true), vim.inspect(multi_db))
  action("CMakeInstall " .. tmp .. "/custom prefix")
  assert(vim.fn.executable(tmp .. "/custom prefix/bin/hello_extended") == 1)
  assert(vim.fn.filereadable(root .. "/out/multi/Release/hello_extended") == 1)
  answers = { "Debug" }
  action("CMakeBuildConfiguration")
  assert(p.saved.build_preset == "multi-release")
  assert(project.json(root .. "/compile_commands.json")[1].command:find("Debug", 1, true))
  action("CMakeBuild")
  assert(vim.fn.executable(root .. "/out/multi/Debug/hello_extended") == 1)

  -- Removing the presets falls back to a conventional build tree. Keep a
  -- pre-existing root database intact and point clangd to the new build.
  vim.fn.delete(root .. "/CMakeUserPresets.json")
  vim.fn.delete(root .. "/CMakePresets.json")
  vim.fn.writefile({ "[]" }, root .. "/compile_commands.json")
  action("CMakeConfigure")
  action("CMakeBuild")
  assert(p.database_dir == root .. "/build", vim.inspect(p.database_dir))
  assert(vim.deep_equal(vim.fn.readfile(root .. "/compile_commands.json"), { "[]" }))
  print(
    "PASS preset dropdown, compatible presets, four targets, launch, install, build diagnostics, database switch"
  )
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.defer_fn(function()
      local ok, err = xpcall(run, debug.traceback)
      if not ok then
        print(err .. "\n" .. table.concat(p and p.log or {}, "\n"))
      end
      if p then
        vim.fn.delete(p.state)
      end
      vim.fn.delete(tmp, "rf")
      vim.cmd(ok and "qa!" or "cquit! 1")
    end, 100)
  end,
})
