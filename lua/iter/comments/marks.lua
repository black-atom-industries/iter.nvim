--- Comments as `virt_lines` below the rows of a diff view, and with signs
--- in normal buffers of repo files.

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

-- Normal file buffers of repo files. Per buffer, `b:iter_comment_target`
-- holds `{ root, path }`, or false for a buffer that is not a repo file, so
-- each buffer is checked once and the state dies with the buffer.

local SIGN = '▍'
local TARGET = 'iter_comment_target'
local WIDTH = 'iter_comment_width'

local buffer_ns = vim.api.nvim_create_namespace('iter.buffer.comments')

---@class IterRootComments
---@field head_path? string
---@field head? string contents of `head_path` when `store_path` was resolved
---@field store_path? string
---@field stat? string stat of `store_path` when `comments` was read
---@field comments IterComment[]

---@type table<string, IterRootComments>
local roots = {}

-- Save errors shown so far, so a failing store warns once per message.
---@type table<string, true>
local save_warned = {}

---@param path string
---@return string
local function stat_key(path)
    local stat = vim.uv.fs_stat(path)

    if stat == nil then
        return ''
    end

    return string.format('%d.%d:%d', stat.mtime.sec, stat.mtime.nsec, stat.size)
end

---@param path string
---@return string?
local function read_line(path)
    local file = io.open(path, 'r')

    if file == nil then
        return nil
    end

    local line = file:read('*l')
    file:close()

    return line
end

--- The HEAD file of the worktree at `root`, found without spawning git: in
--- `.git/`, or in the directory a `.git` file points to.
---@param root string
---@return string?
local function head_path(root)
    local dotgit = vim.fs.joinpath(root, '.git')
    local stat = vim.uv.fs_stat(dotgit)

    if stat == nil then
        return nil
    end

    if stat.type == 'directory' then
        return vim.fs.joinpath(dotgit, 'HEAD')
    end

    local gitdir = (read_line(dotgit) or ''):match('^gitdir: (.+)$')

    if gitdir == nil then
        return nil
    end

    if not vim.startswith(gitdir, '/') then
        gitdir = vim.fs.joinpath(root, gitdir)
    end

    return vim.fs.joinpath(gitdir, 'HEAD')
end

--- The stored comments of the repo at `root`. The store path is resolved
--- again only when HEAD changed, and the file read again only when its
--- stat changed. A failed read keeps the comments there are.
---@param root string
---@return IterComment[]
local function root_comments(root)
    local cache = roots[root]

    if cache == nil then
        cache = { head_path = head_path(root), comments = {} }
        roots[root] = cache
    end

    local head = cache.head_path and read_line(cache.head_path)

    if cache.store_path == nil or head ~= cache.head then
        cache.store_path = require('iter.store').path(root)
        cache.head = head
        cache.stat = nil
    end

    local stat = cache.store_path and stat_key(cache.store_path)

    if stat ~= nil and stat == cache.stat then
        return cache.comments
    end

    local data = cache.store_path
        and require('iter.store').read(cache.store_path)

    if data ~= nil then
        cache.comments = data.comments
        cache.stat = stat
    end

    return cache.comments
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

---@param comment IterComment
---@param path string
---@return boolean
local function follows_buffer(comment, path)
    return (comment.scope == 'line' or comment.scope == 'range')
        and comment.anchor.side == 'new'
        and comment.anchor.path == path
end

--- Draw the comments of `buf` for `win`: a sign on each anchored line and
--- the text below the last one. They resolve against the buffer's lines
--- without persisting; one that isn't found sits outdated at its stored
--- line.
---@param buf integer
---@param win integer
local function render(buf, win)
    local target = target_of(buf)

    if target == nil then
        return
    end

    local comments = vim.tbl_filter(function(comment)
        return follows_buffer(comment, target.path)
    end, root_comments(target.root))

    if #comments == 0 then
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

    for _, comment in ipairs(comments) do
        local start, stop = anchor.resolve(comment.anchor, lines)
        local outdated = start == nil

        if outdated then
            stop = math.min(math.max(comment.anchor.end_line or 1, 1), #lines)
            start = stop
        end

        ---@cast start integer
        ---@cast stop integer

        local group = outdated and 'IterDiffCommentOutdated'
            or 'IterCommentSign'

        for lnum = start, stop do
            vim.api.nvim_buf_set_extmark(buf, buffer_ns, lnum - 1, 0, {
                sign_text = SIGN,
                sign_hl_group = group,
            })
        end

        local virt_lines = M.lines(comment, outdated, width)

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

--- Re-anchor the comments of `buf` against its lines after a write and
--- persist the ones that moved, turned outdated or were found again.
---@param buf integer
local function reanchor(buf)
    local target = target_of(buf)

    if target == nil then
        return
    end

    local path = target.path
    local any = vim.iter(root_comments(target.root)):any(function(comment)
        return follows_buffer(comment, path)
    end)

    if not any then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local data, err = require('iter.store').update(target.root, function(stored)
        local changed = false

        for index, comment in ipairs(stored.comments) do
            if follows_buffer(comment, path) then
                local moved, did = anchor.follow(comment, lines)

                if did then
                    stored.comments[index] = moved
                    changed = true
                end
            end
        end

        return changed
    end)

    if data == nil then
        local message = 'Cannot save the moved comments: ' .. tostring(err)

        if not save_warned[message] then
            save_warned[message] = true
            require('iter.util').warn(message)
        end

        return
    end

    local cache = roots[target.root]

    if cache ~= nil then
        cache.comments = data.comments
        cache.stat = cache.store_path and stat_key(cache.store_path)
    end
end

---@param win integer
---@return boolean
local function is_normal_win(win)
    return vim.api.nvim_win_get_config(win).relative == ''
end

--- A normal window showing `buf`, floats left out: marks are per buffer, so
--- they wrap to a normal window, not to a preview float.
---@param buf integer
---@return integer?
local function normal_win_of(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if is_normal_win(win) then
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

--- Draw the comments of `buf` again in a normal window showing it.
---@param buf integer
function M.render_buffer(buf)
    local win = vim.api.nvim_buf_is_valid(buf) and normal_win_of(buf)

    if win then
        render(buf, win)
    end
end

--- Show comments in normal buffers of repo files and keep them anchored
--- as the files are written. Safe to call more than once.
function M.watch_buffers()
    require('iter.highlight').setup()

    local group =
        vim.api.nvim_create_augroup('iter.buffer_comments', { clear = true })

    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = group,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()

            if is_normal_win(win) then
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
                if vim.api.nvim_win_is_valid(win) and is_normal_win(win) then
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
        if is_normal_win(win) then
            render(vim.api.nvim_win_get_buf(win), win)
        end
    end
end

return M
