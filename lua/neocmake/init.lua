local project = require("neocmake.project")
local presets = require("neocmake.presets")
local task = require("neocmake.task")
local output = require("neocmake.output")
local database = require("neocmake.database")
local M = {}
local defaults = {
  prefix = "<leader>m",
  cmake = "cmake",
  build_dir = "build",
  save_before_build = true,
  select = require("neocmake.picker"),
}
local opts = defaults
local actions = {}

local function exec(p, args, title, diag_dir, env)
  table.insert(args, 1, opts.cmake)
  return task.exec(p, args, title, diag_dir, env)
end

local function select_preset(p)
  local lines = exec(p, { "--list-presets=configure" }, "list configure presets")
  local item = task.choose(p, opts, presets.list(lines), "Configure preset", p.saved.preset)
  if item.name ~= p.saved.preset then
    p.saved.preset, p.saved.build_preset, p.saved.configuration = item.name, nil, nil
    p.saved.target, p.saved.launch, p.saved.dir, p.model = nil, nil, nil, nil
    project.save(p)
  end
end

local function configuration(p)
  local configs = p.model.configurations
  if #configs == 1 then
    return configs[1]
  end
  local name = p.saved.configuration
  if p.saved.build_preset then
    local _, from_preset = p.presets.build(p.saved.build_preset)
    name = from_preset or name
  end
  if not name then
    return configs[1]
  end
  for _, cfg in ipairs(configs) do
    if cfg.name == name then
      return cfg
    end
  end
  error("No CMake configuration named " .. name .. ". Select a configuration or another build preset.")
end

local function refresh(p)
  p.model = project.model(p.saved.dir, p.model)
  local cfg = configuration(p)
  if p.saved.target and not cfg.targets[p.saved.target] then
    p.saved.target = nil
  end
  local launch = cfg.targets[p.saved.launch]
  if not launch or not launch.path then
    p.saved.launch = nil
  end
  local warning = database.publish(p, cfg.name)
  if warning and warning ~= p.database_warning then
    vim.notify(warning, vim.log.levels.WARN)
  end
  p.database_warning = warning
  project.save(p)
  return cfg
end

local function save_buffers(p)
  if not opts.save_before_build then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.fs.relpath(p.root, name) then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent update")
      end)
    end
  end
end

local function configure(p)
  save_buffers(p)
  p.model = nil
  local use_preset = project.has_presets(p.root)
  if use_preset and not p.saved.preset then
    select_preset(p)
  end
  local args = { "-S", p.root, "-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON", "--log-level=STATUS" }
  local dir
  if use_preset then
    vim.list_extend(args, { "--preset", p.saved.preset })
    dir = p.saved.dir
  else
    p.saved.preset, p.saved.build_preset = nil, nil
    dir = project.path(p.root, opts.build_dir)
    vim.list_extend(args, { "-B", dir })
  end
  if dir then
    project.query(dir)
  end
  local lines = exec(p, args, "configure", p.root)
  -- Let CMake locate the tree. This also handles binaryDir inherited from an
  -- included preset, environment macros, and directories outside the project.
  for _, line in ipairs(lines) do
    local path = line:match("^%-%- Build files have been written to: (.+)$")
    if path then
      dir = project.path(p.root, vim.trim(path))
    end
  end
  assert(dir, "CMake did not report its build directory. Check :CMakeLog.")
  if project.query(dir) then
    exec(p, args, "read target model", p.root)
  end
  p.saved.dir = dir
  p.presets = use_preset and presets.metadata(p.root) or nil
  refresh(p)
  p.env = p.presets and p.presets.environment(p.saved.preset, p.model.generator.name) or nil
end

local function ensure(p)
  if not p.model or not vim.uv.fs_stat(p.saved.dir .. "/CMakeCache.txt") then
    configure(p)
  end
end

function actions.Preset(p)
  save_buffers(p)
  assert(project.has_presets(p.root), "This project has no CMake presets. Use :CMakeConfigure.")
  select_preset(p)
  configure(p)
end
actions.Configure = configure

function actions.BuildPreset(p)
  ensure(p)
  assert(p.saved.preset, "This project has no CMake presets")
  local list = presets.list(exec(p, { "--list-presets=build" }, "list build presets"))
  p.presets = presets.metadata(p.root)
  local items = { { label = "Default build settings" } }
  for _, item in ipairs(list) do
    if p.presets.build(item.name) == p.saved.preset then
      table.insert(items, item)
    end
  end
  p.saved.build_preset = task.choose(p, opts, items, "Build preset", p.saved.build_preset).name
  p.saved.target = nil
  refresh(p)
end

function actions.Configuration(p)
  ensure(p)
  if p.saved.build_preset then
    local _, fixed = p.presets.build(p.saved.build_preset)
    assert(not fixed, "Build preset " .. p.saved.build_preset .. " selects " .. tostring(fixed))
  end
  assert(p.model.generator.multiConfig, "The configure preset or CMAKE_BUILD_TYPE selects this configuration")
  p.saved.configuration = task.choose(
    p,
    opts,
    p.model.configurations,
    "Build configuration",
    p.saved.configuration or p.model.configurations[1].name
  ).name
  refresh(p)
end

local function select_target(p, launch)
  ensure(p)
  local targets = configuration(p).targets
  local items = {}
  if not launch then
    table.insert(items, { label = "Default targets (build preset or all)" })
  end
  for _, name in ipairs(vim.fn.sort(vim.tbl_keys(targets))) do
    local t = targets[name]
    if not launch or t.path then
      table.insert(items, { name = name, label = name .. "  [" .. t.type .. "]" })
    end
  end
  local key = launch and "launch" or "target"
  local selected = task.choose(p, opts, items, launch and "Launch target" or "Build target", p.saved[key])
  p.saved[key] = selected.name
  project.save(p)
  return targets[selected.name]
end

function actions.Target(p)
  select_target(p, false)
end
function actions.LaunchTarget(p)
  select_target(p, true)
end

local function with_config(p, args)
  if p.model.generator.multiConfig then
    vim.list_extend(args, { "--config", configuration(p).name })
  end
  return args
end

local function build(p, target)
  save_buffers(p)
  local args = { "--build" }
  if p.saved.build_preset then
    vim.list_extend(args, { "--preset", p.saved.build_preset })
  else
    table.insert(args, p.saved.dir)
  end
  with_config(p, args)
  if target then
    vim.list_extend(args, { "--target", target })
  end
  local env
  if not p.saved.build_preset then
    env = p.env
  end
  exec(p, args, "build", p.saved.dir, env)
  return refresh(p)
end

function actions.Build(p)
  ensure(p)
  build(p, p.saved.target)
end

function actions.Run(p, args)
  ensure(p)
  local cfg = configuration(p)
  local t = cfg.targets[p.saved.launch]
  if not t or not t.path then
    t = select_target(p, true)
  end
  cfg = build(p, t.name)
  local path = assert(cfg.targets[t.name] and cfg.targets[t.name].path, "Launch artifact disappeared")
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].neocmake_root = p.root
  vim.bo[buf].bufhidden = "hide"
  local cmd = vim.list_extend({ path }, args.fargs)
  local id = vim.fn.jobstart(cmd, { term = true, cwd = p.root, env = p.env })
  assert(id > 0, "Could not launch " .. path)
  vim.cmd("startinsert")
end

function actions.Install(p, args)
  ensure(p)
  local gen = p.model.generator.name
  build(p, (gen:match("Visual Studio") or gen == "Xcode") and "ALL_BUILD" or "all")
  local cmd = with_config(p, { "--install", p.saved.dir })
  if args.args ~= "" then
    local prefix = vim.fs.normalize((args.fargs[1]:gsub("\\ ", " ")))
    vim.list_extend(cmd, { "--prefix", project.path(p.root, prefix) })
  end
  exec(p, cmd, "install", nil, p.env)
end

local keys = {
  { "p", "Preset", "Select configure preset" },
  { "P", "BuildPreset", "Select build preset" },
  { "c", "Configure", "Configure" },
  { "t", "Target", "Select build target" },
  { "l", "LaunchTarget", "Select launch target" },
  { "k", "Configuration", "Select build configuration" },
  { "b", "Build", "Build" },
  { "r", "Run", "Build and run" },
  { "i", "Install", "Build and install" },
  { "o", "Log", "Show output" },
  { "s", "Status", "Show selections" },
  { "x", "Stop", "Stop CMake job" },
}
local installed = {}

function M.status()
  local p = project.current()
  return vim.tbl_extend(
    "force",
    vim.deepcopy(p.saved),
    { root = p.root, busy = p.task ~= nil, error = p.error }
  )
end

local function invoke(name, args)
  local p = project.current()
  if name == "Log" then
    return output.show(p)
  end
  if name == "Stop" then
    if p.task and p.task.job then
      p.task.stopped = true
      vim.fn.jobstop(p.task.job)
    else
      vim.notify("No running CMake process")
    end
    return
  end
  if name == "Status" then
    local s = p.saved
    return vim.notify(
      table.concat({
        p.root,
        "Configure preset: " .. (s.preset or "default"),
        "Build preset: " .. (s.build_preset or "default"),
        "Build target: " .. (s.target or "default"),
        "Launch target: " .. (s.launch or "unselected"),
        "Build tree: " .. (s.dir or "unconfigured"),
        "Configuration: " .. (p.model and configuration(p).name or s.configuration or "default"),
        "Activity: " .. (p.task and p.task.action or "idle"),
      }, "\n"),
      nil,
      { title = "CMake" }
    )
  end
  task.start(p, name, function()
    output.clear(p)
    actions[name](p, args)
    if name ~= "Run" then
      vim.notify("CMake " .. name .. " complete", vim.log.levels.INFO)
    end
  end)
end

function M.setup(options)
  opts = vim.tbl_extend("force", defaults, options or {})
  for _, lhs in ipairs(installed) do
    pcall(vim.keymap.del, "n", lhs)
  end
  installed = {}
  for _, spec in ipairs(keys) do
    local suffix, name, description = unpack(spec)
    local nargs = name == "Run" and "*" or (name == "Install" and "?" or 0)
    vim.api.nvim_create_user_command("CMake" .. name, function(args)
      local ok, err = pcall(invoke, name, args)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR)
      end
    end, { nargs = nargs, complete = name == "Install" and "dir" or nil, desc = description, force = true })
    if opts.prefix then
      local lhs = opts.prefix .. suffix
      vim.keymap.set(
        "n",
        lhs,
        "<Cmd>CMake" .. name .. "<CR>",
        { desc = "CMake: " .. description, silent = true }
      )
      table.insert(installed, lhs)
    end
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("NeoCMakeClangd", { clear = true }),
    callback = database.on_attach,
  })
  M.configured = true
end

return M
