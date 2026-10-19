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

--- The window the drawer anchors to: the current one, or when that is a
--- float, the previous or else the first normal window of the tab.
---@return integer
local function target_pane()
    local current = vim.api.nvim_get_current_win()

    if util.is_normal_win(current) then
        return current
    end

    local previous = vim.fn.win_getid(vim.fn.winnr('#'))

    if util.is_normal_win(previous) then
        return previous
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if util.is_normal_win(win) then
            return win
        end
    end

    return current
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

--- Refresh the open review's annotations after a write from outside it.
local function refresh_review()
    if M.current_review ~= nil and M.current_review:is_open() then
        M.current_review:refresh_annotations()
    end
end

--- Draw the stored annotations again in the review and in the buffers shown.
local function refresh_annotations()
    refresh_review()

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        require('iter.annotations.marks').render_buffer(
            vim.api.nvim_win_get_buf(win)
        )
    end
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
        on_annotations = refresh_annotations,
        on_close = function(review)
            if M.current_review == review then
                M.current_review = nil
            end
        end,
    })
end

--- Open the annotation float: on the cursor line or the visual range of a
--- repo file's buffer, or with `scope = 'review'` on the whole review.
---@param opts? { scope?: 'review' }
function M.annotate(opts)
    vim.validate('opts', opts, 'table', true)
    opts = opts or {}

    local editor = require('iter.annotations.editor')

    if opts.scope == 'review' then
        local root = require('iter.git').root()

        if root == '' then
            util.warn('Not inside a git repository')
            return
        end

        editor.open({
            root = root,
            annotation = { scope = 'review', anchor = { side = 'new' } },
            config = M.config,
            on_save = refresh_review,
        })
        return
    end

    local marks = require('iter.annotations.marks')
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
        annotation = {
            scope = first == last and 'line' or 'range',
            anchor = require('iter.annotations.anchor').create({
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

--- Go to `annotation`: in the review when it is open and has the annotation's
--- file among its changes, else in the file's buffer. A deleted line only
--- exists in the review, which opens for it.
---@param root string
---@param annotation IterAnnotation
local function jump_to_annotation(root, annotation)
    local a = annotation.anchor
    local review = open_review()

    if annotation.scope == 'review' then
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

        if review == nil or not review:show_annotation(annotation) then
            util.warn(a.path .. ' has no changes to show the old side of')
        end

        return
    end

    if review ~= nil and review:show_annotation(annotation) then
        return
    end

    if vim.uv.fs_stat(path) == nil then
        util.warn(a.path .. ' is deleted')
        return
    end

    local picker = require('iter.annotations.picker')
    local line = picker.line_of(annotation, picker.file_lines(root, a.path))

    if review ~= nil then
        review:open_file(path, line)
    else
        util.edit_at(path, line)
    end
end

--- The repository the annotation commands work on, with the files of the open
--- review in drawer order: the review's, else the current directory's.
---@return string root
---@return string[] order
local function annotation_scope()
    local review = open_review()
    local root = review and review.drawer.changes.root
        or require('iter.git').root()
    local order = {}

    if review ~= nil then
        for _, item in ipairs(review.drawer:files()) do
            table.insert(order, item.path)

            if item.orig_path ~= nil then
                table.insert(order, item.orig_path)
            end
        end
    end

    return root, order
end

--- Copy the annotations of the repository as text for an agent, then ask once
--- whether to clear them.
function M.yank()
    local root, order = annotation_scope()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    require('iter.export').yank({
        root = root,
        config = M.config,
        order = order,
        on_clear = refresh_annotations,
    })
end

--- Open the annotation picker over the annotations of the repository: the open
--- review's, else the current directory's.
function M.annotations()
    local review = open_review()
    local root, order = annotation_scope()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    local pane = vim.api.nvim_get_current_win()

    if review ~= nil and vim.api.nvim_get_current_tabpage() == review.tab then
        pane = review.diff_win
    end

    require('iter.annotations.picker').open({
        root = root,
        config = M.config,
        order = order,
        jump = function(annotation)
            jump_to_annotation(root, annotation)
        end,
        edit = function(annotation)
            require('iter.annotations.editor').open({
                root = root,
                annotation = annotation,
                config = M.config,
                pane = pane,
                on_save = refresh_annotations,
            })
        end,
        on_change = refresh_annotations,
    })
end

--- `review · <file> · <i>/<n>` inside the review tab, `''` elsewhere, with
--- `draft annotation` while an annotation draft is hidden.
---@return string
function M.statusline()
    local parts = {}

    if M.current_review ~= nil then
        table.insert(parts, M.current_review:statusline())
    end

    table.insert(parts, require('iter.annotations.editor').statusline())

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
    require('iter.annotations.marks').watch_buffers()

    return M
end

return M
