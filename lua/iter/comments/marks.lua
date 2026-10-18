--- Comments as `virt_lines` below the rows of a diff view.

local anchor = require('iter.comments.anchor')

---@class IterCommentMark
---@field lnum integer row the comment sits below
---@field comment IterComment
---@field outdated boolean

local M = {}

local BAR = '▎ '
local OUTDATED = 'outdated · '

-- The old version of each view side, as an old-side anchor's `base`.
local OLD_BASE = { unstaged = 'index', staged = 'HEAD' }

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

--- Where `comment` sits in `file`, or nil when it belongs to another view.
---@param file IterFileDiff
---@param comment IterComment
---@param new_follows boolean the new version is the worktree file
---@return integer? lnum
---@return boolean outdated
local function locate(file, comment, new_follows)
    local a = comment.anchor

    if comment.scope == 'review' then
        return nil, false
    end

    local old = a.side == 'old'
    local path = old and (file.orig_path or file.path) or file.path

    if a.path ~= path then
        return nil, false
    end

    if comment.scope == 'file' then
        return header_of(file.rows), false
    end

    if old and (a.base or 'HEAD') ~= OLD_BASE[file.side] then
        return nil, false
    end

    local lines = old and file.old_lines or file.new_lines
    -- The view's version is the one the anchor follows, so a miss there
    -- means the text is gone, not just elsewhere in another version.
    local follows = old or new_follows
    local stop, outdated

    if lines == nil then
        stop, outdated = a.end_line, comment.outdated
    else
        local start
        start, stop = anchor.resolve(a, lines)

        if start == nil then
            if not follows then
                return nil, false
            end

            stop, outdated = a.end_line, true
        else
            outdated = false
        end
    end

    local lnum = stop and row_of(file.rows, old and 'old' or 'new', stop)

    return lnum or header_of(file.rows), outdated
end

--- The comments of `file` with the row each sits below, in row order and
--- stored order within a row. Line and range comments resolve against the
--- view's own version and sit below their last line, deleted-line comments
--- go to the view whose old version is their base, file comments sit below
--- the header, and a line hidden in a gap puts its comment below the gap.
--- A staged view outdates new-side comments only with `opts.new_follows`,
--- set when the file has no unstaged changes, so the index is the worktree.
---@param file IterFileDiff
---@param comments IterComment[]
---@param opts? { new_follows?: boolean }
---@return IterCommentMark[]
function M.place(file, comments, opts)
    local new_follows = file.side == 'unstaged'
        or (opts ~= nil and opts.new_follows == true)
    local result = {}
    ---@type table<IterCommentMark, integer>
    local order = {}

    for index, comment in ipairs(comments) do
        local lnum, outdated = locate(file, comment, new_follows)

        if lnum ~= nil then
            local mark = { lnum = lnum, comment = comment, outdated = outdated }
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

--- The virtual lines of one comment for a text area `width` cells wide:
--- a bar, then the body wrapped and padded to the width. An outdated one is
--- labelled and dimmed.
---@param comment IterComment
---@param outdated boolean
---@param width integer
---@return [string, string][][]
function M.lines(comment, outdated, width)
    local group = outdated and 'IterDiffCommentOutdated' or 'IterDiffComment'
    local text_width = math.max(1, width - vim.fn.strdisplaywidth(BAR))
    local body = (outdated and OUTDATED or '')
        .. (comment.body:gsub('\t', '    '))
    local result = {}

    for _, paragraph in ipairs(vim.split(body, '\n', { plain = true })) do
        for _, piece in ipairs(wrap(paragraph, text_width)) do
            local pad = text_width - vim.fn.strdisplaywidth(piece)

            table.insert(result, {
                { BAR, group },
                { piece .. string.rep(' ', math.max(0, pad)), group },
            })
        end
    end

    return result
end

--- Draw `marks` into `ns` of `buf`, below their rows.
---@param buf integer
---@param ns integer
---@param marks IterCommentMark[]
---@param width integer text area width of the window
function M.apply(buf, ns, marks, width)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local by_row = {}

    for _, mark in ipairs(marks) do
        by_row[mark.lnum] = by_row[mark.lnum] or {}
        vim.list_extend(
            by_row[mark.lnum],
            M.lines(mark.comment, mark.outdated, width)
        )
    end

    for lnum, lines in pairs(by_row) do
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
            virt_lines = lines,
        })
    end
end

return M
