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
      local message = action .. " complete"
      if not ok then
        message = err == cancelled and (action .. " cancelled") or tostring(err)
        if err ~= cancelled then
          p.error = message
          if not task.preview or not vim.api.nvim_buf_is_loaded(task.preview.buf) then
            vim.notify(message, vim.log.levels.ERROR, { title = "CMake " .. action })
          end
        end
      end
      output.finish(p, message)
      p.task = nil
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
  local capture = diagnostic_dir ~= nil or title == "install"
  local command = "$ " .. table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
  if capture then
    output.begin(p, p.task.show_output)
    output.append(p, { command })
  end
  local lines, pending = {}, { stdout = "", stderr = "" }
  local function receive(_, data, stream)
    data[1] = pending[stream] .. data[1]
    pending[stream] = table.remove(data)
    vim.list_extend(lines, data)
    if capture then
      output.append(p, data)
    end
  end
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
            if capture then
              output.append(p, { rest })
            end
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
    output.begin(p, true)
    if not capture then
      output.append(p, { command })
      output.append(p, lines)
    end
    error(("%s failed (exit %d). See CMake output or :copen."):format(title, code), 0)
  end
  return lines
end

return M
