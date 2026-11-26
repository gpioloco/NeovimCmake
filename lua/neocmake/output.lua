local M = {}
local api = vim.api
local project = require("neocmake.project")

function M.append(p, lines)
  if #lines == 0 then
    return
  end
  local first = #p.log == 0
  vim.list_extend(p.log, lines)
  local preview = p.task.preview
  if preview and api.nvim_buf_is_loaded(preview.buf) then
    api.nvim_chan_send(preview.channel, table.concat(lines, "\n") .. "\n")
  end
  if p.logbuf and api.nvim_buf_is_valid(p.logbuf) then
    vim.bo[p.logbuf].modifiable = true
    api.nvim_buf_set_lines(p.logbuf, first and 0 or -1, -1, false, lines)
    vim.bo[p.logbuf].modifiable = false
  end
end

function M.clear(p)
  p.log = {}
  if p.logbuf and api.nvim_buf_is_valid(p.logbuf) then
    vim.bo[p.logbuf].modifiable = true
    api.nvim_buf_set_lines(p.logbuf, 0, -1, false, {})
    vim.bo[p.logbuf].modifiable = false
  end
end

-- A virtual terminal mirrors the captured output while the original job
-- supplies the lines for quickfix. Closing its channel gives this split the
-- same press-any-key dismissal as a finished program in :terminal.
function M.begin(p, show)
  if not p.task.logging then
    M.clear(p)
    p.task.logging = true
  end
  if not show or p.task.preview then
    return
  end
  local buf = api.nvim_create_buf(false, true)
  local old = p.preview_buf and vim.fn.bufwinid(p.preview_buf) or -1
  if old ~= -1 then
    api.nvim_set_current_win(old)
    api.nvim_win_set_buf(old, buf)
  else
    api.nvim_open_win(buf, true, { split = "below", win = -1, height = 12 })
  end
  local channel = api.nvim_open_term(buf, {
    on_input = vim.schedule_wrap(function()
      -- The CMake job owns separate pipes and continues when this view closes.
      if api.nvim_buf_is_loaded(buf) then
        api.nvim_buf_delete(buf, { force = true })
      end
    end),
  })
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].neocmake_root = p.root
  vim.b[buf].term_title = "CMake " .. p.task.action
  p.preview_buf = buf
  p.task.preview = { buf = buf, channel = channel }
  if #p.log > 0 then
    api.nvim_chan_send(channel, table.concat(p.log, "\n") .. "\n")
  end
  vim.cmd.startinsert()
end

function M.finish(p, message)
  local preview = p.task.preview
  if not preview then
    return
  end
  M.append(p, { message })
  if api.nvim_buf_is_loaded(preview.buf) then
    api.nvim_chan_send(preview.channel, "Press any key to close.")
    vim.fn.chanclose(preview.channel)
  end
end

function M.show(p)
  if not p.logbuf or not api.nvim_buf_is_valid(p.logbuf) then
    p.logbuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(p.logbuf, "CMake output — " .. p.root)
    vim.b[p.logbuf].neocmake_root = p.root
    api.nvim_buf_set_lines(p.logbuf, 0, -1, false, p.log)
    vim.bo[p.logbuf].modifiable = false
  end
  local win = vim.fn.bufwinid(p.logbuf)
  if win == -1 then
    vim.cmd("botright 12split")
    api.nvim_win_set_buf(0, p.logbuf)
  else
    api.nvim_set_current_win(win)
  end
  api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(p.logbuf), 0 })
end

function M.diagnostics(p, lines, cwd, title, failed)
  local items, dirs = {}, { cwd }
  local function add(file, row, col, kind, message, base)
    if not file or not kind then
      return
    end
    kind = kind:lower()
    local typ = ({ error = "E", ["fatal error"] = "E", warning = "W", note = "I" })[kind]
    if not typ then
      return
    end
    local path = project.path(base or dirs[#dirs], vim.trim(file))
    if not vim.uv.fs_stat(path) and vim.uv.fs_stat(project.path(p.root, file)) then
      path = project.path(p.root, file)
    end
    table.insert(
      items,
      { filename = path, lnum = tonumber(row), col = tonumber(col) or 1, type = typ, text = message }
    )
  end

  for i, raw in ipairs(lines) do
    local line = raw:gsub("\27%[[%d;]*[A-Za-z]", "")
    local enter = line:match("Entering directory [`'](.-)'")
    if enter then
      table.insert(dirs, enter)
    end
    if line:match("Leaving directory ") and #dirs > 1 then
      table.remove(dirs)
    end
    local file, row, col, kind, msg = line:match("^(.-):(%d+):(%d+):%s*([%a ]+):%s*(.*)")
    if not file then
      file, row, kind, msg = line:match("^(.-):(%d+):%s*([%a ]+):%s*(.*)")
    end
    if not file then
      file, row, col, kind, msg = line:match("^%s*(.-)%((%d+),?(%d*)%):%s*([%a ]+) [%a]+%d+%s*:%s*(.*)")
    end
    if file then
      add(file, row, col, kind, msg)
    else
      kind, file, row = line:match("^CMake (%a+).- at (.-):(%d+)")
      if file then
        local context = {}
        for j = i + 1, #lines do
          if not lines[j]:match("^  ") then
            break
          end
          table.insert(context, vim.trim(lines[j]))
        end
        add(file, row, 1, kind, #context > 0 and table.concat(context, " ") or line, p.root)
      end
    end
  end

  vim.diagnostic.reset(p.ns)
  local grouped = {}
  for _, item in ipairs(items) do
    local buf = vim.fn.bufadd(item.filename)
    grouped[buf] = grouped[buf] or {}
    table.insert(grouped[buf], {
      lnum = item.lnum - 1,
      col = item.col - 1,
      message = item.text,
      source = "CMake build",
      severity = ({ E = 1, W = 2, I = 3 })[item.type],
    })
  end
  for buf, ds in pairs(grouped) do
    vim.diagnostic.set(p.ns, buf, ds)
  end
  if failed and #items == 0 then
    for _, line in ipairs(lines) do
      if line ~= "" then
        table.insert(items, { text = line })
      end
    end
  end
  if #items > 0 or p.qfid then
    local qf = { title = "CMake " .. title .. " — " .. p.root, items = items }
    if
      p.qfid
      and vim.fn.getqflist({ id = p.qfid }).id == p.qfid
      and (#items == 0 or vim.fn.getqflist({ id = 0 }).id == p.qfid)
    then
      qf.id = p.qfid
      vim.fn.setqflist({}, "r", qf)
    else
      vim.fn.setqflist({}, " ", qf)
      p.qfid = vim.fn.getqflist({ id = 0 }).id
    end
  end
end

return M
