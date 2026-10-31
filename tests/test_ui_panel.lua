local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local P = '_G.panel'

--- In the child: `_G.page(name, count)` makes a page of a title line, a
--- blank line and `count` items whose `on_cursor` snaps to the nearest item
--- in the direction of the move, and `_G.open(width)` opens `_G.panel`.
local function define()
    child.lua([[
        _G.closed = 0

        function _G.page(name, count)
            local buf = vim.api.nvim_create_buf(false, true)
            local page = { buf = buf, items = {}, renders = {} }

            function page.render(_, width, height)
                table.insert(page.renders, { width, height })

                local lines = { ' ' .. name, '' }

                page.items = {}

                for i = 1, count do
                    table.insert(lines, '   item ' .. i)
                    page.items[#lines] = i
                end

                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            end

            function page.on_cursor(_, lnum, prev)
                if page.items[lnum] ~= nil then
                    return
                end

                local step = lnum < prev and -1 or 1
                local last = vim.api.nvim_buf_line_count(buf)

                for _, dir in ipairs({ step, -step }) do
                    local at = lnum + dir

                    while at >= 1 and at <= last do
                        if page.items[at] ~= nil then
                            vim.api.nvim_win_set_cursor(0, { at, 0 })
                            return
                        end

                        at = at + dir
                    end
                end
            end

            return page
        end

        function _G.open(width)
            _G.panel = require('iter.ui.panel').open({
                width = width,
                on_close = function()
                    _G.closed = _G.closed + 1
                end,
            })

            return _G.panel
        end
    ]])
end

---@param columns integer
local function start(columns)
    helpers.start_child(child, repo, { columns = columns })
    child.lua([[require('iter').setup()]])
    child.cmd('edit a.txt')
    define()
end

---@return integer
local function cursor_line()
    return child.lua_get('vim.api.nvim_win_get_cursor(' .. P .. '.win)[1]')
end

--- The line the `▸` marker is on in `buf`, nil without one.
---@param buf string Lua expression of the buffer
---@return integer?
local function marker(buf)
    local line = child.lua_get([[(function(buf)
            local ns = vim.api.nvim_get_namespaces()['iter.panel.cursor']
            local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
            return marks[1] and marks[1][2] + 1 or false
        end)(]] .. buf .. ')')

    return line ~= false and line or nil
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({
                ['a.txt'] = { 'first', 'second', 'third' },
            })
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['window'] = new_set({
    parametrize = { { 80 }, { 200 } },
})

T['window']['opens at the left edge, full height, keeping the focus'] = function(
    columns
)
    start(columns)
    child.cmd('split')

    local origin = child.api.nvim_get_current_win()

    child.lua('_G.open(34)')

    local win = child.lua_get(P .. '.win')

    eq(child.fn.win_screenpos(win), { 1, 1 })
    eq(child.api.nvim_win_get_width(win), 34)
    eq(child.api.nvim_win_get_height(win), 23)
    eq(child.api.nvim_get_current_win(), origin)
end

T['window']['keeps its width through <C-w>='] = function(columns)
    start(columns)
    child.lua('_G.open(34)')
    child.cmd('vsplit')
    child.type_keys('<C-w>=')

    eq(child.lua_get(P .. ':width()'), 34)
end

T['options'] = new_set()

T['options']['the window has the list window options'] = function()
    start(80)
    child.cmd('setlocal number signcolumn=yes')
    child.lua('_G.open(34)')
    child.lua(P .. ':show(_G.page("A", 3))')

    local wo = child.lua_get([[(function(win)
        local o = vim.wo[win]
        return {
            o.number, o.signcolumn, o.wrap, o.cursorline, o.winfixwidth,
            o.winhighlight:match('CursorLine:IterDrawerSelected') ~= nil,
        }
    end)(]] .. P .. '.win)')

    eq(wo, { false, 'no', false, true, true, true })
end

T['options']['the window starts with an empty jumplist'] = function()
    start(80)
    child.type_keys('G', 'gg')
    child.lua('_G.open(34)')

    eq(child.lua_get('#vim.fn.getjumplist(' .. P .. '.win)[1]'), 0)
end

T['pages'] = new_set()

T['pages']['show swaps pages and gives each its cursor back'] = function()
    start(80)
    child.lua([[
        _G.a, _G.b = _G.page('A', 5), _G.page('B', 2)
        _G.open(34):show(_G.a)
    ]])
    child.lua(P .. ':focus()')
    child.type_keys('jj')
    eq(cursor_line(), 5)

    child.lua(P .. ':show(_G.b)')
    eq(
        child.lua_get('vim.api.nvim_win_get_buf(' .. P .. '.win) == _G.b.buf'),
        true
    )
    eq(cursor_line(), 3)
    child.type_keys('j')

    child.lua(P .. ':show(_G.a)')
    eq(cursor_line(), 5)
    eq(marker('_G.a.buf'), 5)
    eq(marker('_G.b.buf'), nil)

    child.lua(P .. ':show(_G.b)')
    eq(cursor_line(), 4)
end

T['pages']['on_cursor snaps the cursor onto an item'] = function()
    start(80)
    child.lua('_G.open(34):show(_G.page("A", 3))')

    -- A new page's cursor starts on the title and snaps down.
    eq(cursor_line(), 3)

    child.lua(P .. ':focus()')
    child.type_keys('k')
    eq(cursor_line(), 3)

    child.type_keys('G')
    eq(cursor_line(), 5)
    child.type_keys('gg')
    eq(cursor_line(), 3)
end

T['pages']['the marker follows j and k'] = function()
    start(80)
    child.lua('_G.a = _G.page("A", 4); _G.open(34):show(_G.a)')
    eq(marker('_G.a.buf'), 3)

    child.lua(P .. ':focus()')
    child.type_keys('j')
    eq(marker('_G.a.buf'), 4)
    child.type_keys('j', 'j')
    eq(marker('_G.a.buf'), 6)
    child.type_keys('k')
    eq(marker('_G.a.buf'), 5)
end

T['pages']['a resize renders at the new size'] = function()
    start(80)
    child.lua('_G.a = _G.page("A", 2); _G.open(34):show(_G.a)')

    child.lua(P .. ':focus()')
    child.cmd('vertical resize 40')
    helpers.wait_until(child, '_G.a.renders[#_G.a.renders][1] == 40')

    child.o.lines = 30
    helpers.wait_until(child, '_G.a.renders[#_G.a.renders][2] == 29')
    eq(child.lua_get('_G.a.renders[#_G.a.renders]'), { 40, 29 })
end

T['pages']['a buffer put into the window leaves the page alone'] = function()
    start(80)
    child.lua([[
        _G.a = _G.page('A', 1)
        _G.calls = 0
        local on_cursor = _G.a.on_cursor
        _G.a.on_cursor = function(...)
            _G.calls = _G.calls + 1
            return on_cursor(...)
        end
        _G.open(34):show(_G.a)
    ]])
    eq(child.lua_get('_G.calls'), 1)

    child.lua(P .. ':focus()')
    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { '1', '2', '3', '4', '5' })
    child.type_keys('G', 'k', 'j')
    child.o.lines = 30
    child.lua(P .. ':render()')

    eq(child.lua_get('_G.calls'), 1)
    eq(marker('_G.a.buf'), nil)
    eq(child.cmd_capture('messages'), '')

    child.lua(P .. ':show(_G.a)')
    eq(
        child.lua_get('vim.api.nvim_win_get_buf(' .. P .. '.win) == _G.a.buf'),
        true
    )
    eq(cursor_line(), 3)
    eq(marker('_G.a.buf'), 3)
end

T['pages']['set_cursor moves the marker while unfocused'] = function()
    start(80)
    child.lua('_G.a = _G.page("A", 4); _G.open(34):show(_G.a)')
    child.lua(P .. ':set_cursor(5)')

    eq(cursor_line(), 5)
    eq(marker('_G.a.buf'), 5)

    -- A title line snaps like a user's move onto it.
    child.lua(P .. ':set_cursor(2)')
    eq(cursor_line(), 3)
    eq(marker('_G.a.buf'), 3)
    eq(child.api.nvim_get_current_win() ~= child.lua_get(P .. '.win'), true)
end

T['pages']['a render with fewer lines keeps the marker on the cursor'] = function()
    start(80)
    child.lua([[
        _G.a = _G.page('A', 5)
        _G.open(34):show(_G.a)
    ]])
    child.lua(P .. ':set_cursor(7)')
    child.lua([[
        local render = _G.a.render
        _G.a.render = function(page, width, height)
            render(page, width, height)
            vim.api.nvim_buf_set_lines(_G.a.buf, 4, -1, false, {})
        end
    ]])
    child.lua(P .. ':render()')

    eq(cursor_line(), 4)
    eq(marker('_G.a.buf'), 4)
end

T['close'] = new_set()

T['close']['closing the window calls on_close'] = function()
    start(80)
    child.lua('_G.open(34):show(_G.page("A", 1))')
    child.lua(P .. ':focus()')
    child.cmd('close')

    helpers.wait_until(child, '_G.closed == 1')
    eq(child.lua_get(P .. ':is_open()'), false)
end

T['screenshot'] = function()
    start(80)
    child.lua('_G.open(34):show(_G.page("Page title", 4))')
    child.lua(P .. ':focus()')
    child.type_keys('j')

    helpers.expect_screenshot(child, 'panel-page')
end

return T
