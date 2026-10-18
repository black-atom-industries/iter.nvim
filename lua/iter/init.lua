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
