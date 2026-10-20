-- Loads iter.nvim alone for the clips: `nvim --clean -u init.lua`.
local tapes = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(tapes .. '/../../..', ':p'))

vim.o.termguicolors = true
vim.o.number = true
vim.o.ruler = false
vim.o.laststatus = 3
vim.o.showcmd = false
vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. 'I'
vim.o.statusline = "%f %m%=%{v:lua.require'iter'.statusline()} "
vim.o.tabline = "%!v:lua.require'iter'.tabline()"

if vim.env.BLACK_ATOM ~= nil and vim.env.BLACK_ATOM ~= '' then
    vim.opt.runtimepath:append(vim.env.BLACK_ATOM)
    vim.cmd.colorscheme('black-atom-minium-sienna-light')
end

require('iter').setup()
