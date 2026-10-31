local tab = require('iter.ui.tab')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type IterTab?
local opened

local T = new_set({
    hooks = {
        post_case = function()
            if opened ~= nil then
                tab.close(opened)
                opened = nil
            end

            vim.cmd('silent! tabonly!')
            vim.cmd('silent! only!')
        end,
    },
})

T['open'] = new_set()

T['open']['opens a labelled tab after the current one and switches to it'] = function()
    local origin_tab = vim.api.nvim_get_current_tabpage()
    local origin_win = vim.api.nvim_get_current_win()
    local t, win = tab.open('iter test')

    opened = t

    eq(vim.api.nvim_get_current_tabpage(), t.tab)
    eq(vim.api.nvim_get_current_win(), win)
    eq(vim.api.nvim_win_get_buf(win), t.buf)
    eq(vim.t.iter_label, 'iter test')
    eq(vim.t.radar_disabled, true)
    eq(t.origin_tab, origin_tab)
    eq(t.origin_win, origin_win)
    eq(vim.api.nvim_tabpage_get_number(t.tab), 2)
end

T['close'] = new_set()

T['close']['goes back to the tab it came from and wipes the buffer'] = function()
    local origin_tab = vim.api.nvim_get_current_tabpage()
    local t = tab.open('iter test')

    tab.close(t)

    eq(vim.api.nvim_tabpage_is_valid(t.tab), false)
    eq(vim.api.nvim_get_current_tabpage(), origin_tab)
    eq(vim.api.nvim_buf_is_valid(t.buf), false)
end

T['close']['the last tab gives way to a new empty one'] = function()
    local t = tab.open('iter test')

    vim.cmd.tabonly()
    tab.close(t)

    eq(#vim.api.nvim_list_tabpages(), 1)
    eq(vim.api.nvim_tabpage_is_valid(t.tab), false)
    eq(vim.api.nvim_buf_get_name(0), '')
end

T['open_file'] = new_set()

T['open_file']['edits the file in the window it came from'] = function()
    local origin_win = vim.api.nvim_get_current_win()
    local path = vim.fn.tempname()

    vim.fn.writefile({ 'one', 'two', 'three' }, path)
    opened = tab.open('iter test')
    tab.open_file(opened, path, 2)

    eq(vim.api.nvim_get_current_win(), origin_win)
    eq(vim.api.nvim_buf_get_name(0), vim.fn.resolve(path))
    eq(vim.api.nvim_win_get_cursor(0)[1], 2)
    eq(vim.api.nvim_tabpage_is_valid(opened.tab), true)
    vim.cmd.bwipeout({ bang = true })
    vim.fn.delete(path)
end

T['open_file']['opens a new tab when the one it came from is gone'] = function()
    local path = vim.fn.tempname()

    vim.fn.writefile({ 'one' }, path)
    opened = tab.open('iter test')
    vim.cmd.tabonly()
    tab.open_file(opened, path, 1)

    eq(#vim.api.nvim_list_tabpages(), 2)
    eq(vim.api.nvim_get_current_tabpage(), opened.origin_tab)
    eq(vim.api.nvim_buf_get_name(0), vim.fn.resolve(path))
    vim.cmd.bwipeout({ bang = true })
    vim.fn.delete(path)
end

T['has_window'] = new_set()

T['has_window']['tells a window of the tab from one of another tab'] = function()
    local origin_win = vim.api.nvim_get_current_win()
    local t, win = tab.open('iter test')

    opened = t

    eq(tab.has_window(t, { win }), true)
    eq(tab.has_window(t, { origin_win, win }), true)
    eq(tab.has_window(t, { origin_win }), false)
    eq(tab.has_window(t, { 99999 }), false)
    eq(tab.has_window(t, {}), false)
end

T['show_summary'] = new_set()

T['show_summary']['saves the options once and hide_summary gives them back'] = function()
    local win = vim.api.nvim_get_current_win()
    local origin = vim.api.nvim_get_current_buf()
    local buf = vim.api.nvim_create_buf(false, true)

    vim.wo[win].number = true
    vim.wo[win].wrap = false

    local saved = tab.show_summary(win, buf)

    eq(vim.api.nvim_win_get_buf(win), buf)
    eq(vim.wo[win].number, false)
    eq(vim.wo[win].wrap, true)
    eq(vim.wo[win].linebreak, true)

    eq(tab.show_summary(win, buf, saved), saved)
    eq(saved.number, true)
    eq(saved.wrap, false)

    tab.hide_summary(win, saved)

    eq(vim.wo[win].number, true)
    eq(vim.wo[win].wrap, false)
    eq(vim.wo[win].linebreak, false)

    vim.api.nvim_win_set_buf(win, origin)
    vim.api.nvim_buf_delete(buf, { force = true })
end

return T
