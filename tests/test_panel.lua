-- The error cases pass wrongly typed options and pages on purpose.
---@diagnostic disable: assign-type-mismatch, missing-fields
local panel = require('iter.ui.panel')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type IterPanel?
local opened

--- A page of a title line, a blank line and `count` item lines that
--- records every render.
---@param count integer
---@return table
local function page(count)
    local buf = vim.api.nvim_create_buf(false, true)
    local self = { buf = buf, renders = {} }

    function self.render(_, width, height)
        table.insert(self.renders, { width, height })

        local lines = { ' Title', '' }

        for i = 1, count do
            table.insert(lines, '   item ' .. i)
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    return self
end

---@param opts? table
---@return IterPanel
local function open(opts)
    opened = panel.open(vim.tbl_extend('force', { width = 30 }, opts or {}))

    return opened
end

local T = new_set({
    hooks = {
        post_case = function()
            if opened ~= nil then
                opened:close()
                opened = nil
            end
        end,
    },
})

T['open'] = new_set()

T['open']['opens a window of the given width and keeps the focus'] = function()
    local origin = vim.api.nvim_get_current_win()
    local p = open({ width = 25 })

    eq(p:is_open(), true)
    eq(p:width(), 25)
    eq(p:height(), vim.api.nvim_win_get_height(origin))
    eq(vim.api.nvim_get_current_win(), origin)
    eq(p.page, nil)
end

T['open']['validates its options'] = function()
    eq(pcall(panel.open, { width = 'wide' }), false)
    eq(pcall(panel.open, { width = 30, on_close = true }), false)
end

T['show'] = new_set()

T['show']['renders the page for the window size'] = function()
    local p = open({ width = 28 })
    local a = page(3)

    p:show(a)

    eq(p.page, a)
    eq(vim.api.nvim_win_get_buf(p.win), a.buf)
    eq(a.renders, { { 28, p:height() } })
    eq(vim.api.nvim_buf_get_lines(a.buf, 0, 1, false), { ' Title' })
end

T['show']['gives each page back the cursor it had'] = function()
    local p = open()
    local a, b = page(5), page(2)

    p:show(a)
    vim.api.nvim_win_set_cursor(p.win, { 6, 0 })
    p:show(b)
    eq(vim.api.nvim_win_get_cursor(p.win), { 1, 0 })

    vim.api.nvim_win_set_cursor(p.win, { 4, 0 })
    p:show(a)
    eq(vim.api.nvim_win_get_cursor(p.win), { 6, 0 })

    p:show(b)
    eq(vim.api.nvim_win_get_cursor(p.win), { 4, 0 })
end

T['show']['clamps a cursor past the lines the page has now'] = function()
    local p = open()
    local a, b = page(5), page(1)
    local count = 5

    function a.render()
        local lines = { ' Title', '' }

        for i = 1, count do
            table.insert(lines, '   item ' .. i)
        end

        vim.api.nvim_buf_set_lines(a.buf, 0, -1, false, lines)
    end

    p:show(a)
    vim.api.nvim_win_set_cursor(p.win, { 7, 0 })
    p:show(b)
    count = 2
    p:show(a)

    eq(vim.api.nvim_win_get_cursor(p.win), { 4, 0 })
end

T['show']['tells the page where the cursor is'] = function()
    local p = open()
    local a = page(3)
    local seen = {}

    function a.on_cursor(_, lnum, prev)
        table.insert(seen, { lnum, prev })
        vim.api.nvim_win_set_cursor(p.win, { 3, 0 })
    end

    p:show(a)

    eq(seen, { { 1, 1 } })
    eq(vim.api.nvim_win_get_cursor(p.win), { 3, 0 })
end

T['show']['rejects a page without a buffer or render'] = function()
    local p = open()

    eq(pcall(p.show, p, { render = function() end }), false)
    eq(pcall(p.show, p, { buf = vim.api.nvim_create_buf(false, true) }), false)
end

T['render'] = new_set()

T['render']['renders the shown page again'] = function()
    local p = open({ width = 30 })
    local a = page(1)

    p:render()
    p:show(a)
    p:render()

    eq(#a.renders, 2)
end

T['set_cursor'] = new_set()

T['set_cursor']['moves the cursor while another window has the focus'] = function()
    local origin = vim.api.nvim_get_current_win()
    local p = open()
    local a = page(4)
    local seen = {}

    function a.on_cursor(_, lnum, prev)
        table.insert(seen, { lnum, prev, vim.api.nvim_get_current_win() })
    end

    p:show(a)
    p:set_cursor(5)
    p:set_cursor(5)
    p:set_cursor(99)

    eq(vim.api.nvim_get_current_win(), origin)
    eq(vim.api.nvim_win_get_cursor(p.win), { 6, 0 })
    eq(seen, { { 1, 1, p.win }, { 5, 1, p.win }, { 6, 5, p.win } })
    eq(p.lnum, 6)
end

T['set_cursor']['gives the cursor to the page when it shows again'] = function()
    local p = open()
    local a, b = page(4), page(1)

    p:show(a)
    p:set_cursor(4)
    p:show(b)
    p:show(a)

    eq(vim.api.nvim_win_get_cursor(p.win), { 4, 0 })
end

T['render']['a cursor the new lines moved reaches on_cursor'] = function()
    local p = open()
    local a = page(5)
    local seen = {}
    local count = 5

    function a.render()
        local lines = { ' Title', '' }

        for i = 1, count do
            table.insert(lines, '   item ' .. i)
        end

        table.insert(lines, '')
        table.insert(lines, ' hints')
        vim.api.nvim_buf_set_lines(a.buf, 0, -1, false, lines)
    end

    function a.on_cursor(_, lnum, prev)
        table.insert(seen, { lnum, prev })

        if lnum > count + 2 then
            vim.api.nvim_win_set_cursor(0, { count + 2, 0 })
        end
    end

    p:show(a)
    p:set_cursor(7)
    count = 1
    seen = {}
    p:render()

    eq(vim.api.nvim_win_get_cursor(p.win), { 3, 0 })
    eq(seen, { { 5, 7 } })
    eq(p.lnum, 3)

    p:render()
    eq(seen, { { 5, 7 } })
end

T['restore_width'] = new_set()

T['restore_width']['gives the window back the width it opened with'] = function()
    local p = open({ width = 25 })

    vim.api.nvim_win_set_width(p.win, 10)
    eq(p:width(), 10)

    p:restore_width()

    eq(p:width(), 25)
end

T['close'] = new_set()

T['close']['closes the window and calls on_close'] = function()
    local closed = 0
    local p = open({
        on_close = function()
            closed = closed + 1
        end,
    })

    p:show(page(1))
    p:close()

    eq(p:is_open(), false)
    vim.wait(1000, function()
        return closed > 0
    end, 10)
    eq(closed, 1)
end

T['close']['silent skips on_close'] = function()
    local closed = 0
    local p = open({
        on_close = function()
            closed = closed + 1
        end,
    })

    p:close({ silent = true })
    vim.wait(100)

    eq(p:is_open(), false)
    eq(closed, 0)
end

return T
