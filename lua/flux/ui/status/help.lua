local Buffer = require('flux.ui.buffer')
local common = require('flux.ui.status.common')
local keymaps = require('flux.ui.status.keymaps')

local M = {}

local AREA_TITLES = {
    status = 'Status window mappings',
    diff_stacked = 'Diff preview mappings',
    diff_split = 'Diff preview mappings',
}

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    if #text >= width then
        return text
    end

    return text .. string.rep(' ', width - #text)
end

---@param self GitStatusWindow
---@return string[]
local function help_lines(self)
    local lines = {}
    local all_entries = {}

    -- Collect all keymap entries across areas, deduplicating by key+desc
    -- so that mappings shared between stacked and split appear once.
    local seen = {}

    local function add_entries(entries)
        for _, entry in ipairs(entries) do
            local sig = entry.key .. '\0' .. entry.desc
            if not seen[sig] then
                seen[sig] = true
                all_entries[#all_entries + 1] = entry
            end
        end
    end

    add_entries(self.config.keymaps_status)
    add_entries(self.config.keymaps_diff_stacked)
    add_entries(self.config.keymaps_diff_split)

    -- Compute max key width.
    local key_width = 0

    for _, entry in ipairs(all_entries) do
        local display_key = entry.key
        if #entry.modes > 0 and entry.modes[1] ~= 'n' then
            display_key = entry.modes[1] .. ' ' .. entry.key
        end
        key_width = math.max(key_width, #display_key)
    end

    table.insert(lines, 'Mappings')
    table.insert(lines, '')

    -- Render each area section.
    local areas_rendered = {}

    for _, entry in ipairs(all_entries) do
        local title = AREA_TITLES[entry.area]

        if title ~= nil and not areas_rendered[entry.area] then
            areas_rendered[entry.area] = true

            table.insert(lines, title)
            table.insert(lines, pad('Key', key_width) .. '  Action')
            table.insert(
                lines,
                string.rep('-', key_width) .. '  ' .. string.rep('-', 32)
            )
        end

        local display_key = entry.key
        if #entry.modes > 0 and entry.modes[1] ~= 'n' then
            display_key = entry.modes[1] .. ' ' .. entry.key
        end

        table.insert(lines, pad(display_key, key_width) .. '  ' .. entry.desc)
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
        keymaps.attach_status(self.buf.id, self.config.keymaps_status, self)
    end
end

---@param self GitStatusWindow
function M.toggle(self)
    if M.has_open_help(self) then
        M.close(self)
        return
    end

    local lines = help_lines(self)
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
        name = 'Flux mappings',
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
        title = ' flux ',
        title_pos = 'center',
        style = 'minimal',
    })

    vim.wo[self.help_win].wrap = false
    vim.wo[self.help_win].cursorline = false

    keymaps.attach_help(self.help_buf.id, self.config.keymaps_help, function()
        M.close(self)
    end)
end

return M
