---@type table<string, fun()>
local subcommands = {
    status = function()
        require('iter').status()
    end,
    review = function()
        require('iter').review()
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

    run()
end, {
    desc = 'Open Iter',
    nargs = '?',
    complete = function(arg_lead)
        local names = vim.tbl_filter(function(name)
            return vim.startswith(name, arg_lead)
        end, vim.tbl_keys(subcommands))
        table.sort(names)

        return names
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
