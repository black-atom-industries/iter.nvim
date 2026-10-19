--- Annotations as `virt_lines` below the rows of a diff view, and with signs
--- in normal buffers of repo files.

local anchor = require('iter.annotations.anchor')
local list = require('iter.annotations.list')
local util = require('iter.util')

---@class IterAnnotationMark
---@field lnum integer row the annotation sits below
---@field annotation IterAnnotation
---@field outdated boolean
---@field section? integer section of the view's document, set by the view
---@field hidden? boolean in a collapsed section, `lnum` its header row; set by the view

local M = {}

local BAR = '▎ '
local OUTDATED = 'outdated · '

--- The row showing line `line` of the old (`field` 'old') or new version:
--- a row with that number, else the gap hiding it.
---@param rows IterDiffRow[]
---@param field 'old'|'new'
---@param line integer
---@return integer?
local function row_of(rows, field, line)
    local skip = field == 'old' and 'add' or 'del'

    for lnum, row in ipairs(rows) do
        if row[field] == line and row.kind ~= skip then
            return lnum
        end

        local gap = row.gap

        if
            gap ~= nil
            and line >= gap[field]
            and line < gap[field] + gap.count
        then
            return lnum
        end
    end

    return nil
end

---@param rows IterDiffRow[]
---@return integer
local function header_of(rows)
    for lnum, row in ipairs(rows) do
        if row.kind == 'header' then
            return lnum
        end
    end

    return 1
end

--- Where `annotation` sits in `file`, or nil when it belongs to another view.
--- It sits where the view's version has its text; whether it is outdated
--- comes from the version it follows, as `list.line_of` decides.
---@param file IterFileDiff
---@param annotation IterAnnotation
---@param new_follows boolean the new version is the worktree file
---@param lines_of? IterLinesOf
---@return integer? lnum
---@return boolean outdated
local function locate(file, annotation, new_follows, lines_of)
    local a = annotation.anchor

    if annotation.scope == 'review' then
        return nil, false
    end

    local old = a.side == 'old'
    local path = old and (file.orig_path or file.path) or file.path

    if a.path ~= path then
        return nil, false
    end

    if annotation.scope == 'file' then
        return header_of(file.rows), false
    end

    if old and (a.base or 'HEAD') ~= anchor.OLD_BASE[file.side] then
        return nil, false
    end

    local lines = old and file.old_lines or file.new_lines
    -- The view's version is the one the anchor follows, so a miss there
    -- means the text is gone, not just elsewhere in another version.
    local follows = old or new_follows
    -- An old-side view shows the anchor's base, the version it follows.
    local followed = old and lines or nil

    if followed == nil and lines_of ~= nil then
        followed = lines_of(path, anchor.version(a))
    end

    if followed == nil and follows then
        followed = lines
    end

    local _, _, outdated = list.line_of(annotation, followed)
    local stop = a.end_line

    if lines ~= nil then
        local start, found = anchor.resolve(a, lines)

        if start ~= nil then
            stop = found
        elseif not follows then
            return nil, false
        end
    end

    local lnum = stop and row_of(file.rows, old and 'old' or 'new', stop)

    return lnum or header_of(file.rows), outdated
end

--- The annotations of `file` with the row each sits below, in row order and
--- stored order within a row. Line and range annotations resolve against the
--- view's own version and sit below their last line, deleted-line annotations
--- go to the view whose old version is their base, file annotations sit below
--- the header, and a line hidden in a gap puts its annotation below the gap.
--- Outdated is read from `opts.lines_of` when given; without it from the
--- view's own version where that is the one the annotation follows (a
--- staged view's new side only with `opts.new_follows`, set when the file
--- has no unstaged changes, so the index is the worktree), else from the
--- stored flag.
---@param file IterFileDiff
---@param annotations IterAnnotation[]
---@param opts? { new_follows?: boolean, lines_of?: IterLinesOf }
---@return IterAnnotationMark[]
function M.place(file, annotations, opts)
    opts = opts or {}

    local new_follows = file.side == 'unstaged' or opts.new_follows == true
    local result = {}
    ---@type table<IterAnnotationMark, integer>
    local order = {}

    for index, annotation in ipairs(annotations) do
        local lnum, outdated =
            locate(file, annotation, new_follows, opts.lines_of)

        if lnum ~= nil then
            local mark =
                { lnum = lnum, annotation = annotation, outdated = outdated }
            order[mark] = index
            table.insert(result, mark)
        end
    end

    table.sort(result, function(a, b)
        if a.lnum ~= b.lnum then
            return a.lnum < b.lnum
        end

        return order[a] < order[b]
    end)

    return result
end

--- `text` cut into pieces no wider than `width` cells, at spaces when it
--- can be, else mid-word.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
    local pieces = {}

    while vim.fn.strdisplaywidth(text) > width do
        local chars = vim.fn.strchars(text)
        local fit = 0

        while
            fit < chars
            and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, fit + 1))
                <= width
        do
            fit = fit + 1
        end

        fit = math.max(fit, 1)

        local head = vim.fn.strcharpart(text, 0, fit)
        local space = head:find(' [^ ]*$')

        if vim.fn.strcharpart(text, fit, 1) == ' ' then
            space = #head + 1
        end

        if space ~= nil and space > 1 then
            table.insert(pieces, text:sub(1, space - 1))
            text = text:sub(space + 1)
        else
            table.insert(pieces, head)
            text = text:sub(#head + 1)
        end
    end

    table.insert(pieces, text)

    return pieces
end

--- The virtual lines of one annotation for a text area `width` cells wide:
--- a bar, then the body wrapped and padded to the width; the first line has
--- `icon` after the bar and the others are indented under the text. An
--- outdated one is labelled and dimmed; a focused one is highlighted.
---@param annotation IterAnnotation
---@param outdated boolean
---@param width integer
---@param focused? boolean
---@param icon? string shown after the bar, nil or '' for none
---@return [string, string][][]
function M.lines(annotation, outdated, width, focused, icon)
    local group = focused and 'IterDiffAnnotationFocus'
        or outdated and 'IterDiffAnnotationOutdated'
        or 'IterDiffAnnotation'
    local lead = icon ~= nil and icon ~= '' and icon .. ' ' or ''
    local lead_width = vim.fn.strdisplaywidth(lead)
    local text_width =
        math.max(1, width - vim.fn.strdisplaywidth(BAR) - lead_width)
    local body = (outdated and OUTDATED or '')
        .. (annotation.body:gsub('\t', '    '))
    local result = {}

    for _, paragraph in ipairs(vim.split(body, '\n', { plain = true })) do
        for _, piece in ipairs(wrap(paragraph, text_width)) do
            local pad = text_width - vim.fn.strdisplaywidth(piece)

            local chunks = { { BAR, group } }

            if lead_width > 0 then
                table.insert(chunks, {
                    #result == 0 and lead or string.rep(' ', lead_width),
                    group,
                })
            end

            table.insert(
                chunks,
                { piece .. string.rep(' ', math.max(0, pad)), group }
            )
            table.insert(result, chunks)
        end
    end

    return result
end

-- Normal file buffers of repo files. Per buffer, `b:iter_annotation_target`
-- holds `{ root, path }`, or false for a buffer that is not a repo file, so
-- each buffer is checked once and the state dies with the buffer.

local SIGN = '▍'
local TARGET = 'iter_annotation_target'
local WIDTH = 'iter_annotation_width'

local buffer_ns = vim.api.nvim_create_namespace('iter.buffer.annotations')

-- Save errors shown so far, so a failing store warns once per message.
---@type table<string, true>
local save_warned = {}

--- The stored annotations of the repo at `root`.
---@param root string
---@return IterAnnotation[]
local function root_annotations(root)
    return require('iter.store').cached(root).annotations
end

--- The repo root and repo-relative path of `buf`, or nil when it is not a
--- file buffer inside a git worktree. Spawns no git.
---@param buf integer
---@return { root: string, path: string }?
local function target_of(buf)
    local known = vim.b[buf][TARGET]

    if known ~= nil then
        return known or nil
    end

    ---@type { root: string, path: string }|false
    local target = false
    local name = vim.api.nvim_buf_get_name(buf)

    if
        vim.bo[buf].buftype == ''
        and name ~= ''
        and not name:match('^%a[%w+.-]*://')
    then
        local path = vim.fs.normalize(vim.fn.resolve(name))
        local root = vim.fs.root(path, '.git')

        if root ~= nil then
            root = vim.fs.normalize(vim.fn.resolve(root))
            local rel = vim.fs.relpath(root, path)

            if
                rel ~= nil
                and rel ~= '.git'
                and not vim.startswith(rel, '.git/')
            then
                target = { root = root, path = rel }
            end
        end
    end

    vim.b[buf][TARGET] = target

    return target or nil
end

---@param annotation IterAnnotation
---@param path string
---@return boolean
local function follows_buffer(annotation, path)
    return (annotation.scope == 'line' or annotation.scope == 'range')
        and annotation.anchor.side == 'new'
        and annotation.anchor.path == path
end

--- Draw the annotations of `buf` for `win`: a sign on each anchored line and
--- the text below the last one. They resolve against the buffer's lines
--- without persisting; one that isn't found sits at its stored line.
---@param buf integer
---@param win integer
local function render(buf, win)
    local target = target_of(buf)

    if target == nil then
        return
    end

    local annotations = vim.tbl_filter(function(annotation)
        return follows_buffer(annotation, target.path)
    end, root_annotations(target.root))

    if #annotations == 0 then
        vim.api.nvim_buf_clear_namespace(buf, buffer_ns, 0, -1)
        vim.b[buf][WIDTH] = vim.api.nvim_win_get_width(win)
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local wininfo = vim.fn.getwininfo(win)[1]
    local indent = wininfo.textoff
    -- The sign column of 'auto' appears with the first sign, but `textoff`
    -- only counts it after the next redraw.
    local signcolumn = vim.wo[win].signcolumn

    if
        vim.startswith(signcolumn, 'auto')
        and #vim.api.nvim_buf_get_extmarks(
                buf,
                -1,
                0,
                -1,
                { type = 'sign', limit = 1 }
            )
            == 0
    then
        indent = indent + 2
    end

    local width = math.max(1, wininfo.width - indent)
    local pad = { string.rep(' ', indent) }

    vim.api.nvim_buf_clear_namespace(buf, buffer_ns, 0, -1)

    for _, annotation in ipairs(annotations) do
        local start, stop, outdated = list.line_of(annotation, lines)

        if start == nil then
            stop =
                math.min(math.max(annotation.anchor.end_line or 1, 1), #lines)
            start = stop
        end

        ---@cast start integer
        ---@cast stop integer

        local group = outdated and 'IterDiffAnnotationOutdated'
            or 'IterAnnotationSign'

        for lnum = start, stop do
            vim.api.nvim_buf_set_extmark(buf, buffer_ns, lnum - 1, 0, {
                sign_text = SIGN,
                sign_hl_group = group,
            })
        end

        local virt_lines = M.lines(
            annotation,
            outdated,
            width,
            false,
            require('iter').config.options.icons.annotation
        )

        for _, line in ipairs(virt_lines) do
            table.insert(line, 1, pad)
        end

        vim.api.nvim_buf_set_extmark(buf, buffer_ns, stop - 1, 0, {
            virt_lines = virt_lines,
            virt_lines_leftcol = true,
        })
    end

    vim.b[buf][WIDTH] = wininfo.width
end

--- Re-anchor the annotations of `buf` against its lines after a write and
--- persist the ones that moved, turned outdated or were found again.
---@param buf integer
local function reanchor(buf)
    local target = target_of(buf)

    if target == nil then
        return
    end

    local path = target.path
    local any = vim.iter(root_annotations(target.root)):any(function(annotation)
        return follows_buffer(annotation, path)
    end)

    if not any then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local data, err = require('iter.store').update(target.root, function(stored)
        local changed = false

        for index, annotation in ipairs(stored.annotations) do
            if follows_buffer(annotation, path) then
                local moved, did = anchor.follow(annotation, lines)

                if did then
                    stored.annotations[index] = moved
                    changed = true
                end
            end
        end

        return changed
    end)

    if data == nil then
        local message = 'Cannot save the moved annotations: ' .. tostring(err)

        if not save_warned[message] then
            save_warned[message] = true
            util.error(message)
        end
    end
end

--- A normal window showing `buf`, floats left out: marks are per buffer, so
--- they wrap to a normal window, not to a preview float.
---@param buf integer
---@return integer?
local function normal_win_of(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if util.is_normal_win(win) then
            return win
        end
    end

    return nil
end

--- The repo root and repo-relative path of `buf`, or nil when it is not a
--- file buffer inside a git worktree. Spawns no git.
---@param buf integer
---@return { root: string, path: string }?
function M.target(buf)
    return target_of(buf)
end

--- Draw the annotations of `buf` again in a normal window showing it.
---@param buf integer
function M.render_buffer(buf)
    local win = vim.api.nvim_buf_is_valid(buf) and normal_win_of(buf)

    if win then
        render(buf, win)
    end
end

--- Show annotations in normal buffers of repo files and keep them anchored
--- as the files are written. Safe to call more than once.
function M.watch_buffers()
    require('iter.highlight').setup()

    local group =
        vim.api.nvim_create_augroup('iter.buffer_annotations', { clear = true })

    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = group,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()

            if util.is_normal_win(win) then
                render(args.buf, win)
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = group,
        callback = function(args)
            local buf = args.buf
            local name = vim.api.nvim_buf_get_name(buf)

            if
                target_of(buf) == nil
                or vim.fn.resolve(args.match) ~= vim.fn.resolve(name)
            then
                return
            end

            reanchor(buf)

            local win = normal_win_of(buf)

            if win ~= nil then
                render(buf, win)
            end
        end,
    })
    -- A reload after an outside change (`:checktime`, 'autoread') replaces
    -- the lines but keeps the extmarks where they were, and fires no
    -- `BufWinEnter`.
    vim.api.nvim_create_autocmd('FileChangedShellPost', {
        group = group,
        callback = function(args)
            local win = normal_win_of(args.buf)

            if win ~= nil then
                render(args.buf, win)
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufFilePost', {
        group = group,
        callback = function(args)
            vim.b[args.buf][TARGET] = nil
            vim.api.nvim_buf_clear_namespace(args.buf, buffer_ns, 0, -1)

            local win = normal_win_of(args.buf)

            if win ~= nil then
                render(args.buf, win)
            end
        end,
    })
    vim.api.nvim_create_autocmd('WinResized', {
        group = group,
        callback = function()
            for _, win in ipairs(vim.v.event.windows) do
                if util.is_normal_win(win) then
                    local buf = vim.api.nvim_win_get_buf(win)
                    local width = vim.b[buf][WIDTH]

                    if
                        width ~= nil
                        and width ~= vim.api.nvim_win_get_width(win)
                    then
                        render(buf, win)
                    end
                end
            end
        end,
    })

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if util.is_normal_win(win) then
            render(vim.api.nvim_win_get_buf(win), win)
        end
    end
end

return M
