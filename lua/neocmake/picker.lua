local api = vim.api

-- A native floating list, including on a clean Neovim installation.
return function(items, opts, on_choice)
  local lines, width, initial = {}, vim.fn.strdisplaywidth(opts.prompt) + 4, 1
  for i, item in ipairs(items) do
    local active = item.name == opts.current
    if active then
      initial = i
    end
    lines[i] = (active and "● " or "  ") .. opts.format_item(item)
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]) + 2)
  end
  width = math.max(1, math.min(width, vim.o.columns - 4))
  local height = math.max(1, math.min(#items, vim.o.lines - 5, 16))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 3)),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.prompt .. " ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  api.nvim_win_set_cursor(win, { initial, 0 })
  local done = false
  local function finish(item)
    if done then
      return
    end
    done = true
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      on_choice(item)
    end)
  end
  vim.keymap.set("n", "<CR>", function()
    finish(items[api.nvim_win_get_cursor(win)[1]])
  end, { buffer = buf })
  for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      finish()
    end, { buffer = buf, nowait = true })
  end
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        finish()
      end)
    end,
  })
end
