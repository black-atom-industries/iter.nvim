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

--- Open a chrome float as `_G.over` and a picker of `one`, `two`, `three`
--- over it as `_G.picker`; `_G.picked` and `_G.closed` record the callbacks.
local function open_picker()
    child.lua([[
        local float = require('iter.ui.float')
        local buf = vim.api.nvim_create_buf(false, true)
        _G.over = float.open({
            pane = vim.api.nvim_get_current_win(),
            buf = buf,
            zindex = 40,
            height = 0.3,
            chrome = true,
        })
        _G.picked = nil
        _G.closed = 0
        _G.picker = require('iter.ui.picker').open({
            over = _G.over,
            title = 'Pick',
            items = { 'one', 'two', 'three' },
            keys = require('iter.config').resolve({}).keys.picker,
            on_pick = function(index)
                _G.picked = index
            end,
            on_close = function()
                _G.closed = _G.closed + 1
            end,
        })
    ]])
end

T['open()'] = new_set()

T['open()']['covers the float it opens over and takes the focus'] = function()
    open_picker()

    local win = child.lua_get('_G.picker.float.win')

    eq(child.api.nvim_get_current_win(), win)
    eq(
        child.api.nvim_win_get_position(win),
        child.lua_get('vim.api.nvim_win_get_position(_G.over.win)')
    )
    eq(
        child.api.nvim_buf_get_lines(
            child.lua_get('_G.picker.buf'),
            0,
            -1,
            false
        ),
        { ' one', ' two', ' three' }
    )
end

T['open()']['<CR> passes the index under the cursor'] = function()
    open_picker()
    child.type_keys('j', '<CR>')

    eq(child.lua_get('_G.picked'), 2)
    eq(child.lua_get('_G.closed'), 1)
    eq(child.lua_get('_G.picker:is_open()'), false)
end

T['open()']['/ moves to a match'] = function()
    open_picker()
    child.type_keys('/thr', '<CR>', '<CR>')

    eq(child.lua_get('_G.picked'), 3)
end

T['open()']['q and <Esc> close without picking'] = function()
    for _, key in ipairs({ 'q', '<Esc>' }) do
        open_picker()
        child.type_keys(key)

        eq(child.lua_get('_G.picker:is_open()'), false)
        eq(child.lua_get('_G.picked'), vim.NIL)
        eq(child.lua_get('_G.closed'), 1)
    end
end

T['open()']['leaving the window closes it without on_close'] = function()
    open_picker()
    child.lua('vim.api.nvim_set_current_win(_G.over.pane)')
    helpers.wait_until(child, 'not _G.picker:is_open()')

    eq(child.lua_get('_G.closed'), 0)
    eq(child.lua_get('_G.picked'), vim.NIL)
end

return T
