if vim.g.loaded_craft_nvim == 1 then
  return
end

vim.g.loaded_craft_nvim = 1

require("craft").setup()
