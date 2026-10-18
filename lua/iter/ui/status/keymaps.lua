local keymap = require('iter.keymap')
local log = require('iter.log')

local M = {}

---@param self GitStatusWindow
---@return table<string, fun()>
function M.status_handlers(self)
    return {
        open = function()
            self:enter_entry_and_close()
        end,
        preview = function()
            self:diff_entry()
        end,
        stage = function()
            self:stage_entry()
        end,
        unstage = function()
            self:unstage_entry()
        end,
        discard = function()
            self:discard_entry()
        end,
        close = function()
            self:close()
        end,
        help = function()
            self:toggle_help()
        end,
    }
end

---@param buf_id integer
---@param self GitStatusWindow
function M.attach_status(buf_id, self)
    assert(self ~= nil)

    keymap.attach(
        buf_id,
        'drawer',
        self.config.keys.drawer,
        M.status_handlers(self)
    )
end

---@param actions IterPreviewBufferActions
---@return table<string, fun()>
function M.diff_handlers(actions)
    return {
        next_hunk = function()
            actions.jump_hunk(1)
        end,
        prev_hunk = function()
            actions.jump_hunk(-1)
        end,
        stage = actions.stage_current_hunk,
        unstage = actions.unstage_current_hunk,
        discard = actions.discard_current_hunk,
        goto_file = actions.goto_code,
        close = actions.close_diff,
        help = actions.toggle_help,
    }
end

---@param buf_id integer
---@param keys table<string, string[]> resolved keys of the diff view
---@param actions IterPreviewBufferActions
function M.attach_diff_stacked(buf_id, keys, actions)
    keymap.attach(buf_id, 'diff', keys, M.diff_handlers(actions))
end

---@param buf_id integer
---@param keys table<string, string[]> resolved keys of the help view
---@param close_fn fun()
function M.attach_help(buf_id, keys, close_fn)
    keymap.attach(buf_id, 'help', keys, { close = close_fn })
end

---@param self GitStatusWindow
function M.attach_cursor_autocmd(self)
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    -- Only clear CursorMoved autocmds within our own group (or on the
    -- buffer if the group doesn't exist yet).  Avoids wiping user-defined
    -- CursorMoved autocmds on the same buffer.
    if self.autocmd_group ~= nil then
        vim.api.nvim_clear_autocmds({
            group = self.autocmd_group,
            event = 'CursorMoved',
        })
    else
        vim.api.nvim_clear_autocmds({
            buffer = self.buf.id,
            event = 'CursorMoved',
        })
    end

    local debounce_timer = nil

    local create_opts = {
        buffer = self.buf.id,
        callback = function()
            local mode = vim.fn.mode()
            local win = vim.api.nvim_get_current_win()
            local buf = vim.api.nvim_win_get_buf(win)

            if buf == self.buf.id then
                log.debug('CursorMoved: win=' .. win .. ' mode=' .. mode)
            end

            if mode == 'v' or mode == 'V' or mode == '\22' then
                return
            end

            -- Debounce: cancel any pending preview update and schedule a new
            -- one. This prevents rapid j/k presses from triggering a full
            -- git.diff + render on every line change.
            if debounce_timer ~= nil then
                debounce_timer:stop()
                debounce_timer:close()
                debounce_timer = nil
            end

            debounce_timer = vim.uv.new_timer()

            if debounce_timer == nil then
                return
            end

            debounce_timer:start(50, 0, function()
                vim.schedule(function()
                    if debounce_timer ~= nil then
                        debounce_timer:close()
                        debounce_timer = nil
                    end

                    if self.buf == nil or not self.buf:is_valid() then
                        return
                    end

                    local win = vim.api.nvim_get_current_win()
                    local buf = vim.api.nvim_win_get_buf(win)

                    if buf ~= self.buf.id then
                        return
                    end

                    local preview_mod = require('iter.ui.status.preview')

                    if preview_mod.has_open_diff(self) then
                        log.debug('debounce: updating preview')
                        local opts = { force = false, notify = false }

                        if
                            not preview_mod.preview_current_commit(self, opts)
                        then
                            preview_mod.preview_current_entry(self, opts)
                        end
                    end
                end)
            end)
        end,
    }
    if self.autocmd_group ~= nil then
        create_opts.group = self.autocmd_group
    end

    vim.api.nvim_create_autocmd('CursorMoved', create_opts)
end

---@param self GitStatusWindow
function M.attach(self)
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    M.attach_status(self.buf.id, self)
    M.attach_cursor_autocmd(self)
end

return M
