--- A tab of iter's own, such as the review or the commits: opened after the
--- current tab, it remembers where it came from, opens files there and goes
--- back there when it closes.

local util = require('iter.util')

local M = {}

---@class IterTab
---@field tab integer
---@field origin_tab integer tab it was opened from; files open there
---@field origin_win? integer normal window of that tab
---@field buf integer the buffer the tab's first window shows first, the tab's own to fill, wiped when the tab closes

-- Window options of the main window while it shows a summary in the diff's
-- place.
local SUMMARY_WINOPTS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    list = false,
    spell = false,
    cursorline = false,
    wrap = true,
    linebreak = true,
    breakindent = true,
}

--- A normal window of `tab`: `preferred` when it is one there, else the
--- tab's current window, else its first normal one.
---@param tab integer
---@param preferred? integer
---@return integer?
local function normal_win(tab, preferred)
    if
        util.is_normal_win(preferred)
        and vim.api.nvim_win_get_tabpage(preferred --[[@as integer]]) == tab
    then
        return preferred
    end

    local current = vim.api.nvim_tabpage_get_win(tab)

    if util.is_normal_win(current) then
        return current
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if util.is_normal_win(win) then
            return win
        end
    end

    return nil
end

--- Open a tab after the current one, labelled `label`, its window showing
--- an empty buffer, and switch to it.
---@param label string
---@return IterTab
---@return integer win the tab's window
function M.open(label)
    vim.validate('label', label, 'string')

    local origin_tab = vim.api.nvim_get_current_tabpage()
    local origin_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].bufhidden = 'hide'
    vim.cmd('tab sbuffer ' .. buf)
    vim.t.radar_disabled = true
    vim.t.iter_label = label

    local win = vim.api.nvim_get_current_win()

    -- New windows copy the jumplist of the window they open from, so a jump
    -- back would put the origin's files into the tab's windows.
    vim.cmd.clearjumps()

    return {
        tab = vim.api.nvim_get_current_tabpage(),
        origin_tab = origin_tab,
        origin_win = normal_win(origin_tab, origin_win),
        buf = buf,
    },
        win
end

--- Close the tab and wipe its buffer, then go back to the tab it came from
--- when it was the current one. The last tab gives way to a new empty one.
---@param t IterTab
function M.close(t)
    local current = vim.api.nvim_get_current_tabpage() == t.tab

    if vim.api.nvim_tabpage_is_valid(t.tab) then
        if #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd.tabnew()
        end

        vim.cmd.tabclose({
            vim.api.nvim_tabpage_get_number(t.tab),
            bang = true,
        })
    end

    if vim.api.nvim_buf_is_valid(t.buf) then
        vim.api.nvim_buf_delete(t.buf, { force = true })
    end

    if current and vim.api.nvim_tabpage_is_valid(t.origin_tab) then
        vim.api.nvim_set_current_tabpage(t.origin_tab)
    end
end

--- Edit `path`, an absolute file path, at `line` in the tab `t` came from,
--- a new tab when that one is gone. `t` stays open.
---@param t IterTab
---@param path string
---@param line integer
function M.open_file(t, path, line)
    if not vim.api.nvim_tabpage_is_valid(t.origin_tab) then
        vim.cmd.tabnew({ range = { 0 } })
        t.origin_tab = vim.api.nvim_get_current_tabpage()
    end

    local win = normal_win(t.origin_tab, t.origin_win)

    if win == nil then
        return
    end

    t.origin_win = win

    if not util.can_leave(vim.api.nvim_win_get_buf(win), path) then
        return
    end

    vim.api.nvim_set_current_tabpage(t.origin_tab)
    vim.api.nvim_set_current_win(win)
    util.edit_at(path, line)
end

--- Show `buf`, a summary, in `win` in place of what it shows, with the
--- options of a text to read. Returns the window's options from before,
--- `saved` when given, for `hide_summary`.
---@param win integer
---@param buf integer
---@param saved? table<string, any>
---@return table<string, any> saved
function M.show_summary(win, buf, saved)
    if vim.api.nvim_win_get_buf(win) ~= buf then
        saved = saved or {}

        for name in pairs(SUMMARY_WINOPTS) do
            saved[name] = vim.api.nvim_get_option_value(
                name,
                { scope = 'local', win = win }
            )
        end

        vim.api.nvim_win_set_buf(win, buf)
    end

    for name, value in pairs(SUMMARY_WINOPTS) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = win }
        )
    end

    return saved or {}
end

--- Give `win` the options `show_summary` saved.
---@param win integer
---@param saved? table<string, any>
function M.hide_summary(win, saved)
    for name, value in pairs(saved or {}) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = win }
        )
    end
end

return M
