---@class IterModule
---@field drawer IterDrawer? the open status drawer
---@field current_review IterReview? the open review tab
---@field current_commits IterCommits? the open commits tab
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
        review:focus()
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

--- Open the commits tab, or switch to it when it is open. An open status
--- drawer closes first.
function M.commits()
    log.info('commits command called')

    if require('iter.git').root() == '' then
        util.warn('Not inside a git repository')
        return
    end

    if M.current_commits ~= nil and M.current_commits:is_open() then
        M.current_commits:focus()
        return
    end

    if M.drawer ~= nil and M.drawer:is_open() then
        M.drawer:close()
    end

    M.current_commits = require('iter.ui.commits').open({
        config = M.config,
        on_close = function(commits)
            if M.current_commits == commits then
                M.current_commits = nil
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
    require('iter.ui.sidebar').refresh_all()

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        require('iter.annotations.marks').render_buffer(
            vim.api.nvim_win_get_buf(win)
        )
    end
end

--- Open the review tab, or switch to it when it is open. An open status
--- drawer closes first. `target.base`, a branch or another ref, sets what
--- the review compares with and is remembered for the branch; a ref that
--- isn't a branch names the commit the review starts after. A base spec
--- applies as it is. Without it the remembered base applies.
---@param target? { path?: string, base?: string|IterBaseSpec } file to select and base
function M.review(target)
    log.info('review command called')

    local git = require('iter.git')
    local root = git.root()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    local base = target and target.base
    local spec

    if type(base) == 'table' then
        spec = base
    elseif type(base) == 'string' then
        local err

        spec, err = git.base_spec(root, base)

        if spec == nil then
            util.error(err, 'Unknown ref ' .. base)
            return
        end
    end

    if M.current_review ~= nil and M.current_review:is_open() then
        M.current_review:focus()

        if spec ~= nil then
            M.current_review:set_base(spec)
        end

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
        base = spec,
        on_annotations = refresh_annotations,
        on_close = function(review)
            if M.current_review == review then
                M.current_review = nil
            end
        end,
    })
end

--- Open the annotation float: on the cursor line or the visual range of a
--- repo file's buffer, with `scope = 'file'` on that file, or with
--- `scope = 'review'` on the whole review.
---@param opts? { scope?: 'file'|'review' }
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
            on_save = refresh_annotations,
        })
        return
    end

    local marks = require('iter.annotations.marks')
    local buf = vim.api.nvim_get_current_buf()
    local first, last, start_col, end_col = editor.selection()
    local target = marks.target(buf)

    if target == nil then
        util.warn('Not a file in a git repository')
        return
    end

    if opts.scope == 'file' then
        editor.open({
            root = target.root,
            annotation = {
                scope = 'file',
                anchor = { path = target.path, side = 'new' },
            },
            config = M.config,
            on_save = refresh_annotations,
        })
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
                start_col = start_col,
                end_col = end_col,
            }, lines),
        },
        config = M.config,
        on_save = refresh_annotations,
    })
end

---@return IterReview?
local function open_review()
    local review = M.current_review

    return review ~= nil and review:is_open() and review or nil
end

--- The repository the annotation commands work on, with the files of the open
--- review in tree order: the review's, else the current directory's. Also
--- what that review compares with, against a base.
---@return string root
---@return string[] order
---@return IterChangesBase? since
local function annotation_scope()
    local review = open_review()
    local root = review and review.changes.root or require('iter.git').root()
    local order = review and review.file_order(review:paths()) or {}

    return root, order, review and review:since(root)
end

--- Copy the annotations of the repository as text for an agent, then ask once
--- whether to clear them. With `opts.ids`, copy only those annotations.
---@param opts? { ids?: string[] }
function M.yank(opts)
    local root, order, since = annotation_scope()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    require('iter.export').yank({
        root = root,
        config = M.config,
        order = order,
        ids = opts ~= nil and opts.ids or nil,
        on_clear = refresh_annotations,
        since = since,
    })
end

--- Remove every annotation of the repository after a confirm.
function M.clear()
    local root = annotation_scope()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    local store = require('iter.store')
    local annotations = store.cached(root, true).annotations
    local n = #annotations

    if n == 0 then
        util.warn('No annotations to clear')
        return
    end

    local question = n == 1 and 'Clear 1 annotation?'
        or string.format('Clear all %d annotations?', n)

    if vim.fn.confirm(question, 'Clear &x\n&No', 2) ~= 1 then
        return
    end

    local ids = vim.tbl_map(function(annotation)
        return annotation.id
    end, annotations)
    local _, err = store.remove_annotations(root, ids)

    if err ~= nil then
        util.error('Cannot clear the annotations: ' .. err)
        return
    end

    refresh_annotations()
end

--- Move the cursor to the next annotation of the current buffer, where its
--- text starts; after the last one it wraps to the first.
function M.next_annotation()
    require('iter.annotations.navigate').jump(1)
end

--- Move the cursor to the previous annotation of the current buffer, where
--- its text starts; before the first one it wraps to the last.
function M.prev_annotation()
    require('iter.annotations.navigate').jump(-1)
end

--- Toggle the annotation sidebar of the current tab; in the review's tab,
--- open or focus the review's annotations.
function M.sidebar()
    local review = open_review()

    if review ~= nil and vim.api.nvim_get_current_tabpage() == review.tab then
        review:focus_annotations()
        return
    end

    require('iter.ui.sidebar').toggle(M.config, refresh_annotations)
end

--- Open the review tab, or switch to it, with its annotations window open
--- and focused.
function M.annotations()
    M.review()

    local review = open_review()

    if review ~= nil then
        review:focus_annotations()
    end
end

--- `review · <file> · <i>/<n>` inside the review tab, `<branch> · <n>`
--- elsewhere in a repository, with `draft annotation` while an annotation
--- draft is hidden.
---@return string
function M.statusline()
    local parts = {}
    local review = M.current_review ~= nil and M.current_review:statusline()
        or ''

    if review ~= '' then
        table.insert(parts, review)
    else
        table.insert(parts, require('iter.statusline').get())
    end

    table.insert(parts, require('iter.annotations.editor').statusline())

    return table.concat(
        vim.tbl_filter(function(part)
            return part ~= ''
        end, parts),
        ' · '
    )
end

--- `iter://review/<path>#L<line>` for the cursor in the review's diff
--- pane, nil elsewhere. `:edit` of it, through `fnameescape()`, opens the
--- review there again.
---@return string?
function M.uri()
    local review = open_review()

    return review and review:uri()
end

--- Open or focus what the iter URI `name` addresses, as `:edit` of it
--- does, without escaping `#` first.
---@param name string
function M.open_uri(name)
    require('iter.uri').open(name)
end

--- A 'tabline' like the default one that labels a tab with its
--- `iter_label` tab variable, and counts only its normal windows.
---@return string
function M.tabline()
    return require('iter.tabline').render()
end

--- A 'statuscolumn' that shows what the default columns show, and draws an
--- annotation's bar on every screen row of a wrapped line.
---@return string
function M.statuscolumn()
    return require('iter.annotations.statuscolumn').get()
end

---@param opts IterOptions?
function M.setup(opts)
    local config = require('iter.config')
    M.config = config.resolve(opts)
    M.did_setup = true
    require('iter.annotations.marks').watch_buffers()
    require('iter.statusline').setup()

    return M
end

return M
