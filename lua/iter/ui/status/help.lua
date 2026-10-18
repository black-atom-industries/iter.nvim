local Buffer = require('iter.ui.buffer')
local common = require('iter.ui.status.common')
local keymap = require('iter.keymap')
local keymaps = require('iter.ui.status.keymaps')

local M = {}

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    if #text >= width then
        return text
    end

    return text .. string.rep(' ', width - #text)
end

---@param entries IterKeymapEntry[]
---@return string[]
local function help_lines(entries)
    local key_width = 0

    for _, entry in ipairs(entries) do
        key_width = math.max(key_width, #table.concat(entry.lhs, ' '))
    end

    local lines = {}

    for _, entry in ipairs(entries) do
        table.insert(
            lines,
            pad(table.concat(entry.lhs, ' '), key_width) .. '  ' .. entry.desc
        )
    end

    return lines
end

---@param lines string[]
---@return integer
local function content_width(lines)
    local width = 1

    for _, line in ipairs(lines) do
        width = math.max(width, #line)
    end

    return width
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_help(self)
    return self.help_buf ~= nil
        and self.help_buf:is_valid()
        and common.is_valid_win(self.help_win)
        and vim.api.nvim_win_get_buf(self.help_win) == self.help_buf.id
end

---@param self GitStatusWindow
function M.close(self)
    if not M.has_open_help(self) then
        return
    end

    vim.api.nvim_win_close(self.help_win, true)
    self.help_win = nil

    if self.help_buf ~= nil and self.help_buf:is_valid() then
        self.help_buf:delete()
    end

    self.help_buf = nil

    if common.is_valid_win(self.help_prev_win) then
        vim.api.nvim_set_current_win(self.help_prev_win)
    end

    self.help_prev_win = nil

    -- Re-attach status keymaps after closing help. Focus is returning to the
    -- status window, but BufEnter may not fire if the status buffer was never
    -- left (e.g. floating help overlay) and WinEnter alone may race with the
    -- help-close redraw.
    if
        self.buf ~= nil
        and self.buf:is_valid()
        and self.win ~= nil
        and common.is_valid_win(self.win)
    then
        keymaps.attach_status(self.buf.id, self)
    end
end

--- Toggle a float listing the keys of `view`.
---@param self GitStatusWindow
---@param view IterView
---@param handlers table<string, fun()> the view's handlers, as bound
function M.toggle(self, view, handlers)
    if M.has_open_help(self) then
        M.close(self)
        return
    end

    local lines =
        help_lines(keymap.list(view, self.config.keys[view], handlers))
    local max_width = math.min(vim.o.columns, math.max(24, vim.o.columns - 4))
    local max_height = math.min(vim.o.lines, math.max(6, vim.o.lines - 4))
    local width = math.min(content_width(lines) + 4, max_width)
    local height = math.min(#lines + 2, max_height)
    local row = math.max(0, math.floor((vim.o.lines - height) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    self.help_prev_win = vim.api.nvim_get_current_win()
    self.help_buf = Buffer.new({
        listed = false,
        scratch = true,
        name = 'Iter mappings',
    })

    vim.bo[self.help_buf.id].buftype = 'nofile'
    vim.bo[self.help_buf.id].bufhidden = 'wipe'
    vim.bo[self.help_buf.id].swapfile = false
    vim.bo[self.help_buf.id].modifiable = true
    self.help_buf:set_lines(lines)
    vim.bo[self.help_buf.id].modifiable = false

    self.help_win = vim.api.nvim_open_win(self.help_buf.id, true, {
        relative = 'editor',
        row = row,
        col = col,
        width = width,
        height = height,
        border = 'rounded',
        title = ' iter ',
        title_pos = 'center',
        style = 'minimal',
    })

    vim.wo[self.help_win].wrap = false
    vim.wo[self.help_win].cursorline = false

    keymaps.attach_help(self.help_buf.id, self.config.keys.help, function()
        M.close(self)
    end)
end

return M
