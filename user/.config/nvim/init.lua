-- Use terminal colors — inherits the base16 palette from wezterm
vim.opt.termguicolors = false
vim.opt.background = "dark"

vim.opt.number = true
vim.opt.relativenumber = true

vim.api.nvim_create_autocmd("InsertEnter", {
  callback = function() vim.opt.relativenumber = false end,
})
vim.api.nvim_create_autocmd("InsertLeave", {
  callback = function() vim.opt.relativenumber = true end,
})
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.signcolumn = "yes"
vim.opt.clipboard = "unnamedplus"
vim.opt.scrolloff = 8
vim.opt.updatetime = 250
vim.opt.mouse = "a"
