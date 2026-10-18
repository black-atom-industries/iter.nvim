local M = {}

local function check_nvim_version()
    if vim.fn.has('nvim-0.12') == 1 then
        vim.health.ok('Neovim 0.12 or newer')
    else
        vim.health.error('Neovim 0.12 or newer is required')
    end
end

local function check_git()
    if vim.fn.executable('git') == 1 then
        vim.health.ok('`git` is executable')
    else
        vim.health.error('`git` is not executable')
    end
end

M.check = function()
    vim.health.start('iter.nvim report')
    check_nvim_version()
    check_git()
end

return M
