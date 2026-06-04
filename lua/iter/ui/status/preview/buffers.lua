require('iter.ui.status.preview.types')

local Buffer = require('iter.ui.buffer')
local keymaps = require('iter.ui.status.keymaps')

local M = {}

---@param bufnr integer
---@param actions IterPreviewBufferActions
function M.set_goto_code_keymap(bufnr, actions)
    keymaps.set_goto_code_keymap(bufnr, actions)
end

---@param bufnr integer?
function M.clear_goto_code_keymap(bufnr)
    keymaps.clear_goto_code_keymap(bufnr)
end

---@param buf Buffer
---@param lines string[]
function M.set_plain_lines(buf, lines)
    vim.bo[buf.id].modifiable = true
    vim.api.nvim_buf_set_lines(buf.id, 0, -1, false, lines)
    vim.bo[buf.id].modifiable = false
end

---@param self GitStatusWindow
---@param actions IterPreviewBufferActions
---@return Buffer
function M.ensure_stacked(self, actions)
    if self.diff_buf and self.diff_buf:is_valid() then
        return self.diff_buf
    end

    self.diff_buf = Buffer.new({
        listed = false,
        scratch = true,
        name = 'Iter diff',
    })

    vim.bo[self.diff_buf.id].buftype = 'nofile'
    vim.bo[self.diff_buf.id].bufhidden = 'hide'
    vim.bo[self.diff_buf.id].swapfile = false

    keymaps.attach_diff_stacked(
        self.diff_buf.id,
        self.config.keymaps_diff_stacked,
        actions
    )

    return self.diff_buf
end

--- NOTE: self is now used (was _) to access self.config.keymaps_diff_split.
--- All internal callers pass self; this module is not part of the public API.
---@param self GitStatusWindow
---@param buf_name string
---@param existing Buffer?
---@param actions IterPreviewBufferActions
---@return Buffer
function M.ensure_split(self, buf_name, existing, actions)
    if existing ~= nil and existing:is_valid() then
        return existing
    end

    local buf = Buffer.new({
        listed = false,
        scratch = true,
        name = buf_name,
    })

    vim.bo[buf.id].buftype = 'nofile'
    vim.bo[buf.id].bufhidden = 'hide'
    vim.bo[buf.id].swapfile = false

    keymaps.attach_diff_split(buf.id, self.config.keymaps_diff_split, actions)

    return buf
end

return M
