local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fs.dirname(vim.fn.fnamemodify(source, ':p'))
local project_root = vim.fs.dirname(tests_dir)

vim.opt.runtimepath:prepend(project_root)
vim.opt.runtimepath:append(project_root .. '/deps/diffs.nvim')
vim.opt.runtimepath:append(project_root .. '/deps/mini.nvim')

vim.g.mapleader = ' '

-- One throwaway HOME and XDG tree per test run. Child Neovims inherit the
-- environment and reuse it, so nothing reads or writes the user's dotfiles.
if vim.env.ITER_TEST_HOME == nil then
    local home = vim.fn.tempname()
    vim.env.ITER_TEST_HOME = home
    vim.env.HOME = home
    vim.env.XDG_CONFIG_HOME = home .. '/config'
    vim.env.XDG_DATA_HOME = home .. '/data'
    vim.env.XDG_STATE_HOME = home .. '/state'
    vim.env.XDG_CACHE_HOME = home .. '/cache'
    for _, dir in ipairs({ 'config', 'data', 'state', 'cache' }) do
        vim.fn.mkdir(home .. '/' .. dir, 'p')
    end
end

-- Isolate every git call, from tests and from the plugin, from the user's git
-- config, and pin identity and dates so commit hashes are reproducible.
vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
vim.env.GIT_CONFIG_NOSYSTEM = '1'
vim.env.GIT_TERMINAL_PROMPT = '0'
vim.env.GIT_AUTHOR_NAME = 'Iter Test'
vim.env.GIT_AUTHOR_EMAIL = 'iter@example.test'
vim.env.GIT_COMMITTER_NAME = 'Iter Test'
vim.env.GIT_COMMITTER_EMAIL = 'iter@example.test'
vim.env.GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z'
vim.env.GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z'

-- With a UI attached this file is being sourced by a person, whose session
-- owns its own mini.test setup; only headless runs set it up here.
if #vim.api.nvim_list_uis() == 0 then
    require('mini.test').setup()
end
