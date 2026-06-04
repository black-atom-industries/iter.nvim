vim.api.nvim_create_user_command('Iter', function()
    require('iter').status()
end, {
    desc = 'Open Iter status window',
    force = true,
})
