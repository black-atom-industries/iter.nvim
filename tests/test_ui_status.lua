local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

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
    child.lua([[require('iter').setup({ status = { height = 0.75 } })]])
    child.cmd('Iter')

    helpers.wait_until(
        child,
        [[require('iter').gsw ~= nil
            and require('iter').gsw.loading_message == nil
            and vim.api.nvim_buf_line_count(require('iter').gsw.buf.id) > 1]]
    )

    eq(child.bo.filetype, 'iter')
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == require('iter').gsw.win]]
        ),
        true
    )
    eq(child.api.nvim_buf_get_lines(0, 0, -1, false), {
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
    })
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'status-fixture-entries')
end

return T
