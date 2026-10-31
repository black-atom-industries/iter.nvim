--- Stage and unstage the hunk under the cursor of a diff view, or the lines
--- of a visual selection.

local document = require('iter.diff.document')
local editor = require('iter.annotations.editor')
local git = require('iter.git')
local patch = require('iter.diff.patch')
local util = require('iter.util')

local M = {}

---@class IterHunkActionOptions
---@field view IterDiffView
---@field root string
---@field args string[] `diff.args`, for the diff the patch comes from
---@field section fun(first: integer, last: integer): IterDocSection?, integer[] the section between buffer lines `first` and `last`, with the model rows on them
---@field refresh fun(path?: string) reload, the cursor kept on `path`

--- The section of `view` between buffer lines `first` and `last`, with the
--- model rows on those lines, in the split layout of `side` or of both
--- sides; nil and a warning when they span two files.
---@param view IterDiffView
---@param first integer
---@param last integer
---@param side? 'old'|'new'
---@return IterDocSection?
---@return integer[] rows
function M.section(view, first, last, side)
    local section, _, index = view:at(first)
    local last_section, _, last_index = view:at(last)

    if section == nil or last_section == nil then
        return nil, {}
    end

    if index ~= last_index then
        util.warn('The selection spans two files')
        return nil, {}
    end

    return section, document.rows_in(view.document, first, last, side)
end

--- Put the cursor on the `@@` row of hunk `index` of the file with `key`,
--- else of its last hunk.
---@param view IterDiffView
---@param key string
---@param index integer
local function cursor_to_hunk(view, key, index)
    local section_index = document.find(view.document, key)

    if section_index == nil then
        return
    end

    local section = view.document.sections[section_index]

    local target = math.min(index, #section.file.hunks)

    for row, model_row in ipairs(section.file.rows) do
        if model_row.kind == 'hunk' and model_row.hunk == target then
            local lnum = document.line_of(view.document, section_index, row)

            if lnum then
                view:reveal(lnum)
            end

            return
        end
    end
end

--- The del and add rows of `file` among `rows`; nil when there are none.
---@param file IterFileDiff
---@param rows integer[]
---@return IterLineSelection?
local function line_selection(file, rows)
    local selection = { old = {}, new = {} }
    local any = false

    for _, index in ipairs(rows) do
        local row = file.rows[index]

        if row.kind == 'del' then
            selection.old[row.old], any = true, true
        elseif row.kind == 'add' then
            selection.new[row.new], any = true, true
        end
    end

    return any and selection or nil
end

--- Whether the file header of `raw` names a symlink or submodule mode, whose
--- one line is a link target or commit, not text.
---@param raw string[]
---@return boolean
local function is_link(raw)
    for _, line in ipairs(raw) do
        if vim.startswith(line, '@@') then
            break
        end

        local mode = line:match('^index %x+%.%.%x+ (%d+)$')
            or line:match('^new file mode (%d+)$')
            or line:match('^deleted file mode (%d+)$')
            or line:match('^old mode (%d+)$')
            or line:match('^new mode (%d+)$')

        if mode == '120000' or mode == '160000' then
            return true
        end
    end

    return false
end

--- Stage (`stage`) or unstage (`unstage`) the hunk under the cursor of the
--- view, or in visual mode the selected del and add rows, in the split
--- layout those on both sides of the selected lines. The patch comes from
--- git's diff text of this moment, byte for byte, and only when that text
--- is still the one on screen; `git apply --check` runs before the apply.
--- After a hunk the cursor goes to the hunk that took its place, else the
--- last one. Fires `User IterStage` when it applied.
---@param kind 'stage'|'unstage'
---@param opts IterHunkActionOptions
function M.apply(kind, opts)
    local view = opts.view
    local visual = vim.fn.mode():find('^[vV\22]') ~= nil
    local first, last = editor.selection()

    if not view:is_shown() then
        return
    end

    local section, rows = opts.section(first, last)

    if section == nil then
        return
    end

    local file = section.file

    local what = visual and 'selected lines' or 'hunk'

    if file.side == 'base' then
        util.warn(
            (kind == 'stage' and 'Staging' or 'Unstaging')
                .. ' does not apply against a base'
        )
        return
    elseif kind == 'stage' and file.side ~= 'unstaged' then
        util.warn(
            visual and 'The lines are staged already'
                or 'The hunk is staged already'
        )
        return
    elseif kind == 'unstage' and file.side ~= 'staged' then
        util.warn(
            visual and 'The lines are not staged' or 'The hunk is not staged'
        )
        return
    end

    local row = file.rows[rows[1]]
    local selection

    if visual and is_link(file.raw) then
        util.warn('Lines of a symlink or submodule cannot be staged one by one')
        return
    elseif visual then
        selection = line_selection(file, rows)

        if selection == nil then
            util.warn('No added or deleted lines selected')
            return
        end
    elseif row == nil or row.hunk == nil then
        util.warn('No hunk under the cursor')
        return
    end

    local raw = git.file_diff_bytes(opts.root, file, opts.args)

    if raw == nil or not vim.deep_equal(patch.text(raw), file.raw) then
        opts.refresh()
        util.warn(
            file.path .. ' changed since it was shown; nothing was applied'
        )
        return
    end

    local lines = selection ~= nil and assert(patch.lines(raw, selection, kind))
        or assert(patch.hunk(raw, row.hunk))
    local ok, err = git.apply_patch(opts.root, lines, kind, { check = true })

    if ok then
        ok, err = git.apply_patch(opts.root, lines, kind)
    end

    -- The tree row is the path, whichever sides it has after the apply.
    opts.refresh(file.path)

    if not ok then
        util.error(string.format('Cannot %s the %s: %s', kind, what, err))
        return
    end

    util.emit('IterStage', {
        root = opts.root,
        paths = { file.path },
        action = kind,
    })

    if not visual and view:is_shown() then
        cursor_to_hunk(view, section.key, row.hunk)
    end
end

return M
