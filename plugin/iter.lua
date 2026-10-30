---@type table<string, fun(ref?: string)>
local subcommands = {
    status = function()
        require('iter').status()
    end,
    review = function(ref)
        require('iter').review(ref ~= nil and { base = ref } or nil)
    end,
    annotate = function()
        require('iter').sidebar()
    end,
}

vim.api.nvim_create_user_command('Iter', function(args)
    local name = args.fargs[1] or 'status'
    local run = subcommands[name]

    if run == nil then
        error('[iter] Unknown subcommand: ' .. name, 0)
    end

    if #args.fargs > (name == 'review' and 2 or 1) then
        error('[iter] Too many arguments for ' .. name, 0)
    end

    run(args.fargs[2])
end, {
    desc = 'Open Iter',
    nargs = '*',
    complete = function(arg_lead, cmdline, cursor)
        local args = vim.split(cmdline:sub(1, cursor), '%s+')
        local names = {}

        if #args == 2 then
            names = vim.tbl_keys(subcommands)
            table.sort(names)
        elseif #args == 3 and args[2] == 'review' then
            local git = require('iter.git')
            local root = git.root()

            names = root ~= '' and git.branches(root) or {}
        end

        return vim.tbl_filter(function(name)
            return vim.startswith(name, arg_lead)
        end, names)
    end,
    force = true,
})

local group = vim.api.nvim_create_augroup('iter.uri', { clear = true })

vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = 'iter://*',
    callback = function(args)
        require('iter.uri').read(args.buf)
    end,
})
vim.api.nvim_create_autocmd('SessionLoadPost', {
    group = group,
    callback = function()
        require('iter.uri').clean()
    end,
})
vim.api.nvim_create_autocmd('FileReadCmd', {
    group = group,
    pattern = 'iter://*',
    callback = function() end,
})
