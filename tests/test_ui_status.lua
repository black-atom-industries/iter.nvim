local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local FIXTURE_LINES = {
    'HEAD: main',
    '',
    'Staged (1)',
    'M  staged.txt',
    '',
    'Unstaged (2)',
    ' D deleted.txt',
    ' M modified.txt',
    '',
    'Untracked (2)',
    '?? untracked.txt',
    '?? untracked_dir/',
    '',
    'Unpushed (1)',
    '021b9c0 initial',
}

--- Run `:Iter` (or `command`) in the child and wait for the first render.
---@param command? string
local function open_status(command)
    child.cmd(command or 'Iter')

    helpers.wait_until(
        child,
        [[require('iter').gsw ~= nil
            and vim.api.nvim_buf_line_count(require('iter').gsw.buf.id) > 1]]
    )
end

---@param lhs string
---@return string
local function buf_map_desc(lhs)
    return child.lua_get(
        [[vim.fn.maparg(..., 'n', false, true).desc or '']],
        { lhs }
    )
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_fixture_repo()
            helpers.start_child(child, repo)
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T[':Iter opens the status window with the fixture entries'] = function()
    child.lua([[require('iter').setup({ drawer = { height = 0.75 } })]])
    open_status()

    eq(child.bo.filetype, 'iter')
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == require('iter').gsw.win]]
        ),
        true
    )
    eq(child.api.nvim_buf_get_lines(0, 0, -1, false), FIXTURE_LINES)
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'status-fixture-entries')
end

T[':Iter status opens the status window'] = function()
    open_status('Iter status')

    eq(child.bo.filetype, 'iter')
    eq(child.api.nvim_buf_get_lines(0, 0, -1, false), FIXTURE_LINES)
end

T[':Iter with an unknown subcommand errors'] = function()
    local result = child.lua_get([[{ pcall(vim.cmd, 'Iter foo') }]])

    eq(result[1], false)
    eq(result[2]:find('Unknown subcommand: foo', 1, true) ~= nil, true)
    eq(child.lua_get([[require('iter').gsw]]), vim.NIL)
end

T[':Iter completes the subcommands'] = function()
    eq(child.fn.getcompletion('Iter ', 'cmdline'), { 'status' })
    eq(child.fn.getcompletion('Iter st', 'cmdline'), { 'status' })
    eq(child.fn.getcompletion('Iter x', 'cmdline'), {})
end

T['a remapped key stages and the default key is unbound'] = function()
    child.lua(
        [[require('iter').setup({ keys = { drawer = { stage = 'S' } } })]]
    )
    open_status()

    eq(buf_map_desc('s'), '')
    eq(buf_map_desc('S'), 'Stage or unstage the file')

    child.api.nvim_win_set_cursor(0, { 8, 0 })
    child.type_keys('S')

    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_get_lines(0, 3, 5, false)[1] == 'M  modified.txt']]
    )
    eq(child.api.nvim_buf_get_lines(0, 2, 5, false), {
        'Staged (2)',
        'M  modified.txt',
        'M  staged.txt',
    })
end

T['a key disabled with false is not mapped'] = function()
    child.lua(
        [[require('iter').setup({ keys = { drawer = { discard = false } } })]]
    )
    open_status()

    eq(buf_map_desc('d'), '')
    eq(buf_map_desc('u'), 'Unstage the file')
end

T['help lists the resolved keys and closes with its keys'] = function()
    child.lua([[require('iter').setup({
        keys = {
            drawer = { stage = 'S', discard = false },
            help = { close = { 'x', '<Esc>' } },
        },
    })]])
    open_status()

    child.type_keys('?')
    helpers.wait_until(
        child,
        [[vim.api.nvim_get_current_win() == require('iter').gsw.help_win]]
    )

    eq(child.api.nvim_buf_get_lines(0, 0, -1, false), {
        '<CR>  Open the file and close the status window',
        '=     Toggle the diff preview',
        'S     Stage or unstage the file',
        'u     Unstage the file',
        'q     Close',
        '?     Show the keys',
    })
    eq(buf_map_desc('x'), 'Close')
    eq(buf_map_desc('<Esc>'), 'Close')
    eq(buf_map_desc('q'), '')

    helpers.expect_screenshot(child, 'status-help')

    child.type_keys('x')
    eq(child.lua_get([[require('iter').gsw.help_win]]), vim.NIL)
    eq(child.bo.filetype, 'iter')
end

T['outside a git repository'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)
            repo = vim.fn.resolve(vim.fn.tempname())
            vim.fn.mkdir(repo, 'p')
            helpers.start_child(child, repo)
            child.lua([[
                _G.notes = {}
                vim.notify = function(msg, level)
                    table.insert(_G.notes, { msg, level })
                end
            ]])
        end,
    },
})

T['outside a git repository'][':Iter warns and opens nothing'] = function()
    child.cmd('Iter')

    eq(child.lua_get([[_G.notes]]), {
        { '[iter] Not inside a git repository', vim.log.levels.WARN },
    })
    eq(child.lua_get([[require('iter').gsw]]), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
    eq(child.bo.filetype, '')
end

return T
