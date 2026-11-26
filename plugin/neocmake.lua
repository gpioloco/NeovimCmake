if vim.g.loaded_neocmake then
  return
end
vim.g.loaded_neocmake = true
local plugin = require("neocmake")
if not plugin.configured then
  plugin.setup()
end
