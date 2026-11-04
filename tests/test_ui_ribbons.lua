local helpers = dofile('tests/helpers.lua')
local H = dofile('tests/helpers_review.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = H.R
local V = R .. '.view'

--- `f.lua`: a changed line, a deleted line, two added lines, far enough apart
--- to be chunks of their own.
---@return string
local function create_repo()
    local lines = {}

    for i = 1, 60 do
        lines[i] = 'local v = ' .. i
    end

    local path = helpers.create_repo({ ['f.lua'] = lines })
    local new = vim.deepcopy(lines)

    new[3] = 'local v = 3 + 0'
    table.insert(new, 9, 'local w = 1')
    table.insert(new, 10, 'local w = 2')
    table.remove(new, 5)
    helpers.write_file(vim.fs.joinpath(path, 'f.lua'), new)

    return path
end

--- Make the child believe a terminal with images is attached: its writes to
--- the terminal land in `_G.sent`.
local function terminal_with_images()
    child.lua([[
        _G.sent = {}
        _G.notes = {}
        vim.env.TMUX = nil
        vim.o.termguicolors = true
        vim.notify = function(msg) table.insert(_G.notes, msg) end
        vim.api.nvim_ui_send = function(bytes)
            table.insert(_G.sent, bytes)
        end
        vim.api.nvim_list_uis = function()
            return { { stdout_tty = true } }
        end
        local graphics = require('iter.graphics')
        graphics.probe()
        for _, sequence in ipairs({
            '\27_Gi=' .. 0x1A0000 .. ';OK\27\\',
            '\27[?62;22c',
        }) do
            vim.api.nvim_exec_autocmds('TermResponse', {
                data = { sequence = sequence },
            })
        end
    ]])
    helpers.wait_until(child, [[require('iter.graphics').on()]])
end

local function open_split()
    H.open(child)
    helpers.wait_until(child, V .. ':is_shown()')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('|')
    helpers.wait_until(child, V .. '.old ~= nil')
end

---@return integer
local function images_sent()
    return child.lua_get([[(function()
        local count = 0
        for _, bytes in ipairs(_G.sent) do
            if bytes:find('a=T', 1, true) then
                count = count + 1
            end
        end
        return count
    end)()]])
end

---@param text string
---@return integer
local function line_of(text)
    return child.lua_get([[(function(text)
            local lines = vim.api.nvim_buf_get_lines(]] .. V .. [[.buf, 0, -1, false)
            for lnum, line in ipairs(lines) do
                if line == text then
                    return lnum
                end
            end
        end)(...)]], { text })
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_repo()
            helpers.start_child(child, repo, { lines = 30, columns = 120 })
            child.lua(
                [[require('iter').config = require('iter.config').resolve({ status = { style = 'drawer' } })]]
            )
            terminal_with_images()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['gutter'] = new_set()

T['gutter']['covers the separator and four rail cells'] = function()
    open_split()

    local config = child.lua_get(
        'vim.api.nvim_win_get_config(' .. V .. '.gutter.canvas.win)'
    )
    local height = child.lua_get('vim.api.nvim_win_get_height(' .. V .. '.win)')

    eq(config.relative, 'win')
    eq(config.width, 5)
    eq(config.col, -1)
    eq(config.height, height)
    eq(config.focusable, false)
    eq(config.zindex, 1)
end

T['gutter']['the float does not follow the binds'] = function()
    open_split()

    local win = V .. '.gutter.canvas.win'

    eq(child.lua_get('vim.wo[' .. win .. '].scrollbind'), false)
    eq(child.lua_get('vim.wo[' .. win .. '].cursorbind'), false)
    eq(child.lua_get('vim.wo[' .. V .. '.win].scrollbind'), true)
    child.type_keys('<C-f>')
    eq(child.lua_get([[vim.fn.line('w0', ]] .. win .. ')'), 1)
end

T['gutter']['the new side gives its rail four cells'] = function()
    open_split()

    local old =
        child.lua_get('vim.fn.getwininfo(' .. V .. '.old.win)[1].textoff')
    local new = child.lua_get('vim.fn.getwininfo(' .. V .. '.win)[1].textoff')

    eq(new - old, 4)
end

T['gutter']['leaves both sides the same width of text'] = function()
    open_split()

    local widths = child.lua_get(
        '{ ' .. V .. ':text_width(' .. V .. '.old), ' .. V .. ':text_width() }'
    )

    eq(math.abs(widths[1] - widths[2]) <= 1, true)
end

T['gutter']['filler rows are blank'] = function()
    open_split()

    local marks = child.lua_get([[(function()
        local v = ]] .. V .. [[
        local count = 0
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
            v.old.buf, -1, 0, -1, { details = true }
        )) do
            local text = mark[4].virt_text and mark[4].virt_text[1][1] or ''
            if text:find('╱', 1, true) then
                count = count + 1
            end
        end
        return count
    end)()]])

    eq(marks, 0)
end

T['gutter']['stays under the other floats'] = function()
    open_split()
    child.type_keys('?')

    local zindex = child.lua_get([[(function()
        local top = 0
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            top = math.max(top, vim.api.nvim_win_get_config(win).zindex or 0)
        end
        return top
    end)()]])

    eq(zindex > 1, true)
end

T['gutter']['follows the height of its window'] = function()
    open_split()

    child.lua('vim.o.lines = 20')
    helpers.wait_until(
        child,
        'vim.api.nvim_win_get_height('
            .. V
            .. '.gutter.canvas.win) == vim.api.nvim_win_get_height('
            .. V
            .. '.win)'
    )

    local lines = child.lua_get(
        'vim.api.nvim_buf_line_count(' .. V .. '.gutter.canvas.buf)'
    )

    eq(lines, child.lua_get('vim.api.nvim_win_get_height(' .. V .. '.win)'))
end

T['gutter']['closes with the split and frees the image'] = function()
    open_split()

    local win = child.lua_get(V .. '.gutter.canvas.win')
    local id = child.lua_get(V .. '.gutter.canvas.id')

    child.type_keys('-')
    helpers.wait_until(child, V .. '.old == nil')

    eq(child.lua_get('vim.api.nvim_win_is_valid(' .. win .. ')'), false)
    eq(child.lua_get(V .. '.gutter == nil'), true)
    eq(
        child.lua_get(
            [[_G.sent[#_G.sent]:find('a=d,d=I,i=]]
                .. id
                .. [[', 1, true) ~= nil]]
        ),
        true
    )
end

T['gutter']['closes with the review'] = function()
    open_split()

    local win = child.lua_get(V .. '.gutter.canvas.win')

    child.type_keys('q')
    helpers.wait_until(child, R .. ' == nil')
    eq(child.lua_get('vim.api.nvim_win_is_valid(' .. win .. ')'), false)
end

T['gutter']['leaves the status sidebar a tab it can restore'] = function()
    child.lua(
        [[require('iter').config = require('iter.config').resolve({ status = { style = 'sidebar' } })]]
    )

    local before = child.lua_get('vim.api.nvim_tabpage_list_wins(0)')
    local sizes = child.fn.winrestcmd()

    child.cmd('Iter status')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil]]
            .. [[ and require('iter').drawer.preview.view ~= nil]]
            .. [[ and require('iter').drawer.preview.view:is_shown()]]
    )
    child.lua([[require('iter').drawer.preview.view:set_layout('split')]])
    helpers.wait_until(
        child,
        [[require('iter').drawer.preview.view.gutter ~= nil]]
    )
    child.lua([[require('iter').drawer:close()]])

    eq(child.lua_get('vim.api.nvim_tabpage_list_wins(0)'), before)
    eq(child.fn.winrestcmd(), sizes)
end

T['image'] = new_set()

T['image']['is sent once for one picture'] = function()
    open_split()

    local sent = images_sent()

    eq(sent >= 1, true)
    child.lua(V .. ':draw_gutter()')
    eq(images_sent(), sent)
end

T['image']['is sent again when the view scrolls past a change'] = function()
    open_split()

    local sent = images_sent()

    child.type_keys('<C-e>')
    helpers.wait_until(child, 'vim.fn.line("w0", ' .. V .. '.win) == 2')
    eq(images_sent() > sent, true)
end

--- Put the cursor on `lnum` of the new side.
---@param lnum integer
local function cursor_to(lnum)
    child.lua(
        'vim.api.nvim_win_set_cursor(' .. V .. '.win, { ' .. lnum .. ', 0 })'
    )
    child.lua(V .. ':sync(' .. V .. ')')
    child.cmd('redraw')
end

--- The screen attribute past the end of `lnum`'s text in the new side.
---@param lnum integer
---@return string
local function attr_past_text(lnum)
    local position = child.lua_get([[(function(lnum)
            local win = ]] .. V .. [[.win
            return {
                row = vim.fn.screenpos(win, lnum, 1).row,
                edge = vim.api.nvim_win_get_position(win)[2]
                    + vim.api.nvim_win_get_width(win),
            }
        end)(...)]], { lnum })

    return child.get_screenshot().attr[position.row][position.edge]
end

T['active chunk'] = new_set()

T['active chunk']['follows the cursor into a chunk and out'] = function()
    open_split()

    local added = line_of('local w = 1')

    cursor_to(added)

    local chunk = V .. '.gutter.active'

    eq(child.lua_get(chunk .. '.new_first'), added)
    eq(child.lua_get(chunk .. '.new_last'), added + 1)

    cursor_to(line_of('local v = 1'))
    eq(child.lua_get(chunk .. ' == nil'), true)
end

T['active chunk']['tints its rows and its rail, then lets go'] = function()
    open_split()

    local added = line_of('local w = 1')
    local other = added + 1

    child.o.cursorline = false
    cursor_to(line_of('local v = 1'))

    local plain = attr_past_text(other)

    cursor_to(added)

    if attr_past_text(other) == plain then
        error('the other row of the chunk under the cursor keeps its tint')
    end

    local highlights = child.lua_get([[(function(lnum)
            local win = ]] .. V .. [[.win
            return vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, {
                winid = win,
                use_statuscol_lnum = lnum,
                highlights = true,
            }).highlights
        end)(...)]], { other })

    eq(highlights[#highlights].group, 'IterDiffAddCursor')

    cursor_to(line_of('local v = 1'))
    eq(attr_past_text(other), plain)
end

T['active chunk']['survives a redraw of the view'] = function()
    open_split()

    local added = line_of('local w = 1')

    cursor_to(added)

    local tinted = attr_past_text(added + 1)

    child.lua(V .. ':show_document(' .. V .. '.document)')
    child.cmd('redraw')
    eq(attr_past_text(added + 1), tinted)
end

T['screen rows'] = new_set()

T['screen rows']['an annotation moves the chunks below it'] = function()
    open_split()

    local context = line_of('local v = 1')
    local added = line_of('local w = 1')

    child.lua(
        [[
        local lnum = ...
        local v = require('iter').current_review.view
        for _, pane in ipairs(v:panes()) do
            vim.api.nvim_buf_set_extmark(pane.buf, vim.api.nvim_create_namespace('t'),
                lnum - 1, 0, { virt_lines = { { { 'a', 'Normal' } }, { { 'b', 'Normal' } } } })
        end
        v:draw_gutter()
    ]],
        { context }
    )
    child.cmd('redraw')

    local shape_row = child.lua_get([[(function(added)
            local v = ]] .. V .. [[
            local win = v.win
            local top = vim.fn.line('w0', win)
            local position = vim.fn.screenpos(win, added, 1)
            local origin = vim.api.nvim_win_get_position(win)[1]
            return {
                screen = position.row - origin - 1,
                text = vim.api.nvim_win_text_height(win, {
                    start_row = top - 1,
                    end_row = added - 2,
                }).all,
            }
        end)(...)]], { added })

    eq(shape_row.text, shape_row.screen)
end

T['fallback'] = new_set()

T['fallback']['a rejected image brings the fillers back'] = function()
    open_split()

    local win = child.lua_get(V .. '.gutter.canvas.win')
    local id = child.lua_get(V .. '.gutter.canvas.id')

    child.lua(
        [[vim.api.nvim_exec_autocmds('TermResponse', {
            data = { sequence = ... },
        })]],
        { '\27_Gi=' .. id .. ';ENOMEM:no room\27\\' }
    )
    helpers.wait_until(child, V .. '.gutter == nil')

    eq(child.lua_get('vim.api.nvim_win_is_valid(' .. win .. ')'), false)
    eq(child.lua_get(V .. '.old ~= nil'), true)
    eq(child.lua_get([[_G.notes[1]:find('rejected', 1, true) ~= nil]]), true)
    eq(
        child.lua_get('vim.fn.getwininfo(' .. V .. '.win)[1].textoff')
            - child.lua_get('vim.fn.getwininfo(' .. V .. '.old.win)[1].textoff'),
        0
    )
end

T['fallback']['a UI that cannot be asked closes the gutter'] = function()
    open_split()

    local win = child.lua_get(V .. '.gutter.canvas.win')

    child.lua([[
        vim.api.nvim_list_uis = function()
            return {}
        end
        vim.api.nvim_exec_autocmds('UIEnter', {})
    ]])
    helpers.wait_until(child, V .. '.gutter == nil')

    eq(child.lua_get('vim.api.nvim_win_is_valid(' .. win .. ')'), false)
    eq(child.lua_get(V .. '.old ~= nil'), true)
end

return T
