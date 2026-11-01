--- The panel: a full-height window at the tab's left edge that shows one
--- page at a time, such as the review's file tree or a list that takes its
--- place, and marks the cursor line with `▸`.

local util = require('iter.util')

local M = {}

---@class IterPanelPage
---@field buf integer the page's own buffer, its lines starting with a 3-cell gutter whose second cell the panel draws `▸` in; it must survive being hidden ('bufhidden' not 'wipe' or 'delete'), since another page takes the window
---@field render fun(self, width: integer, height: integer) writes the page's lines and its line → item map
---@field on_cursor? fun(self, lnum: integer, prev: integer) after the cursor moved to another line, and once when the page is shown, with the panel's window current; may move the cursor to an item line
---@field has_item? fun(self, lnum: integer): boolean whether line `lnum` holds an item; the marker shows only on such a line

---@class IterPanelOpenOptions
---@field width integer cells
---@field on_close? fun() after its window closed, however it closed

---@class IterPanel
---@field win integer
---@field columns integer the width it keeps
---@field page? IterPanelPage the page the window shows
---@field on_close? fun()
---@field group integer
---@field cursors table<IterPanelPage, [integer, integer]> each page's cursor when it was last shown
---@field lnum? integer the cursor line `on_cursor` last saw
---@field silent? boolean `close` was asked not to call `on_close`
local Panel = {}
Panel.__index = Panel

local namespace = vim.api.nvim_create_namespace('iter.panel.cursor')

local WINOPTS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    wrap = false,
    list = false,
    -- With 'scrolloffpad', a user's 'scrolloff' scrolls a page that fits the
    -- window as the cursor nears its end.
    scrolloff = 0,
    cursorline = true,
    winfixwidth = true,
    winhighlight = 'Normal:IterSidebar,EndOfBuffer:IterSidebar,SignColumn:IterSidebar,FoldColumn:IterSidebar,CursorLine:IterDrawerSelected',
}

--- Local values only: a buffer `:edit` puts in the window, and a window
--- split from it, start out with the window's global values, the user's.
---@param win integer
local function apply_winopts(win)
    for name, value in pairs(WINOPTS) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = win }
        )
    end
end

---@return boolean
function Panel:is_open()
    return util.is_valid_win(self.win)
end

---@return integer
function Panel:width()
    return vim.api.nvim_win_get_width(self.win)
end

---@return integer
function Panel:height()
    return vim.api.nvim_win_get_height(self.win)
end

function Panel:focus()
    if self:is_open() then
        vim.api.nvim_set_current_win(self.win)
    end
end

--- Whether the window shows the page, and not a buffer put there from
--- outside.
---@param self IterPanel
---@return boolean
local function showing(self)
    return self.page ~= nil
        and self:is_open()
        and vim.api.nvim_win_get_buf(self.win) == self.page.buf
end

--- Draw `▸` in the gutter of the cursor line of the shown page, none
--- while the window shows another buffer.
---@param self IterPanel
local function mark(self)
    local page = self.page

    if page == nil or not vim.api.nvim_buf_is_valid(page.buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(page.buf, namespace, 0, -1)

    if not showing(self) then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]

    if page.has_item ~= nil and not page:has_item(lnum) then
        return
    end

    vim.api.nvim_buf_set_extmark(page.buf, namespace, lnum - 1, 0, {
        virt_text = { { ' ▸', 'IterDrawerKey' } },
        virt_text_pos = 'overlay',
        hl_mode = 'combine',
    })
end

--- Let the page answer a cursor move to a line other than the one it last
--- saw, then mark where the cursor ended up.
---@param self IterPanel
---@param force? boolean also when the line is the same
local function moved(self, force)
    local page = self.page

    if page == nil or not showing(self) then
        mark(self)
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]

    if page.on_cursor ~= nil and (force or lnum ~= self.lnum) then
        local prev = self.lnum or lnum

        vim.api.nvim_win_call(self.win, function()
            page:on_cursor(lnum, prev)
        end)
        lnum = vim.api.nvim_win_get_cursor(self.win)[1]
    end

    self.lnum = lnum
    self.cursors[page] = vim.api.nvim_win_get_cursor(self.win)
    mark(self)
end

--- Show the page from its first line while the cursor line fits in the
--- window from there, so a header stays in view after a resize.
---@param self IterPanel
local function top(self)
    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]

    if lnum <= self:height() then
        vim.api.nvim_win_call(self.win, function()
            vim.fn.winrestview({ topline = 1 })
        end)
    end
end

--- Give the window back its width, which a split beside it takes from it.
function Panel:restore_width()
    if self:is_open() and self:width() ~= self.columns then
        vim.api.nvim_win_set_width(self.win, self.columns)
    end
end

--- Render the shown page for the window's size. A cursor the new lines
--- moved, or left past their end, reaches `on_cursor` as a move.
function Panel:render()
    if self.page == nil or not self:is_open() then
        return
    end

    self.page:render(self:width(), self:height())

    if showing(self) then
        local cursor = vim.api.nvim_win_get_cursor(self.win)
        local last = vim.api.nvim_buf_line_count(self.page.buf)

        if cursor[1] > last then
            vim.api.nvim_win_set_cursor(self.win, { last, 0 })
        end

        top(self)
    end

    moved(self)
end

--- Move the cursor of the shown page to `lnum`, as a move of the user's
--- would, also while another window has the focus.
---@param lnum integer
function Panel:set_cursor(lnum)
    vim.validate('lnum', lnum, 'number')

    if not showing(self) then
        return
    end

    local last = vim.api.nvim_buf_line_count(self.page.buf)

    vim.api.nvim_win_set_cursor(
        self.win,
        { math.max(1, math.min(lnum, last)), 0 }
    )
    moved(self)
end

--- Show `page` in the window, rendered, with the cursor it had when it was
--- last shown.
---@param page IterPanelPage
function Panel:show(page)
    vim.validate('page', page, 'table')
    vim.validate('page.buf', page.buf, 'number')
    vim.validate('page.render', page.render, 'function')

    if not self:is_open() then
        return
    end

    local shown = self.page

    if showing(self) then
        self.cursors[shown] = vim.api.nvim_win_get_cursor(self.win)
    end

    if shown ~= nil and vim.api.nvim_buf_is_valid(shown.buf) then
        vim.api.nvim_buf_clear_namespace(shown.buf, namespace, 0, -1)
    end

    self.page = page
    vim.api.nvim_win_set_buf(self.win, page.buf)
    apply_winopts(self.win)
    page:render(self:width(), self:height())

    local cursor = self.cursors[page] or { 1, 0 }
    local last = vim.api.nvim_buf_line_count(page.buf)
    local lnum = math.min(cursor[1], last)

    vim.api.nvim_win_set_cursor(self.win, { lnum, cursor[2] })
    top(self)
    self.lnum = lnum
    moved(self, true)
end

--- Close the window; `on_close` follows unless `opts.silent`.
---@param opts? { silent?: boolean }
function Panel:close(opts)
    self.silent = opts ~= nil and opts.silent == true

    if self:is_open() then
        pcall(vim.api.nvim_win_close, self.win, true)
    end
end

--- Open the panel at the left edge of the current tab, the tab's full
--- height, without moving the focus. It shows nothing until `show`.
---@param opts IterPanelOpenOptions
---@return IterPanel
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.width', opts.width, 'number')
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false

    local win = vim.api.nvim_open_win(buf, false, {
        split = 'left',
        win = -1,
        width = opts.width,
    })

    apply_winopts(win)
    vim.api.nvim_win_call(win, function()
        vim.cmd.clearjumps()
    end)

    local self = setmetatable({
        win = win,
        columns = opts.width,
        on_close = opts.on_close,
        group = vim.api.nvim_create_augroup(
            'iter.panel.' .. win,
            { clear = true }
        ),
        cursors = setmetatable({}, { __mode = 'k' }),
    }, Panel)

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = self.group,
        callback = function()
            if vim.api.nvim_get_current_win() == self.win then
                moved(self)
            end
        end,
    })
    vim.api.nvim_create_autocmd('WinResized', {
        group = self.group,
        callback = function()
            if vim.tbl_contains(vim.v.event.windows, self.win) then
                self:render()
            end
        end,
    })
    vim.api.nvim_create_autocmd('VimResized', {
        group = self.group,
        callback = function()
            self:render()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = tostring(win),
        once = true,
        callback = function()
            pcall(vim.api.nvim_del_augroup_by_id, self.group)

            local page = self.page

            if page ~= nil and vim.api.nvim_buf_is_valid(page.buf) then
                vim.api.nvim_buf_clear_namespace(page.buf, namespace, 0, -1)
            end

            if self.on_close ~= nil and not self.silent then
                vim.schedule(self.on_close)
            end
        end,
    })

    return self
end

return M
