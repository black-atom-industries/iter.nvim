require('iter.ui.status.preview.types')

local Buffer = require('iter.ui.buffer')
local keymaps = require('iter.ui.status.keymaps')

local M = {}

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
        self.config.keys.diff,
        actions
    )

    return self.diff_buf
end

return M
