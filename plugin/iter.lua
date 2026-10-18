---@type table<string, fun()>
local subcommands = {
    status = function()
        require('iter').status()
    end,
    review = function()
        require('iter').review()
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
