local helpers = dofile('tests/helpers.lua')
local H = dofile('tests/helpers_review.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = H.R
local D = [[require('iter').drawer]]

---@return string
local function messages()
    return child.cmd_capture('messages')
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['a.txt'] = { 'one', 'two' } })
            helpers.write_file(
                vim.fs.joinpath(repo, 'a.txt'),
                { 'one', 'changed' }
            )
            helpers.start_child(child, repo, { lines = 36 })
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['a removed worktree leaves an open review quiet'] = function()
    child.lua([[require('iter').setup({ refresh = { poll_ms = 30 } })]])
    H.open(child)
    vim.fn.delete(repo, 'rf')
    vim.uv.sleep(200)

    eq(messages():find('ENOENT', 1, true), nil)
    eq(child.lua_get(R .. ' ~= nil'), true)
end

T['a failed read of the base keeps the state of the last one'] = function()
    helpers.git(repo, { 'switch', '--quiet', '-c', 'feat' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'on feat' })
    child.lua([[require('iter').setup()]])
    H.open(child, 'Iter review main')

    local since = R .. '.changes.since.label'
    local text = child.lua_get(since)

    child.lua([[
        vim.notify = function() end
        require('iter.git').base_changes = function()
            return nil, 'boom'
        end
    ]])

    eq(child.lua_get(R .. ':load()'), false)
    eq(child.lua_get(since), text)
    eq(child.lua_get(R .. '.changes.base ~= nil'), true)
end

T['reveal() leaves the base list alone'] = function()
    child.lua([[require('iter').setup()]])
    H.open(child)
    child.type_keys('b')
    helpers.wait_until(child, R .. '.picker ~= nil')

    local win = child.api.nvim_get_current_win()

    child.lua(R .. ":reveal('a.txt', 1)")

    eq(child.api.nvim_get_current_win(), win)
    eq(child.lua_get(R .. '.panel.page == ' .. R .. '.picker'), true)
end

T['the drawer closes cleanly after the split preview is wiped'] = function()
    child.lua(
        [[require('iter').setup({ status = { style = 'drawer' }, diff = { layout = 'split' } })]]
    )
    child.cmd('Iter')
    helpers.wait_until(
        child,
        D .. [[ ~= nil and ]] .. D .. [[.view.old ~= nil]]
    )
    child.lua('_G.old_buf = ' .. D .. '.view.old.buf')
    child.lua([[
        vim.api.nvim_win_call(require('iter').drawer.pane, function()
            vim.cmd.bwipeout()
        end)
    ]])
    helpers.wait_until(child, D .. ' == nil')

    eq(messages():find('E444', 1, true), nil)
    eq(child.lua_get('vim.api.nvim_buf_is_valid(_G.old_buf)'), false)
end

T['a conflicted file says so in its header'] = function()
    helpers.git(repo, { 'switch', '--quiet', '-c', 'other' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'on other' })
    helpers.git(repo, { 'switch', '--quiet', 'main' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'one', 'different' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'on main' })
    vim.system({ 'git', 'merge', '--quiet', 'other' }, { cwd = repo }):wait()

    child.lua([[require('iter').setup()]])
    H.open(child)
    helpers.wait_until(child, R .. '.view:is_shown()')

    local header = child.lua_get([[(function()
        local ns = vim.api.nvim_create_namespace('iter.diff')
        local buf = ]] .. R .. [[.view.buf
        local parts = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, 0, { details = true })) do
            if mark[4].virt_text_pos == 'right_align' then
                for _, chunk in ipairs(mark[4].virt_text) do
                    table.insert(parts, chunk[1])
                end
            end
        end
        return table.concat(parts)
    end)()]])

    eq(header:find('conflicted', 1, true) ~= nil, true)
end

return T
