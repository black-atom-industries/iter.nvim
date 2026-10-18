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

--- Split the screen into a left pane and a right window, open a float on the
--- left pane as `_G.float` and keep its id in `_G.pane`.
---@param opts? string Lua table body merged into the open() options
local function open_float(opts)
    child.lua(string.format(
        [[
        vim.cmd('vsplit')
        _G.pane = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_create_buf(false, true)
        local lines = {}
        for i = 1, 20 do
            lines[i] = 'DRAWER'
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        _G.float = require('iter.ui.float').open(vim.tbl_extend('force', {
            pane = _G.pane,
            buf = buf,
            zindex = 45,
            height = 0.3,
        }, { %s }))
    ]],
        opts or ''
    ))
    child.cmd('redraw')
end

--- Screen row just below the last text row of `win`.
---@param win string Lua expression for the window id
---@return integer
local function bottom_of(win)
    return child.lua_get(string.format(
        [[(function()
            local w = %s
            return vim.api.nvim_win_get_position(w)[1]
                + vim.api.nvim_win_get_height(w)
        end)()]],
        win
    ))
end

T['open()'] = new_set()

T['open()']['anchors the float to the bottom of its pane'] = function()
    open_float()

    local config = child.lua_get('vim.api.nvim_win_get_config(_G.float.win)')
    eq(config.relative, 'win')
    eq(config.win, child.lua_get('_G.pane'))
    eq(config.anchor, 'SW')
    eq(config.zindex, 45)
    eq(config.focusable, true)
    eq(config.width, child.lua_get('vim.api.nvim_win_get_width(_G.pane)'))

    local pane_height = child.lua_get('vim.api.nvim_win_get_height(_G.pane)')
    eq(config.height, math.floor(pane_height * 0.3))

    local pane_bottom = bottom_of('_G.pane')
    local float_bottom = bottom_of('_G.float.win')
    eq(float_bottom, pane_bottom)
    eq(child.lua_get('_G.float:is_open()'), true)
end

T['open()']['takes a height in lines and caps it to the pane'] = function()
    open_float('height = 5')
    eq(child.lua_get('vim.api.nvim_win_get_height(_G.float.win)'), 5)

    child.lua('_G.float:reposition({ height = 500 })')
    eq(
        child.lua_get('vim.api.nvim_win_get_height(_G.float.win)'),
        child.lua_get('vim.api.nvim_win_get_height(_G.pane)')
    )
end

T['open()']['enters the float only when asked'] = function()
    open_float()
    eq(child.lua_get('vim.api.nvim_get_current_win() == _G.pane'), true)

    child.lua('_G.float:close()')
    open_float('enter = true')
    eq(child.lua_get('vim.api.nvim_get_current_win() == _G.float.win'), true)
end

T['reposition()'] = new_set()

T['reposition()']['follows pane resizes'] = function()
    open_float()

    child.cmd('vertical resize 20')
    child.cmd('redraw')
    helpers.wait_until(child, 'vim.api.nvim_win_get_width(_G.float.win) == 20')
    eq(bottom_of('_G.float.win'), bottom_of('_G.pane'))

    child.cmd('resize 10')
    child.cmd('redraw')
    helpers.wait_until(child, 'vim.api.nvim_win_get_height(_G.float.win) == 3')
    eq(bottom_of('_G.float.win'), bottom_of('_G.pane'))
end

T['reposition()']['follows a terminal resize'] = function()
    open_float()

    child.o.lines = 40
    child.o.columns = 100
    child.cmd('redraw')
    helpers.wait_until(
        child,
        'vim.api.nvim_win_get_width(_G.float.win) == vim.api.nvim_win_get_width(_G.pane)'
    )
    child.cmd('redraw')
    eq(bottom_of('_G.float.win'), bottom_of('_G.pane'))
end

T['close()'] = new_set()

T['close()']['closes the float and stops following'] = function()
    open_float()
    child.lua('_G.win = _G.float.win; _G.float:close()')

    eq(child.lua_get('vim.api.nvim_win_is_valid(_G.win)'), false)
    eq(child.lua_get('_G.float:is_open()'), false)
    child.lua('_G.float:close()')
    eq(child.v.errmsg, '')
end

T['close()']['happens when the pane closes'] = function()
    open_float()
    child.lua('_G.win = _G.float.win')
    child.lua('vim.api.nvim_win_close(_G.pane, true)')

    eq(child.lua_get('vim.api.nvim_win_is_valid(_G.win)'), false)
    eq(child.lua_get('_G.float:is_open()'), false)
end

T['zindex'] = new_set()

T['zindex']['draws above a float with a lower zindex'] = function()
    child.lua([[
        vim.cmd('vsplit')
        _G.pane = vim.api.nvim_get_current_win()
        local low = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(low, 0, -1, false, vim.fn['repeat']({ 'XXXXXXXXXXXXXXXXXXXXXXXX' }, 30))
        vim.api.nvim_open_win(low, false, {
            relative = 'editor', row = 0, col = 0,
            width = 30, height = 22, zindex = 20,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn['repeat']({ 'DRAWER' }, 20))
        _G.float = require('iter.ui.float').open({
            pane = _G.pane, buf = buf, zindex = 40, height = 0.5,
        })
    ]])
    child.cmd('redraw')

    local rows = vim.tbl_map(function(cells)
        return table.concat(cells)
    end, child.get_screenshot().text)
    local drawer_rows = 0

    for _, row in ipairs(rows) do
        if row:find('DRAWER', 1, true) then
            drawer_rows = drawer_rows + 1
            eq(row:sub(1, 40):find('X', 1, true), nil)
        end
    end

    eq(drawer_rows > 0, true)
end

return T
