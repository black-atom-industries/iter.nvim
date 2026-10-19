--- The annotation float: a real buffer to write an annotation in, and the draft
--- lifecycle around it. One draft exists at a time. While it exists the
--- toggle key is also mapped globally in normal mode, so the draft can come
--- back from any buffer; a user mapping on that key returns afterwards.

local keymap = require('iter.keymap')
local store = require('iter.store')
local util = require('iter.util')

---@class IterEditorOpenOptions
---@field root string repository the annotation belongs to
---@field annotation IterAnnotation|{ scope: string, anchor: IterAnchor, body?: string } with an `id` an edit of a stored annotation
---@field config IterConfig
---@field pane? integer window to place the float in, the current one by default
---@field on_save? fun(annotation: IterAnnotation) after every successful save

---@class IterEditorDraft
---@field buf integer
---@field win? integer nil while hidden
---@field root string
---@field annotation table the stored annotation once it has an id
---@field keys table<string, string[]> resolved `keys.annotation`
---@field geometry table float config to show the float with again
---@field cursor integer[] cursor of the float when it was hidden
---@field at_end boolean insert after the end of the cursor line on show
---@field unloaded? { lines: string[], modified: boolean } text of an unloaded buffer
---@field saved_maps? table<string, table|false> user maps on the toggle keys
---@field closing boolean the float is being closed by the editor itself
---@field on_save? fun(annotation: IterAnnotation)

local M = {}

local GROUP = 'iter.annotation'
local HEIGHT = 6
local GLOBAL_DESC = 'Show the draft annotation'

---@type IterEditorDraft?
local draft = nil

local buf_count = 0

--- ` path:3 `, ` path:3-5 `, ` path:8 (old side) `, ` path (file) `,
--- ` Review `.
---@param annotation table
---@return string
local function title_of(annotation)
    local a = annotation.anchor

    if annotation.scope == 'review' then
        return ' Review '
    elseif annotation.scope == 'file' then
        return string.format(' %s (file) ', a.path)
    end

    local lines = a.start_line == a.end_line and tostring(a.start_line)
        or string.format('%d-%d', a.start_line, a.end_line)
    local old = a.side == 'old' and ' (old side)' or ''

    return string.format(' %s:%s%s ', a.path, lines, old)
end

---@param keys table<string, string[]>
---@return string
local function footer_of(keys)
    local parts = {}

    for _, action in ipairs({ 'save', 'toggle', 'cancel' }) do
        local lhs = keys[action] or {}

        if #lhs > 0 then
            table.insert(parts, lhs[1] .. ' ' .. action)
        end
    end

    return ' ' .. table.concat(parts, ' · ') .. ' '
end

--- Float config below the cursor line of `pane` when the pane is the
--- current window and there is room, else above it; at the bottom of the
--- pane when the cursor is elsewhere.
---@param pane integer
---@param zindex integer
---@param title string
---@param footer string
---@return table
local function geometry(pane, zindex, title, footer)
    local pos = vim.api.nvim_win_get_position(pane)
    local pane_height = vim.api.nvim_win_get_height(pane)
    local width = math.max(20, vim.api.nvim_win_get_width(pane) - 2)
    local outer = HEIGHT + 2
    local row

    if pane == vim.api.nvim_get_current_win() then
        local line = vim.api.nvim_win_call(pane, vim.fn.winline)
        row = pos[1] + line

        if row + outer > pos[1] + pane_height then
            row = pos[1] + line - 1 - outer
        end
    else
        row = pos[1] + pane_height - outer
    end

    return {
        relative = 'editor',
        row = math.max(0, row),
        col = pos[2],
        width = math.min(width, vim.o.columns - 2),
        height = HEIGHT,
        zindex = zindex,
        border = 'rounded',
        title = title,
        title_pos = 'left',
        footer = footer,
        footer_pos = 'left',
    }
end

---@param lhs string
---@return string
local function key_name(lhs)
    return vim.fn.keytrans(vim.keycode(lhs))
end

--- The global normal-mode mapping of `lhs`, buffer-local ones left out.
---@param lhs string
---@return table|false
local function global_map(lhs)
    local name = key_name(lhs)

    for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
        if vim.fn.keytrans(map.lhsraw) == name then
            return map
        end
    end

    return false
end

--- Map the toggle keys globally in normal mode, keeping any user mapping
--- on them to restore later.
local function arm()
    if draft == nil or draft.saved_maps ~= nil then
        return
    end

    draft.saved_maps = {}

    for _, lhs in ipairs(draft.keys.toggle or {}) do
        draft.saved_maps[lhs] = global_map(lhs)
        vim.keymap.set('n', lhs, function()
            M.show()
        end, { desc = GLOBAL_DESC, silent = true })
    end
end

--- Remove the global toggle maps and put the user's mappings back.
local function disarm()
    if draft == nil or draft.saved_maps == nil then
        return
    end

    for lhs, saved in pairs(draft.saved_maps) do
        local current = global_map(lhs)

        -- A map the user set meanwhile stays.
        if current and current.desc == GLOBAL_DESC then
            vim.keymap.del('n', lhs)

            if saved then
                vim.fn.mapset(saved)
            end
        end
    end

    draft.saved_maps = nil
end

---@return boolean
local function is_visible()
    return draft ~= nil and util.is_valid_win(draft.win)
end

--- Whether the draft holds text that isn't saved, also after its buffer
--- was unloaded.
---@return boolean
local function has_unsaved()
    if draft == nil then
        return false
    end

    if vim.api.nvim_buf_is_loaded(draft.buf) then
        return vim.bo[draft.buf].modified
    end

    return draft.unloaded ~= nil and draft.unloaded.modified
end

--- Close the float without ending the draft.
local function close_win()
    if not is_visible() then
        return
    end

    ---@cast draft IterEditorDraft
    if vim.api.nvim_get_current_win() == draft.win then
        vim.cmd.stopinsert()
    end

    draft.closing = true
    vim.api.nvim_win_close(draft.win, true)
    draft.closing = false
    draft.win = nil
end

--- End the draft: close the float, wipe its buffer, give the toggle keys
--- back. Unsaved text is dropped.
local function finish()
    if draft == nil then
        return
    end

    disarm()
    pcall(vim.api.nvim_del_augroup_by_name, GROUP)
    close_win()

    local buf = draft.buf
    draft = nil

    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

---@return string?
local function body()
    ---@cast draft IterEditorDraft
    local lines = vim.api.nvim_buf_get_lines(draft.buf, 0, -1, false)

    while #lines > 0 and lines[#lines]:match('^%s*$') do
        table.remove(lines)
    end

    local text = table.concat(lines, '\n')

    return text:match('%S') and text or nil
end

--- Save the annotation: a new one the first time, an edit of the stored one
--- after that. An annotation deleted elsewhere stays deleted.
---@return boolean saved
local function save()
    if draft == nil then
        return false
    end

    local text = body()

    if text == nil then
        util.warn('The annotation is empty')
        return false
    end

    local annotation = vim.deepcopy(draft.annotation)
    annotation.body = text

    local saved, err

    if annotation.id == nil then
        annotation.outdated = false
        saved, err = store.put_annotation(draft.root, annotation)
    else
        saved, err = store.edit_annotation(draft.root, annotation)
    end

    if saved == nil then
        util.warn(err or 'Cannot save the annotation')
        return false
    end

    draft.annotation = saved
    vim.bo[draft.buf].modified = false
    disarm()

    if draft.on_save ~= nil then
        draft.on_save(saved)
    end

    return true
end

--- Keep the cursor of the float, and whether it stood past the end of its
--- line, which insert mode allows and a restored cursor doesn't.
local function remember_cursor()
    ---@cast draft IterEditorDraft
    local cursor = vim.api.nvim_win_get_cursor(draft.win)
    local line = vim.api.nvim_buf_get_lines(
        draft.buf,
        cursor[1] - 1,
        cursor[1],
        false
    )[1] or ''

    draft.cursor = cursor
    draft.at_end = cursor[2] >= #line
end

--- Hide the float and keep the draft; the toggle key shows it again.
local function hide()
    if not is_visible() then
        return
    end

    ---@cast draft IterEditorDraft
    remember_cursor()
    close_win()
    arm()
end

local restore_buf

local function open_win()
    ---@cast draft IterEditorDraft
    restore_buf()
    draft.win = vim.api.nvim_open_win(draft.buf, true, draft.geometry)
    vim.wo[draft.win][0].wrap = true

    if draft.cursor ~= nil then
        pcall(vim.api.nvim_win_set_cursor, draft.win, draft.cursor)
    end

    vim.api.nvim_create_autocmd('WinClosed', {
        group = GROUP,
        pattern = tostring(draft.win),
        once = true,
        callback = function()
            if draft == nil or draft.closing then
                return
            end

            -- Closed from outside, e.g. `:q`, `:wq` or `:bunload!`: unsaved
            -- text stays as a hidden draft, a saved annotation ends the draft.
            if has_unsaved() then
                draft.geometry = vim.api.nvim_win_get_config(draft.win)
                remember_cursor()
                draft.win = nil
                arm()
            else
                draft.win = nil
                vim.schedule(finish)
            end
        end,
    })

    vim.cmd.startinsert({ bang = draft.at_end })
end

---@param buf integer
---@param keys table<string, string[]>
local function attach(buf, keys)
    keymap.attach(buf, 'annotation', keys, {
        save = save,
        toggle = hide,
        cancel = finish,
        close = function()
            if has_unsaved() then
                util.warn(
                    'The annotation has unsaved changes; save or cancel it'
                )
                return
            end

            finish()
        end,
    })

    vim.api.nvim_create_autocmd('BufWriteCmd', {
        group = GROUP,
        buffer = buf,
        -- A callback returning true would delete the autocmd.
        callback = function()
            save()
        end,
    })
    -- `:bunload!`, `:bdelete!` and `:bwipeout!` drop the lines; keep them,
    -- so the next show brings the draft back in a new buffer.
    vim.api.nvim_create_autocmd('BufUnload', {
        group = GROUP,
        buffer = buf,
        callback = function()
            if draft ~= nil and draft.buf == buf then
                draft.unloaded = {
                    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                    modified = vim.bo[buf].modified,
                }
            end
        end,
    })
end

--- A new annotation buffer holding `lines`, with the float's keys.
---@param lines string[]
---@param modified boolean
---@param keys table<string, string[]>
---@return integer
local function new_buf(lines, modified, keys)
    buf_count = buf_count + 1

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, 'iter://annotation/' .. buf_count)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = modified
    vim.bo[buf].filetype = 'markdown'
    attach(buf, keys)

    return buf
end

--- Give the draft a new buffer when its old one was unloaded or wiped.
restore_buf = function()
    ---@cast draft IterEditorDraft
    if vim.api.nvim_buf_is_loaded(draft.buf) or draft.unloaded == nil then
        return
    end

    local old = draft.buf
    draft.buf =
        new_buf(draft.unloaded.lines, draft.unloaded.modified, draft.keys)
    draft.unloaded = nil

    if vim.api.nvim_buf_is_valid(old) then
        vim.api.nvim_clear_autocmds({ group = GROUP, buffer = old })
        vim.api.nvim_buf_delete(old, { force = true })
    end
end

--- Open the float on an annotation: a new one, or with an `id` an edit of a
--- stored one. A draft that is still open is shown instead, unless all of
--- it is saved.
---@param opts IterEditorOpenOptions
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.root', opts.root, 'string')
    vim.validate('opts.annotation', opts.annotation, 'table')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.pane', opts.pane, 'number', true)
    vim.validate('opts.on_save', opts.on_save, 'function', true)

    if draft ~= nil then
        if not is_visible() or has_unsaved() then
            util.warn('Finish the open annotation first')
            M.show()
            return
        end

        finish()
    end

    local keys = opts.config.keys.annotation
    local pane = opts.pane or vim.api.nvim_get_current_win()
    local body_lines = opts.annotation.body ~= nil
            and vim.split(opts.annotation.body, '\n')
        or {}

    vim.api.nvim_create_augroup(GROUP, { clear = true })

    local buf = new_buf(body_lines, false, keys)

    draft = {
        buf = buf,
        root = opts.root,
        annotation = vim.deepcopy(opts.annotation),
        keys = keys,
        geometry = geometry(
            pane,
            opts.config.options.drawer.zindex + 20,
            title_of(opts.annotation),
            footer_of(keys)
        ),
        cursor = { vim.api.nvim_buf_line_count(buf), 0 },
        at_end = true,
        closing = false,
        on_save = opts.on_save,
    }

    open_win()
    arm()
end

--- Show the hidden draft where it was, or focus the float.
function M.show()
    if draft == nil then
        return
    end

    if is_visible() then
        vim.api.nvim_set_current_win(draft.win --[[@as integer]])
        vim.cmd.startinsert()
        return
    end

    open_win()
end

---@return boolean
function M.is_shown()
    return is_visible()
end

--- The float's window, nil while hidden or without a draft.
---@return integer?
function M.win()
    return is_visible() and draft.win or nil
end

--- `draft annotation` while a draft is hidden, else `''`.
---@return string
function M.statusline()
    if draft ~= nil and not is_visible() then
        return 'draft annotation'
    end

    return ''
end

--- The first and last line of the visual selection when in visual mode,
--- which then ends, else the cursor line twice.
---@return integer first
---@return integer last
function M.selection()
    local mode = vim.fn.mode()
    local cursor = vim.fn.line('.')

    if mode == 'v' or mode == 'V' or mode == '\22' then
        local other = vim.fn.line('v')
        vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)

        return math.min(cursor, other), math.max(cursor, other)
    end

    return cursor, cursor
end

--- Delete `annotation` from the store after a confirm that shows its first
--- line. A failed delete warns.
---@param root string
---@param annotation IterAnnotation
---@return boolean? deleted nil when the confirm was declined
function M.delete(root, annotation)
    local first = vim.split(annotation.body, '\n')[1]

    if
        vim.fn.confirm('Delete the annotation?\n' .. first, '&Delete\n&No', 2)
        ~= 1
    then
        return nil
    end

    local _, err = store.remove_annotations(root, { annotation.id })

    if err ~= nil then
        util.warn('Cannot delete the annotation: ' .. err)
        return false
    end

    return true
end

return M
