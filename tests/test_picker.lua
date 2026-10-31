local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            helpers.start_child(child, repo, { lines = 24, columns = 80 })
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

--- Open a panel as `_G.panel` showing a base list of `one`, `two` under
--- `Branches` and `three` under `Commits` as `_G.page`; `_G.picked` and
--- `_G.closed` record the callbacks.
local function open_page()
    child.lua([[
        _G.picked = nil
        _G.closed = 0
        _G.panel = require('iter.ui.panel').open({ width = 34 })
        _G.page = require('iter.ui.picker').page({
            title = 'Base of the review',
            items = {
                { label = 'one', tag = 'parent' },
                { label = 'two' },
                {
                    label = function(width)
                        return { { 'abc', 'IterCommitSha' }, { ' ' .. ('x'):rep(width - 4) } }
                    end,
                },
            },
            sections = { [2] = 'Branches', [3] = 'Commits' },
            keys = require('iter.config').resolve({}).keys.picker,
            on_pick = function(index)
                _G.picked = index
            end,
            on_close = function()
                _G.closed = _G.closed + 1
            end,
        })
        _G.panel:show(_G.page)
        _G.panel:focus()
    ]])
end

---@return string[]
local function lines()
    return vim.tbl_map(
        function(line)
            return (line:gsub('%s+$', ''))
        end,
        child.api.nvim_buf_get_lines(child.lua_get('_G.page.buf'), 0, -1, false)
    )
end

T['page()'] = new_set()

T['page()']['lays out the title, the items under their sections and the hints'] = function()
    open_page()

    local shown = lines()

    eq(vim.list_slice(shown, 1, 9), {
        ' Base of the review',
        ' / search',
        '',
        '  one                      parent',
        '',
        ' Branches',
        '  two',
        '',
        ' Commits',
    })
    eq(shown[10], '  abc ' .. ('x'):rep(28))
    eq(vim.list_slice(shown, #shown - 1), {
        ' <CR> pick  / search',
        ' q back to the tree',
    })
    eq(#shown, child.api.nvim_win_get_height(child.lua_get('_G.panel.win')))
end

T['page()']['maps item lines to indexes, the cursor snaps to items'] = function()
    open_page()

    eq(
        child.lua_get(
            '{ _G.page.indexes[4], _G.page.indexes[7], _G.page.indexes[10] }'
        ),
        { 1, 2, 3 }
    )
    eq(child.lua_get('vim.tbl_count(_G.page.indexes)'), 3)
    eq(child.api.nvim_win_get_cursor(0)[1], 4)
    eq(child.lua_get('_G.page:index()'), 1)

    child.type_keys('j')
    eq(child.api.nvim_win_get_cursor(0)[1], 7)
    child.type_keys('j')
    eq(child.api.nvim_win_get_cursor(0)[1], 10)
    child.type_keys('k')
    eq(child.api.nvim_win_get_cursor(0)[1], 7)
    eq(child.lua_get('_G.page:line_of(3)'), 10)
end

T['page()']['<CR> passes the index under the cursor'] = function()
    open_page()
    child.type_keys('j', '<CR>')

    eq(child.lua_get('_G.picked'), 2)
    eq(child.lua_get('_G.closed'), 0)
end

T['page()']['/ moves to a match'] = function()
    open_page()
    child.type_keys('/two', '<CR>', '<CR>')

    eq(child.lua_get('_G.picked'), 2)
end

T['page()']['q and <Esc> call on_close without picking'] = function()
    open_page()
    child.type_keys('q', '<Esc>')

    eq(child.lua_get('_G.picked'), vim.NIL)
    eq(child.lua_get('_G.closed'), 2)
end

T['page()']['rejects a missing on_close'] = function()
    local ok = child.lua_get([[pcall(require('iter.ui.picker').page, {
        title = 't',
        items = {},
        keys = {},
        on_pick = function() end,
    })]])

    eq(ok, false)
end

return T
