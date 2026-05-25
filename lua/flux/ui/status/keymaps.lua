local M = {}

---@param buf_id integer
---@param keymaps FluxKeymapEntry[]
---@param self GitStatusWindow
function M.attach_status(buf_id, keymaps, self)
    assert(self ~= nil)

    for _, entry in ipairs(keymaps) do
        if entry.area == 'status' then
            local action = entry.action

            -- Resolve action name to a function on self, with special-casing
            -- for actions that need arguments or call module-level helpers.
            local callback
            if action == 'discard_entry' then
                local force = entry.args ~= nil and entry.args.force or false
                callback = function()
                    self:discard_entry(force)
                end
            elseif action == 'toggle_preview_layout' then
                callback = function()
                    local preview_mod = require('flux.ui.status.preview')
                    preview_mod.toggle_layout(self)
                end
            else
                callback = function()
                    self[action](self)
                end
            end

            for _, mode in ipairs(entry.modes) do
                vim.keymap.set(mode, entry.key, callback, {
                    buffer = buf_id,
                    desc = entry.desc,
                    silent = true,
                    nowait = true,
                })
            end
        end
    end
end

---@param buf_id integer
---@param keymaps FluxKeymapEntry[]
---@param actions FluxPreviewActions
function M.attach_diff_stacked(buf_id, keymaps, actions)
    for _, entry in ipairs(keymaps) do
        if entry.area == 'diff_stacked' then
            local callback
            if entry.action == 'jump_hunk_next' then
                callback = function()
                    actions.jump_hunk(1)
                end
            elseif entry.action == 'jump_hunk_prev' then
                callback = function()
                    actions.jump_hunk(-1)
                end
            else
                callback = actions[entry.action]
            end

            if callback ~= nil then
                for _, mode in ipairs(entry.modes) do
                    vim.keymap.set(mode, entry.key, callback, {
                        buffer = buf_id,
                        desc = entry.desc,
                        silent = true,
                        nowait = true,
                    })
                end
            end
        end
    end
end

---@param buf_id integer
---@param keymaps FluxKeymapEntry[]
---@param actions FluxPreviewActions
function M.attach_diff_split(buf_id, keymaps, actions)
    for _, entry in ipairs(keymaps) do
        if entry.area == 'diff_split' then
            local callback
            if entry.action == 'jump_hunk_next' then
                callback = function()
                    vim.cmd('normal! ]c')
                end
            elseif entry.action == 'jump_hunk_prev' then
                callback = function()
                    vim.cmd('normal! [c')
                end
            else
                callback = actions[entry.action]
            end

            if callback ~= nil then
                for _, mode in ipairs(entry.modes) do
                    vim.keymap.set(mode, entry.key, callback, {
                        buffer = buf_id,
                        desc = entry.desc,
                        silent = true,
                        nowait = true,
                    })
                end
            end
        end
    end
end

---@param buf_id integer
---@param keymaps FluxKeymapEntry[]
---@param close_fn fun()
function M.attach_help(buf_id, keymaps, close_fn)
    for _, entry in ipairs(keymaps) do
        if entry.area == 'help' then
            for _, mode in ipairs(entry.modes) do
                vim.keymap.set(mode, entry.key, close_fn, {
                    buffer = buf_id,
                    desc = entry.desc,
                    silent = true,
                    nowait = true,
                })
            end
        end
    end
end

---@param bufnr integer
---@param actions FluxPreviewActions
function M.set_goto_code_keymap(bufnr, actions)
    vim.keymap.set('n', '<CR>', actions.goto_code, {
        buffer = bufnr,
        desc = 'Go to code under git diff cursor',
        silent = true,
        nowait = true,
    })
end

---@param bufnr integer?
function M.clear_goto_code_keymap(bufnr)
    if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.keymap.del, 'n', '<CR>', { buffer = bufnr })
    end
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

                    local preview_mod = require('flux.ui.status.preview')

                    if preview_mod.has_open_diff(self) then
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
---@param keymaps FluxKeymapEntry[]
function M.attach(self, keymaps)
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())

    M.attach_status(self.buf.id, keymaps, self)
    M.attach_cursor_autocmd(self)
end

return M
