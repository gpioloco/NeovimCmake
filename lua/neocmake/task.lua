local output = require("neocmake.output")
local M = {}
local cancelled = {}

-- Each project has at most one workflow. Yield for a picker or a subprocess
-- so configure -> build -> launch can share ordinary sequential control flow.
function M.start(p, action, fn)
  if p.task then
    vim.notify("CMake is waiting for " .. p.task.action, vim.log.levels.WARN)
    return
  end
  local task = { action = action }
  p.task = task
  local thread = coroutine.create(fn)
  function task.resume(...)
    local ok, err = coroutine.resume(thread, ...)
    if not ok or coroutine.status(thread) == "dead" then
      p.task = nil
      if not ok and err ~= cancelled then
        p.error = tostring(err)
        vim.notify(p.error, vim.log.levels.ERROR, { title = "CMake " .. action })
      end
    end
  end
  p.error = nil
  task.resume()
end

function M.choose(p, options, items, prompt, current)
  assert(#items > 0, "No choices available for " .. prompt)
  local resume = p.task.resume
  options.select(items, {
    prompt = prompt,
    current = current,
    format_item = function(item)
      return item.label or item.name
    end,
  }, function(item)
    vim.schedule(function()
      resume(item)
    end)
  end)
  local item = coroutine.yield()
  if not item then
    error(cancelled)
  end
  return item
end

function M.exec(p, args, title, diagnostic_dir, env)
  local lines, pending = {}, { stdout = "", stderr = "" }
  local function receive(_, data, stream)
    data[1] = pending[stream] .. data[1]
    pending[stream] = table.remove(data)
    vim.list_extend(lines, data)
    output.append(p, data)
  end
  output.append(p, { "$ " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ") })
  local resume = p.task.resume
  local id = vim.fn.jobstart(args, {
    cwd = p.root,
    env = env,
    on_stdout = receive,
    on_stderr = receive,
    on_exit = function(_, code)
      vim.schedule(function()
        for _, rest in pairs(pending) do
          if rest ~= "" then
            table.insert(lines, rest)
            output.append(p, { rest })
          end
        end
        resume(code)
      end)
    end,
  })
  assert(id > 0, "Could not start " .. args[1] .. ". Check your PATH.")
  p.task.job = id
  local code = coroutine.yield()
  p.task.job = nil
  if p.task.stopped then
    error(cancelled)
  end
  if diagnostic_dir or code ~= 0 then
    output.diagnostics(p, lines, diagnostic_dir or p.root, title, code ~= 0)
  end
  if code ~= 0 then
    output.show(p)
    error(("%s failed (exit %d). See CMake output or :copen."):format(title, code), 0)
  end
  return lines
end

return M
