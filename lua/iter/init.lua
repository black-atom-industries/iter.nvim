---@class Iter
---@field drawer IterDrawer? the open status drawer
---@field current_review IterReview? the open review tab
---@field did_setup boolean
---@field config IterConfig
local M = {
    drawer = nil,
    current_review = nil,
    did_setup = false,
    config = require('iter.config').resolve(),
}

local log = require('iter.log')
local util = require('iter.util')

---@param win integer
---@return boolean
local function is_normal_win(win)
    return util.is_valid_win(win)
        and vim.api.nvim_win_get_config(win).relative == ''
end

--- The window the drawer anchors to: the current one, or when that is a
--- float, the previous or else the first normal window of the tab.
---@return integer
local function target_pane()
    local current = vim.api.nvim_get_current_win()

    if is_normal_win(current) then
        return current
    end

    local previous = vim.fn.win_getid(vim.fn.winnr('#'))

    if is_normal_win(previous) then
        return previous
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if is_normal_win(win) then
            return win
        end
    end

    return current
end

---@param path string?
---@return GitFileChangeCounts
---@return string?
function M.file_change_counts(path)
    return require('iter.git').file_change_counts(path)
end

---@return GitFileChangeCounts
---@return string?
function M.current_file_change_counts()
    return require('iter.git').current_file_change_counts()
end

function M.status()
    log.info('status command called')

    if require('iter.git').root() == '' then
        util.warn('Not inside a git repository')
        return
    end

    local review = M.current_review

    if
        review ~= nil
        and review:is_open()
        and vim.api.nvim_get_current_tabpage() == review.tab
    then
        review.drawer:focus()
        return
    end

    if M.drawer ~= nil and M.drawer:is_open() then
        M.drawer:focus()
        return
    end

    local path = vim.api.nvim_buf_get_name(0)

    M.drawer = require('iter.ui.drawer').open({
        pane = target_pane(),
        config = M.config,
        path = path ~= '' and vim.fs.normalize(vim.fn.resolve(path)) or nil,
        on_close = function(drawer)
            if M.drawer == drawer then
                M.drawer = nil
            end
        end,
    })
end

--- Open the review tab, or switch to it when it is open. An open status
--- drawer closes first.
---@param target? { path: string, side?: IterSide } file to select
function M.review(target)
    log.info('review command called')

    if require('iter.git').root() == '' then
        util.warn('Not inside a git repository')
        return
    end

    if M.current_review ~= nil and M.current_review:is_open() then
        M.current_review:focus()
        return
    end

    if M.drawer ~= nil and M.drawer:is_open() then
        M.drawer:close()
    end

    local path = target and target.path

    if path == nil then
        local name = vim.api.nvim_buf_get_name(0)
        path = name ~= '' and vim.fs.normalize(vim.fn.resolve(name)) or nil
    end

    M.current_review = require('iter.review').open({
        config = M.config,
        path = path,
        side = target and target.side,
        on_close = function(review)
            if M.current_review == review then
                M.current_review = nil
            end
        end,
    })
end

--- Refresh the open review's comments after a write from outside it.
local function refresh_review()
    if M.current_review ~= nil and M.current_review:is_open() then
        M.current_review.drawer:refresh_comments()
    end
end

--- Draw the stored comments again in the review and in the buffers shown.
local function refresh_comments()
    refresh_review()

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        require('iter.comments.marks').render_buffer(
            vim.api.nvim_win_get_buf(win)
        )
    end
end

--- Open the comment float: on the cursor line or the visual range of a
--- repo file's buffer, or with `scope = 'review'` on the whole review.
---@param opts? { scope?: 'review' }
function M.comment(opts)
    vim.validate('opts', opts, 'table', true)
    opts = opts or {}

    local editor = require('iter.comments.editor')

    if opts.scope == 'review' then
        local root = require('iter.git').root()

        if root == '' then
            util.warn('Not inside a git repository')
            return
        end

        editor.open({
            root = root,
            comment = { scope = 'review', anchor = { side = 'new' } },
            config = M.config,
            on_save = refresh_review,
        })
        return
    end

    local marks = require('iter.comments.marks')
    local buf = vim.api.nvim_get_current_buf()
    local first, last = editor.selection()
    local target = marks.target(buf)

    if target == nil then
        util.warn('Not a file in a git repository')
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    editor.open({
        root = target.root,
        comment = {
            scope = first == last and 'line' or 'range',
            anchor = require('iter.comments.anchor').create({
                path = target.path,
                side = 'new',
                start_line = first,
                end_line = last,
            }, lines),
        },
        config = M.config,
        on_save = function()
            marks.render_buffer(buf)
            refresh_review()
        end,
    })
end

---@return IterReview?
local function open_review()
    local review = M.current_review

    return review ~= nil and review:is_open() and review or nil
end

--- Edit `path`, an absolute file path, at `line` in the current window.
---@param path string
---@param line integer
local function edit_at(path, line)
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))

    if not ok then
        util.error(tostring(err), 'Cannot open ' .. vim.fs.basename(path))
        return
    end

    vim.api.nvim_win_set_cursor(
        0,
        { math.min(line, vim.api.nvim_buf_line_count(0)), 0 }
    )
end

--- Go to `comment`: in the review when it is open and has the comment's
--- file among its changes, else in the file's buffer. A deleted line only
--- exists in the review, which opens for it.
---@param root string
---@param comment IterComment
local function jump_to_comment(root, comment)
    local a = comment.anchor
    local review = open_review()

    if comment.scope == 'review' then
        if review ~= nil then
            review:focus()
        else
            M.review()
        end

        return
    end

    local path = vim.fs.joinpath(root, a.path)

    if a.side == 'old' then
        if review == nil then
            M.review({
                path = path,
                side = a.base == 'HEAD' and 'staged' or 'unstaged',
            })
            review = open_review()
        end

        if review == nil or not review:show_comment(comment) then
            util.warn(a.path .. ' has no changes to show the old side of')
        end

        return
    end

    if review ~= nil and review:show_comment(comment) then
        return
    end

    if vim.uv.fs_stat(path) == nil then
        util.warn(a.path .. ' is deleted')
        return
    end

    local picker = require('iter.comments.picker')
    local line = picker.line_of(comment, picker.file_lines(root, a.path))

    if review ~= nil then
        review:open_file(path, line)
    else
        edit_at(path, line)
    end
end

--- Open the comment picker over the comments of the repository: the open
--- review's, else the current directory's.
function M.comments()
    local review = open_review()
    local root = review and review.drawer.changes.root
        or require('iter.git').root()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    local order = {}

    if review ~= nil then
        for _, item in ipairs(review.drawer:files()) do
            table.insert(order, item.path)

            if item.orig_path ~= nil then
                table.insert(order, item.orig_path)
            end
        end
    end

    local pane = vim.api.nvim_get_current_win()

    if review ~= nil and vim.api.nvim_get_current_tabpage() == review.tab then
        pane = review.diff_win
    end

    require('iter.comments.picker').open({
        root = root,
        config = M.config,
        order = order,
        jump = function(comment)
            jump_to_comment(root, comment)
        end,
        edit = function(comment)
            require('iter.comments.editor').open({
                root = root,
                comment = comment,
                config = M.config,
                pane = pane,
                on_save = refresh_comments,
            })
        end,
        on_change = refresh_comments,
    })
end

--- `review · <file> · <i>/<n>` inside the review tab, `''` elsewhere, with
--- `draft comment` while a comment draft is hidden.
---@return string
function M.statusline()
    local parts = {}

    if M.current_review ~= nil then
        table.insert(parts, M.current_review:statusline())
    end

    table.insert(parts, require('iter.comments.editor').statusline())

    return table.concat(
        vim.tbl_filter(function(part)
            return part ~= ''
        end, parts),
        ' · '
    )
end

---@param opts IterOptions?
function M.setup(opts)
    local config = require('iter.config')
    M.config = config.resolve(opts)
    M.did_setup = true
    require('iter.comments.marks').watch_buffers()

    return M
end

return M
