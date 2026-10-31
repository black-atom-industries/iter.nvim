local anchor = require('iter.annotations.anchor')
local changes_mod = require('iter.changes')
local document = require('iter.diff.document')
local editor = require('iter.annotations.editor')
local file_actions = require('iter.ui.file_actions')
local git = require('iter.git')
local model = require('iter.diff.model')
local help = require('iter.ui.help')
local hunk_actions = require('iter.ui.hunk_actions')
local layout = require('iter.ui.layout')
local panel = require('iter.ui.panel')
local picker = require('iter.ui.picker')
local Preview = require('iter.ui.preview')
local render = require('iter.ui.render')
local review_tree = require('iter.ui.review_tree')
local store = require('iter.store')
local tree = require('iter.ui.tree')
local uri = require('iter.uri')
local util = require('iter.util')
local reviewed = require('iter.reviewed')
local sidebar = require('iter.ui.sidebar')
local tab = require('iter.ui.tab')
local watch = require('iter.watch')

---@class IterReviewOpenOptions
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field base? IterBaseSpec what to compare with, remembered for the branch; the remembered one by default
---@field on_annotations? fun() after an annotation of the review is saved or deleted
---@field on_close? fun(review: IterReview)

---@class IterReview: IterTab
---@field diff_win integer
---@field panel IterPanel the window at the tab's left edge
---@field tree IterReviewTree the file tree page of the panel
---@field picker? IterPickerPage the base list page, while the panel shows it
---@field choices? IterBaseChoice[] the items of the base list
---@field summaries? table<integer, IterBaseSummary|false> the base list's summaries read so far, by item, false when the read failed
---@field summary? IterBaseSummary|false the summary the diff window shows, false when its read failed
---@field summary_buf? integer the summary's buffer, while the base list shows
---@field summary_winopts? table<string, any> the diff window's options from before the summary
---@field preview IterPreview the diff of the selected file
---@field view IterDiffView the preview's view in the diff window
---@field watch? IterWatch refreshes the review on external changes
---@field preview_timer? uv.uv_timer_t runs the last scheduled preview of a file or a base
---@field changes IterChanges the files of the review, read on every load
---@field annotations IterAnnotation[] stored annotations
---@field records table<string, IterReviewed> stored reviewed records against the current base
---@field reviewed table<string, IterReviewedState> state per file path of the tree
---@field expanded table<string, true> per path, reviewed files shown whole in all-files mode
---@field fresh? boolean read the store on the next load whatever its stat says
---@field quiet? boolean the tree's cursor moves come from the review, which previews itself
---@field annotations_closed boolean the user closed the annotations window; it stays closed until asked for
---@field help? IterHelp help float of the diff window or the tree
---@field config IterConfig
---@field preview_target? { id: string, file: IterChange|IterFileDiff } the annotation previewed last and the file it showed it in
---@field base_spec? IterBaseSpec what the review compares with, nil for working changes; resolved on every status read
---@field base_branch? string the branch `base_spec` belongs to, nil on a detached HEAD
---@field group integer
---@field closed boolean
---@field on_annotations? fun()
---@field on_close? fun(review: IterReview)
local Review = {}
Review.__index = Review

-- Recent commits the base list offers.
local PICKER_COMMITS = 20

local PREVIEW_DELAY_MS = 50

local BASE_PREVIEW_DELAY_MS = 150

-- Commits since a branch the base summary lists at most.
local BASE_COMMITS = 100

-- Glyph and group per reviewed state at the right of a tree row.
local REVIEWED_MARKS = {
    reviewed = { '✓', 'IterReviewed' },
    changed = { '↻', 'IterReviewedChanged' },
}

--- Remember `spec` as the base of the checked-out branch, nil for working
--- changes. A detached HEAD remembers nothing: every detached checkout
--- shares one store file.
---@param root string
---@param spec? IterBaseSpec
local function remember_base(root, spec)
    if git.head_branch(root) == nil then
        return
    end

    local _, err = store.set_base(root, spec)

    if err ~= nil then
        util.error('Cannot remember the base: ' .. err)
    end
end

--- Open the review tab after the current one: the file tree at its left
--- edge, the diff beside it and the annotations right of the diff, or
--- below the tree in a narrow tab. The tree gets the focus.
---@param opts IterReviewOpenOptions
---@return IterReview?
function Review.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.base', opts.base, 'table', true)
    vim.validate('opts.on_annotations', opts.on_annotations, 'function', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local root = git.root()
    local base_spec = opts.base

    if base_spec ~= nil then
        remember_base(root, base_spec)
    else
        base_spec = store.cached(root).base
    end

    require('iter.highlight').setup()

    local opened, diff_win = tab.open('iter review')

    local self = setmetatable({
        tab = opened.tab,
        origin_tab = opened.origin_tab,
        origin_win = opened.origin_win,
        diff_win = diff_win,
        buf = opened.buf,
        annotations = {},
        records = {},
        reviewed = {},
        expanded = {},
        annotations_closed = false,
        base_spec = base_spec,
        base_branch = git.head_branch(root),
        closed = false,
        on_annotations = opts.on_annotations,
        on_close = opts.on_close,
        config = opts.config,
    }, Review)

    -- The diff window belongs to the view, so a buffer that takes its place
    -- only hides it, and the review puts it back.
    self.preview = Preview.new({
        win = diff_win,
        config = opts.config,
        handlers = self:view_handlers(),
        bufhidden = 'hide',
        source = {
            changes = function()
                return self.changes
            end,
            files = function()
                return self:files()
            end,
            collapsed = function(item)
                return self:collapsed(item)
            end,
            shown = function()
                self:shown()
            end,
        },
        on_cursor = function()
            self:follow_view()
        end,
    })
    self.view = self.preview.view
    self.tree = review_tree.new({
        view = 'tree',
        keys = opts.config.keys.tree,
        handlers = self:tree_handlers(),
        header = function(width)
            return self:header(width)
        end,
        decorate = self:decorator(),
        hints = function()
            return self:hints()
        end,
        on_select = function(node)
            if not self.quiet and node.kind == 'file' then
                self:schedule_preview()
            end
        end,
    })

    if not self:load() then
        self.closed = true
        self.preview:close()
        self.tree:close()
        tab.close(self)
        return nil
    end

    self.panel = panel.open({
        width = opts.config.options.review.tree_width,
        on_close = function()
            self:close()
        end,
    })
    util.name_buf(self.tree.buf, uri.of('review'))
    uri.own(self.tree.buf, {
        owns = function(win)
            return win == self.panel.win
        end,
        reload = function()
            if self:is_open() then
                self:show_tree()
            end
        end,
    })

    self.quiet = true
    self.panel:show(self.tree)
    self.quiet = false

    local path = opts.path

    if path ~= nil and vim.startswith(path, self.changes.root .. '/') then
        path = path:sub(#self.changes.root + 2)
    end

    local first = self:paths()[1]

    if path == nil or self:file_at(path) == nil then
        path = first and first.path
    end

    if path == nil or not self:select_path(path) then
        self:render()
    end

    self:show_selection(true)
    self:attach()
    self:place_annotations()
    self.panel:focus()
    self.watch = watch.start({
        root = self.changes.root,
        poll_ms = opts.config.options.refresh.poll_ms,
        on_change = function(reason)
            self:refresh(reason)
        end,
    })

    return self
end

--- Whether `file` is the preview of a file outside the changes, which
--- takes no staging, annotations or reviewed marks; warns when it is.
---@param file IterFileDiff
---@return boolean
local function read_only(file)
    if file.side ~= 'commit' then
        return false
    end

    util.warn('The file has no changes in this review')

    return true
end

---@return table<string, fun()>
function Review:view_handlers()
    return {
        next_hunk = function()
            self.view:jump_hunk(1)
        end,
        prev_hunk = function()
            self.view:jump_hunk(-1)
        end,
        next_annotation = function()
            self.view:jump_annotation(1)
        end,
        prev_annotation = function()
            self.view:jump_annotation(-1)
        end,
        next_file = function()
            self:step_file(1)
        end,
        prev_file = function()
            self:step_file(-1)
        end,
        stage = function()
            self:apply_change('stage')
        end,
        unstage = function()
            self:apply_change('unstage')
        end,
        goto_file = function()
            self:goto_file()
        end,
        annotate = function()
            self:annotate()
        end,
        annotate_file = function()
            local file = self:shown_file()

            if file ~= nil and not read_only(file) then
                self:annotate_file(file.path)
            end
        end,
        edit = function()
            self:edit_annotation()
        end,
        delete = function()
            self:delete_annotation()
        end,
        expand = function()
            self:expand()
        end,
        reviewed = function()
            local file = self:shown_file()

            if file ~= nil and not read_only(file) then
                self:mark_reviewed(file.path, true)
            end
        end,
        unreviewed = function()
            local file = self:shown_file()

            if file ~= nil and not read_only(file) then
                self:unmark_reviewed(file.path)
            end
        end,
        mode = function()
            self:toggle_mode()
        end,
        split = function()
            self.preview:set_layout('split')
            self:render()
        end,
        unified = function()
            self.preview:set_layout('unified')
            self:render()
        end,
        wrap = function()
            self.preview:toggle_wrap()
        end,
        yank = function()
            self:yank_under_cursor()
        end,
        yank_all = function()
            require('iter').yank()
        end,
        close = function()
            self:close()
        end,
        help = function()
            self:toggle_help()
        end,
        focus_drawer = function()
            self:focus_tree()
        end,
    }
end

--- On the header of a collapsed file, show the whole file until the next
--- `=` into all-files mode or `r` marks it reviewed again; elsewhere expand
--- hidden context.
function Review:expand()
    local view = self.view
    local section, row = view:at()

    if section ~= nil and section.collapsed and row == 1 then
        self.expanded[section.file.path] = true
        view:expand_path(section.file.path)
    else
        view:expand()
    end
end

--- The file under the cursor of the diff pane.
---@return IterFileDiff?
function Review:shown_file()
    local view = self.view

    return view:is_shown() and view:file() or nil
end

--- The section of the diff pane between buffer lines `first` and `last`,
--- with the model rows on those lines, in the split layout of `side` or of
--- both sides; nil and a warning when they span two files or the file has
--- no changes in the review.
---@param first integer
---@param last integer
---@param side? 'old'|'new'
---@return IterDocSection?
---@return integer[] rows
function Review:selected_section(first, last, side)
    local section, rows = hunk_actions.section(self.view, first, last, side)

    if section == nil or read_only(section.file) then
        return nil, {}
    end

    return section, rows
end

--- Stage (`stage`) or unstage (`unstage`) the hunk under the cursor of the
--- diff pane, or the selected lines.
---@param kind 'stage'|'unstage'
function Review:apply_change(kind)
    hunk_actions.apply(kind, {
        view = self.view,
        root = self.changes.root,
        args = self.config.options.diff.args,
        section = function(first, last)
            return self:selected_section(first, last)
        end,
        refresh = function(path)
            self:refresh(nil, path)
        end,
    })
end

--- Annotations per path, review annotations left out.
---@param annotations IterAnnotation[]
---@return table<string, integer>
local function annotation_counts(annotations)
    local counts = {}

    for _, annotation in ipairs(annotations) do
        local path = annotation.anchor.path

        if annotation.scope ~= 'review' and path ~= nil then
            counts[path] = (counts[path] or 0) + 1
        end
    end

    return counts
end

--- Annotations on `file`; a nested repository counts those on the files
--- inside it.
---@param counts table<string, integer>
---@param file IterTreeFile
---@return integer
local function file_count(counts, file)
    if not file.items[1].dir then
        return counts[file.path] or 0
    end

    local count = 0

    for path, n in pairs(counts) do
        if vim.startswith(path, file.path) then
            count = count + n
        end
    end

    return count
end

--- Read the status, the changes since the base when there is one, and the
--- stored annotations and reviewed records. Once loaded, the review stays on
--- its root whatever the cwd becomes.
---@return boolean loaded
---@return boolean stored_changed the annotations or reviewed states changed
function Review:load()
    local snapshot =
        git.status_snapshot(self.changes and self.changes.root or nil)

    if snapshot.error ~= nil then
        util.error(snapshot.error, 'Cannot read the git status')
        return false, false
    end

    local result = changes_mod.build(snapshot)

    self.changes = result
    require('iter.statusline').update(result)

    local base = self:resolve_base(snapshot.root)

    if base ~= nil then
        local items, err =
            git.base_changes(snapshot.root, base.sha, snapshot.entries)

        if items == nil then
            util.error(err, 'Cannot read the changes since ' .. base.label)
            return false, false
        end

        result.base, result.since = items, base
    end

    local items = result.base
        or vim.list_extend(vim.list_extend({}, result.unstaged), result.staged)

    self.tree.root = tree.build(items)

    return true, self:load_store()
end

--- Read the stored annotations and reviewed records through the store cache,
--- and the reviewed state of every file of the tree. Files whose stat is
--- unchanged are not hashed again.
---@return boolean changed
function Review:load_store()
    local root = self.changes.root
    local before_annotations, before_reviewed = self.annotations, self.reviewed
    local data = store.cached(root, self.fresh)

    self.fresh = nil
    self.annotations = data.annotations
    self.records = reviewed.records(data, reviewed.base_key(self.base_spec))
    self.reviewed = reviewed.states(
        root,
        vim.tbl_map(function(file)
            return file.path
        end, self:paths()),
        self.records
    )

    local annotations_changed =
        not vim.deep_equal(before_annotations, self.annotations)

    if annotations_changed then
        self.view:set_annotations(self.annotations, root)
    end

    return annotations_changed
        or not vim.deep_equal(before_reviewed, self.reviewed)
end

--- A file row shows its staging state in working changes, its annotation
--- count and its reviewed mark at the right.
---@return fun(file: IterTreeFile): IterTreeDecor
function Review:decorator()
    local counts, annotations

    return function(file)
        if annotations ~= self.annotations then
            annotations = self.annotations
            counts = annotation_counts(annotations)
        end

        local right = {}
        local count = file_count(counts, file)
        local mark = not file.items[1].dir
            and REVIEWED_MARKS[self.reviewed[file.path]]

        if count > 0 then
            table.insert(right, { ' ✎' .. count, 'IterDrawerCount' })
        end

        table.insert(
            right,
            mark and { ' ' .. mark[1], mark[2] } or { '  ', 'IterDrawerHint' }
        )

        return { icon = tree.stage_icon(file.stage), right = right }
    end
end

--- The header of the tree: `Review HEAD <branch>` or `Review since <base>`,
--- what it lists with the number of files, and the reviewed progress.
---@param width integer
---@return IterRenderLine[]
function Review:header(width)
    local result = self.changes
    local since = result.since
    local title = { { ' Review', 'IterDrawerTitle' } }

    if since ~= nil then
        table.insert(
            title,
            { ' ' .. changes_mod.base_text(since), 'IterDrawerHint' }
        )
    else
        vim.list_extend(title, {
            { ' HEAD ', 'IterDrawerHint' },
            {
                result.branch == 'HEAD' and '(detached)' or result.branch,
                'IterHead',
            },
        })
    end

    local total = #self:paths()
    local what = since ~= nil and changes_mod.base_title(since)
        or 'Working changes'
    local progress = render.line('')

    -- Starts one cell in, as the title does, and keeps a cell to the edge.
    progress.text = layout.progress_cell(
        progress,
        reviewed.summary(self.reviewed) --[[@as IterLayoutProgress]],
        0,
        width - 1
    )

    return {
        render.chunks_line(title),
        render.chunks_line({
            {
                string.format(
                    ' %s · %d %s',
                    what,
                    total,
                    total == 1 and 'file' or 'files'
                ),
                'IterDrawerHint',
            },
        }),
        progress,
    }
end

--- The key hints at the bottom of the tree, two lines.
---@return [string, string][][]
function Review:hints()
    local all = { 'mode', self.preview.all_files and 'one file' or 'all' }
    local split = self.view.layout == 'split' and { 'unified', 'unified' }
        or { 'split', 'split' }

    if self.changes.base ~= nil then
        return {
            {
                { 'reviewed', 'reviewed' },
                { 'annotate_file', 'annotate' },
                { 'base', 'base' },
            },
            { all, split, { 'help', 'help' } },
        }
    end

    return {
        {
            { 'stage', 'stage' },
            { 'unstage', 'unstage' },
            {
                'reviewed',
                'reviewed',
            },
        },
        { { 'base', 'base' }, all, { 'help', 'help' } },
    }
end

--- The base the review compares with, resolved again; after a checkout the
--- one remembered for the new branch. A base that no longer resolves falls
--- back to working changes, with a warning, and is forgotten for the
--- branch, unless it was just read for a branch checked out since.
---@param root string
---@return IterChangesBase?
function Review:resolve_base(root)
    local branch = git.head_branch(root)
    local switched = branch ~= self.base_branch

    if switched then
        self.base_branch = branch
        self.base_spec = store.cached(root).base
        self.expanded = {}
    end

    local spec = self.base_spec

    if spec == nil then
        return nil
    end

    local label = changes_mod.base_label(spec)
    local sha, err = git.resolve_base(root, spec)

    if sha == nil then
        self.base_spec = nil

        if not switched and branch ~= nil then
            store.set_base(root, nil)
        end

        util.warn(
            string.format(
                'Cannot compare with %s (%s); showing working changes',
                label,
                err or 'unknown'
            )
        )
        return nil
    end

    return { kind = spec.kind, sha = sha, label = label }
end

--- The files of the review in tree order, one per path, nested
--- repositories left out.
---@return IterTreeFile[]
function Review:paths()
    return vim.tbl_filter(function(file)
        return not file.items[1].dir
    end, tree.files(self.tree.root))
end

--- The changes of the review in tree order, a partly staged path's
--- Unstaged change before its Staged one.
---@return IterChange[]
function Review:files()
    local items = {}

    for _, file in ipairs(self:paths()) do
        vim.list_extend(items, file.items)
    end

    return items
end

--- The file of the tree at `path`, matched by its path or its original path.
---@param path string
---@return IterTreeFile?
function Review:file_at(path)
    for _, file in ipairs(self:paths()) do
        if file.path == path then
            return file
        end
    end

    for _, file in ipairs(self:paths()) do
        for _, item in ipairs(file.items) do
            if item.orig_path == path then
                return file
            end
        end
    end

    return nil
end

--- Render the tree page when the panel shows it, the cursor kept on a row.
function Review:render()
    if not self.panel:is_open() or self.panel.page ~= self.tree then
        return
    end

    self.quiet = true
    self.panel:render()

    local lnum = self.tree.lnum
    local target = self.tree:nearest(lnum, 1)

    if target ~= nil and target ~= lnum then
        self.panel:set_cursor(target)
    end

    self.quiet = false
end

--- Show the tree in the panel again, with the cursor on the file it had.
function Review:show_tree()
    local file = self.tree:file()

    self.quiet = true
    self.panel:show(self.tree)
    self.quiet = false

    if file == nil or not self:select_path(file.path) then
        self:render()
    end
end

--- Put the tree's cursor on the row of `path`, a file or directory path,
--- opening the directories above it; the preview doesn't follow.
---@param path string
---@return boolean found
function Review:select_path(path)
    self.tree:open_to(path)
    self:render()

    local lnum = self.tree:line_of(path)

    if lnum == nil or self.panel.page ~= self.tree then
        return false
    end

    self.quiet = true
    self.panel:set_cursor(lnum)
    self.quiet = false

    return true
end

--- Run `fn` after `delay` ms, replacing a preview scheduled before that
--- still waits.
---@param self IterReview
---@param delay integer
---@param fn fun()
local function schedule(self, delay, fn)
    if self.closed then
        return
    end

    self.preview_timer = self.preview_timer or assert(vim.uv.new_timer())
    self.preview_timer:stop()
    self.preview_timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            if not self.closed then
                fn()
            end
        end)
    )
end

--- Preview the tree's file after `PREVIEW_DELAY_MS`, replacing a preview
--- scheduled before that still waits.
function Review:schedule_preview()
    schedule(self, PREVIEW_DELAY_MS, function()
        self:show_selection(false)
    end)
end

--- Show the diff of the tree's file, all its changes. A directory leaves
--- the diff as it is; an empty tree gives the diff window its own buffer
--- back. While the base list shows, the diff window keeps its summary,
--- read again when `force`.
---@param force boolean also when the view shows the file already
---@param keep_focus? boolean keep the focused annotation, as a refresh does
function Review:show_selection(force, keep_focus)
    if not self:is_open() then
        return
    end

    if self.picker ~= nil then
        if force then
            self.summaries = {}
            self:preview_base(self.picker:index())
        end

        return
    end

    local file = self.tree:file()

    if file == nil then
        if #self:paths() == 0 then
            self.preview.previewed = nil
            self.view:hide()
        end

        return
    end

    local previewed = self.preview.previewed

    if not keep_focus then
        self.view:set_focus(nil)
    end

    self.preview:show(file.items, force)

    -- The annotation the diff focuses stays what it previews, so the
    -- annotations window showing it again keeps the cursor.
    if
        keep_focus
        and self.view.focus ~= nil
        and previewed ~= nil
        and vim.startswith(previewed, 'annotation\0')
    then
        self.preview.previewed = previewed
    end
end

--- Name the view after what it shows, `iter://review/<path>` or in
--- all-files mode `iter://review#all`, and show the reviewed states.
function Review:shown()
    local file = self.view.files[1]

    if self.preview.all_files then
        self.view:set_name(uri.of('review') .. '#all')
    elseif file ~= nil then
        self.view:set_name(uri.of('review', file.path))
    end

    self.view:set_reviewed(self.reviewed)
end

--- In all-files mode, whether `item` shows its header row alone: a
--- reviewed file, unless `<CR>` or a jump to one of its annotations
--- expanded it.
---@param item IterChange
---@return boolean
function Review:collapsed(item)
    return self.reviewed[item.path] == 'reviewed'
        and not self.expanded[item.path]
end

--- Fire `User IterStage` for `paths` when the `action` on them succeeded.
---@param ok boolean
---@param action 'stage'|'unstage'|'discard'
---@param paths string[]
function Review:staged(ok, action, paths)
    if ok then
        util.emit('IterStage', {
            root = self.changes.root,
            paths = paths,
            action = action,
        })
    end
end

--- Reload the status, keep the cursor on its path, or on `target`, a
--- relative path, when given, and show its diff afresh. A poll that finds
--- the files unchanged leaves the diff as it is, renders only when the
--- annotations or reviewed states changed, and reads the diff again when
--- its file was written from outside.
---@param reason? IterWatchReason nil after an action of the review
---@param target? string
function Review:refresh(reason, target)
    if not self:is_open() then
        return
    end

    local before = self.changes
    local file = self.tree:file()
    local path = target or (file and file.path)
    local loaded, stored = self:load()

    if not loaded then
        return
    end

    local same = vim.deep_equal(before, self.changes)

    if reason == 'poll' and same then
        if stored then
            self:render()
        end

        file = self.tree:file()

        if
            file ~= nil
            and Preview.keys(file.items) == self.preview.previewed
            and self.preview:stat(file.items[1])
                ~= self.preview.previewed_stat
        then
            self:show_selection(true, true)
        end

        return
    end

    if path == nil or not self:select_path(path) then
        self:render()
    end

    self:show_selection(true, true)

    if reason == nil or not same then
        util.emit('IterRefresh', {
            root = self.changes.root,
            paths = changes_mod.paths(self.changes),
        })
    end
end

--- Read the changes afresh after the base changed, with the cursor on the
--- first file.
function Review:relist()
    if not self:is_open() or not self:load() then
        return
    end

    self.preview.diff_ids = nil
    self.preview.previewed, self.preview.all_shown = nil, false

    local first = self:paths()[1]

    if first == nil or not self:select_path(first.path) then
        self:render()
    end

    self:show_selection(true)
    util.emit('IterRefresh', {
        root = self.changes.root,
        paths = changes_mod.paths(self.changes),
    })
end

--- The path of the file the diff shows under its cursor, else the tree's.
---@return string?
function Review:current_path()
    local shown = self.view:is_shown() and self.view:file() or nil

    if self.preview.all_files and shown ~= nil then
        return shown.path
    end

    local file = self.tree:file()

    return file and file.path or (shown and shown.path)
end

--- Go to the next (`dir` 1) or previous (-1) file in tree order, also in
--- closed directories, which open: select it and show its diff now; in
--- all-files mode put its first section's header on top. At the last or
--- first file nothing changes.
---@param dir 1|-1
function Review:step_file(dir)
    local paths = self:paths()
    local current = self:current_path()
    local index = dir == 1 and 0 or #paths + 1

    for i, file in ipairs(paths) do
        if file.path == current then
            index = i
        end
    end

    local target = paths[index + dir]

    if target == nil then
        return
    end

    self:select_path(target.path)

    if not self.preview.all_files then
        self:show_selection(false)
        return
    end

    self.preview.previewed = Preview.keys(target.items)

    local view = self.view
    local section = document.find(view.document, Preview.key(target.items[1]))

    if section ~= nil then
        view:reveal(view.document.sections[section].first)
    end
end

--- In all-files mode, put the tree's cursor on the file under the diff's
--- cursor, without showing it again.
function Review:follow_view()
    if not self.preview.all_files or not self:is_open() then
        return
    end

    local shown = self.view:file()
    local file = self.tree:file()

    if shown == nil or (file ~= nil and file.path == shown.path) then
        return
    end

    local target = self:file_at(shown.path)

    if target ~= nil then
        self.preview.previewed = Preview.keys(target.items)
        self:select_path(target.path)
    end
end

--- Focus the tree, the review's tab first.
function Review:focus_tree()
    vim.api.nvim_set_current_tabpage(self.tab)
    self.panel:focus()
end

--- What the file actions work on.
---@return IterFileActionContext
function Review:action_context()
    return { changes = self.changes, config = self.config }
end

--- Refresh after `result`, an action's, and fire `User IterStage` for it.
---@param result? IterFileActionResult
function Review:after_action(result)
    if result == nil then
        return
    end

    if not result.ok then
        util.error(result.err, result.fallback)
    end

    self:refresh()

    if result.action ~= nil then
        self:staged(result.ok, result.action, result.paths)
    end
end

--- Stage (`stage`) or unstage (`unstage`) the tree's row: a file, or every
--- file below a directory that has such changes.
---@param kind 'stage'|'unstage'
function Review:stage_row(kind)
    local node = self.tree:node()

    if node == nil then
        return
    end

    local ctx = self:action_context()

    if node.kind == 'file' then
        self:after_action(file_actions[kind](ctx, node.items))
        return
    end

    local items = file_actions.below(tree.files(node), kind)

    if kind == 'stage' and #items == 0 and ctx.changes.base == nil then
        util.warn('Nothing to stage')
        return
    end

    self:after_action(file_actions[kind](ctx, items))
end

--- The tree's file for an action that works on one file; warns on a
--- directory.
---@return IterTreeFile?
function Review:row_file()
    local node = self.tree:node()

    if node ~= nil and node.kind == 'dir' then
        util.warn('Works on a file, not a directory')
        return nil
    end

    return node --[[@as IterTreeFile?]]
end

--- On a directory, close it or open it; on a file, `collapse` goes to its
--- directory and closes it.
---@param action 'toggle'|'collapse'|'expand'
function Review:fold(action)
    local dir = self.tree:fold(action)

    if dir ~= nil then
        self:select_path(dir.path)
    end
end

---@return table<string, fun()>
function Review:tree_handlers()
    return {
        open = function()
            local node = self.tree:node()

            if node == nil then
                return
            elseif node.kind == 'dir' then
                self:fold('toggle')
                return
            end

            self:show_selection(false)

            if self.view:is_shown() then
                vim.api.nvim_set_current_win(self.diff_win)
            end
        end,
        stage = function()
            self:stage_row('stage')
        end,
        unstage = function()
            self:stage_row('unstage')
        end,
        discard = function()
            local file = self:row_file()

            if file == nil then
                return
            end

            local item = file.items[1]

            for _, other in ipairs(file.items) do
                if other.side == 'unstaged' then
                    item = other
                end
            end

            self:after_action(file_actions.discard(self:action_context(), item))
        end,
        ignore = function()
            local file = self:row_file()

            if file ~= nil then
                self:after_action(
                    file_actions.ignore(self:action_context(), file.items[1])
                )
            end
        end,
        reviewed = function()
            local file = self:row_file()

            if file ~= nil then
                self:mark_reviewed(file.path, true)
            end
        end,
        unreviewed = function()
            local file = self:row_file()

            if file ~= nil then
                self:unmark_reviewed(file.path)
            end
        end,
        base = function()
            self:pick_base()
        end,
        mode = function()
            self:toggle_mode()
        end,
        split = function()
            self.preview:set_layout('split')
            self:render()
        end,
        unified = function()
            self.preview:set_layout('unified')
            self:render()
        end,
        wrap = function()
            self.preview:toggle_wrap()
        end,
        annotate_file = function()
            local file = self:row_file()

            if file ~= nil then
                self:annotate_file(file.path)
            end
        end,
        yank = function()
            local file = self.tree:file()

            if file ~= nil then
                self:yank_file(file.items[1])
            else
                require('iter').yank()
            end
        end,
        yank_all = function()
            require('iter').yank()
        end,
        collapse = function()
            self:fold('collapse')
        end,
        expand = function()
            self:fold('expand')
        end,
        close = function()
            self:close()
        end,
        help = function()
            self:toggle_help('tree')
        end,
        scroll_down = function()
            self.preview:scroll('<C-d>')
        end,
        scroll_up = function()
            self.preview:scroll('<C-u>')
        end,
    }
end

--- Compare the review with `spec`, nil for working changes, and remember
--- it for the branch, unless HEAD is detached.
---@param spec? IterBaseSpec
function Review:set_base(spec)
    remember_base(self.changes.root, spec)

    self.base_spec = spec
    self.expanded = {}
    self:relist()
end

---@class IterBaseChoice an item of the base list
---@field item IterPickerItem
---@field spec? IterBaseSpec nil for working changes
---@field commit? string abbreviated sha of a commit, resolved when picked

--- Pick what the review compares with in a list that takes the tree's
--- place: the merge base with the parent branch when there is one, working
--- changes, the other branches, then the recent commits. Without a parent,
--- as on the default branch, the merge base with the upstream follows
--- working changes. A picked commit is part of the review.
function Review:pick_base()
    local root = self.changes.root
    local head = git.head_branch(root)
    local parent = git.parent_branch(root)
    local recent = git.recent(root, PICKER_COMMITS)
    local merge = parent or (recent and recent.upstream)
    ---@type IterBaseChoice[]
    local choices = { { item = { label = 'Working changes' } } }

    if merge ~= nil then
        -- The list puts the cursor on its first item: the parent's merge
        -- base, else working changes.
        table.insert(choices, parent and 1 or 2, {
            item = {
                label = 'since ' .. merge,
                tag = parent and 'parent' or 'upstream',
            },
            spec = { kind = 'branch', ref = merge },
        })
    end

    local presets = #choices

    for _, branch in ipairs(git.branches(root) or {}) do
        if branch ~= merge and branch ~= head then
            table.insert(choices, {
                item = { label = branch },
                spec = { kind = 'branch', ref = branch },
            })
        end
    end

    local branches = #choices

    for _, commit in ipairs(recent and recent.commits or {}) do
        table.insert(choices, {
            item = {
                label = function(width)
                    return layout.commit_short(commit, width)
                end,
            },
            commit = commit.sha,
        })
    end

    ---@type table<integer, string>
    local sections = {}

    if branches > presets then
        sections[presets + 1] = 'Branches'
    end

    if #choices > branches then
        sections[branches + 1] = 'Commits'
    end

    local function back()
        local page = self.picker

        self.picker, self.choices, self.summaries = nil, nil, nil

        if self.preview_timer ~= nil then
            self.preview_timer:stop()
        end

        self:hide_summary()

        if not self.closed and self.panel:is_open() then
            self:show_tree()
            self.panel:focus()
        end

        if page ~= nil then
            page:close()
        end
    end

    if self.picker ~= nil then
        self.picker:close()
    end

    ---@type IterPickerPage
    local page
    page = picker.page({
        title = 'Base of the review',
        items = vim.tbl_map(function(choice)
            return choice.item
        end, choices),
        sections = sections,
        keys = self.config.keys.picker,
        on_close = function()
            back()
            self:show_selection(true)
        end,
        on_select = function(index)
            schedule(self, BASE_PREVIEW_DELAY_MS, function()
                if self.picker == page then
                    self:preview_base(index)
                end
            end)
        end,
        on_pick = function(index)
            if self.closed then
                return
            end

            local choice = choices[index]
            local spec = choice.spec

            if choice.commit ~= nil then
                local sha, err = git.commit_sha(root, choice.commit)

                if sha == nil then
                    util.error(err, 'Unknown commit ' .. choice.commit)
                    return
                end

                spec = { kind = 'commit', sha = sha }
            end

            back()
            self:set_base(spec)
        end,
    })
    self.picker, self.choices, self.summaries = page, choices, {}
    util.name_buf(page.buf, uri.of('review') .. '#base')
    uri.own(page.buf, {
        owns = function(win)
            return win == self.panel.win
        end,
        reload = function()
            if self.panel.page == page then
                self.panel:render()
            end
        end,
    })
    self:guard_page(page.buf)
    self.panel:show(page)
    self.panel:focus()
end

--- Open the base list, or focus it while it shows.
function Review:show_base_list()
    if self.picker ~= nil and self.panel.page == self.picker then
        self.panel:focus()
    else
        self:pick_base()
    end
end

--- The working changes' paths and their untracked ones.
---@param changes IterChanges
---@return integer working
---@return integer untracked
local function working_counts(changes)
    local paths, untracked = {}, 0

    for _, list in ipairs({ changes.unstaged, changes.staged }) do
        for _, item in ipairs(list) do
            paths[item.path] = true

            if item.code == '?' then
                untracked = untracked + 1
            end
        end
    end

    return vim.tbl_count(paths), untracked
end

--- What the review brings in against `choice`, read from git.
---@param choice IterBaseChoice
---@return IterBaseSummary?
---@return string? error
function Review:base_summary(choice)
    local root = self.changes.root
    local working, untracked = working_counts(self.changes)
    ---@type IterBaseSummary
    local summary = {
        kind = 'working',
        label = 'Working changes',
        head = git.head_branch(root),
        commits = {},
        more = 0,
        working = working,
        untracked = untracked,
        stats = {},
    }
    local base, err, stats

    if choice.commit ~= nil then
        local sha
        sha, err = git.commit_sha(root, choice.commit)

        if sha == nil then
            return nil, err
        end

        base, err = git.parent_of(root, sha)

        if base == nil then
            return nil, err
        end

        local commits
        commits, err = git.messages(root, sha, 'HEAD')

        if commits == nil then
            return nil, err
        end

        summary.kind, summary.label = 'commit', choice.commit
        summary.commits, summary.commit = commits, commits[#commits]
    elseif choice.spec ~= nil then
        base, err = git.resolve_base(root, choice.spec)

        if base == nil then
            return nil, err
        end

        local commits, more
        commits, err, more =
            git.messages_since(root, base, 'HEAD', BASE_COMMITS)

        if commits == nil then
            return nil, err
        end

        summary.kind, summary.label, summary.sha =
            'branch', choice.spec.ref, base
        summary.commits, summary.more = commits, more
    end

    -- Before the first commit the working changes are all additions.
    base = base or git.commit_sha(root, 'HEAD') or git.empty_tree(root)

    if base == nil then
        return nil, 'Cannot read the empty tree'
    end

    stats, err = git.stats(root, base)

    if stats == nil then
        return nil, err
    end

    summary.stats = stats

    return summary
end

--- Show what base list item `index` brings in, in the diff window. Each
--- item is read once while the list shows; a refresh reads them again.
---@param index? integer
function Review:preview_base(index)
    if index == nil or self.choices == nil then
        return
    end

    local summary = self.summaries[index]

    if summary == nil then
        local read, err = self:base_summary(self.choices[index])

        if read == nil then
            util.error(err, 'Cannot read the base')
        end

        summary = read or false
        self.summaries[index] = summary
    end

    if not util.is_valid_win(self.diff_win) then
        return
    end

    self.summary = summary
    self:render_summary()
    vim.api.nvim_win_set_cursor(self.diff_win, { 1, 0 })
end

--- Draw the summary for the diff window's width and show it there, in the
--- view's place.
function Review:render_summary()
    local buf = self.summary_buf

    if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = 'hide'
        vim.bo[buf].modifiable = false
        vim.bo[buf].filetype = 'iter'
        util.name_buf(buf, uri.of('review') .. '#base#preview')
        uri.own(buf, {
            owns = function(win)
                return win == self.diff_win
            end,
            reload = function()
                if self.summary_buf == buf then
                    self:render_summary()
                end
            end,
        })
        vim.api.nvim_create_autocmd('BufWinLeave', {
            group = self.group,
            buffer = buf,
            callback = function()
                if vim.api.nvim_get_current_win() == self.diff_win then
                    vim.schedule(function()
                        self:take_back_summary(buf)
                    end)
                end
            end,
        })
        self.summary_buf = buf
    end

    local lines = self.summary
            and layout.base_summary(
                self.summary,
                vim.api.nvim_win_get_width(self.diff_win)
            )
        or {
            render.chunks_line({
                { ' Cannot read this base', 'IterDrawerHint' },
            }),
        }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render.text_lines(lines))
    vim.bo[buf].modifiable = false
    render.apply(buf, lines)

    if vim.api.nvim_win_get_buf(self.diff_win) ~= buf then
        self.view:hide()
    end

    self.summary_winopts =
        tab.show_summary(self.diff_win, buf, self.summary_winopts)
end

--- Give the diff window its own buffer and options back from the summary,
--- and wipe the summary.
function Review:hide_summary()
    local buf = self.summary_buf

    self.summary_buf, self.summary = nil, nil

    if buf == nil then
        return
    end

    if
        util.is_valid_win(self.diff_win)
        and vim.api.nvim_win_get_buf(self.diff_win) == buf
    then
        vim.api.nvim_win_set_buf(self.diff_win, self.buf)
        tab.hide_summary(self.diff_win, self.summary_winopts)
    end

    self.summary_winopts = nil

    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

--- Show the summary `buf` in the diff window again after another buffer
--- took its place, and open a file buffer in the tab the review came from.
---@param buf integer
function Review:take_back_summary(buf)
    if
        self.closed
        or self.summary_buf ~= buf
        or not util.is_valid_win(self.diff_win)
        or vim.api.nvim_win_get_buf(self.diff_win) == buf
    then
        return
    end

    local path, line = self:file_in(self.diff_win)

    vim.api.nvim_win_set_buf(self.diff_win, buf)
    self:render_summary()
    vim.api.nvim_win_call(self.diff_win, function()
        vim.cmd.clearjumps()
    end)

    if path ~= nil then
        self:open_file(path, line)
    end
end

--- The paths of `files`, a renamed file's original path after its new one.
---@param files IterTreeFile[]
---@return string[]
local function file_order(files)
    local order = {}

    for _, file in ipairs(files) do
        table.insert(order, file.path)

        for _, item in ipairs(file.items) do
            if item.orig_path ~= nil then
                table.insert(order, item.orig_path)
                break
            end
        end
    end

    return order
end

Review.file_order = file_order

--- The files of `changes` whose diff can place `annotation`, the side of
--- its old version first.
---@param changes IterChanges
---@param annotation IterAnnotation
---@return IterChange[]
local function annotation_files(changes, annotation)
    local a = annotation.anchor
    local found = {}

    if annotation.scope == 'review' or a.path == nil then
        return found
    end

    local sides = a.side == 'old'
            and a.base == 'HEAD'
            and { 'staged', 'unstaged' }
        or { 'unstaged', 'staged' }

    if changes.base ~= nil then
        sides = { 'base' }
    end

    for _, side in ipairs(sides) do
        for _, item in ipairs(changes[side]) do
            if
                not item.dir
                and (item.path == a.path or item.orig_path == a.path)
            then
                table.insert(found, item)
            end
        end
    end

    return found
end

--- The line of `view` `annotation` sits below, in `file` when given, nil
--- when it isn't placed there; in a collapsed file its header row, with the
--- file's section index.
---@param view IterDiffView
---@param annotation IterAnnotation
---@param file? IterChange|IterFileDiff
---@return integer?
---@return integer? collapsed section index of the file, when collapsed
local function annotation_row(view, annotation, file)
    if not view:is_shown() then
        return nil
    end

    local sections = view.document.sections

    for _, mark in ipairs(view.marks) do
        if
            mark.annotation.id == annotation.id
            and (
                file == nil
                or sections[mark.section].key == document.key(file)
            )
        then
            return mark.lnum, mark.hidden and mark.section or nil
        end
    end

    return nil
end

--- Show the file of `annotation`, which the changes don't list, in the
--- diff pane: its `HEAD` version, read-only, every line as context. A file
--- `HEAD` lacks shows as it is on disk.
---@param annotation IterAnnotation
---@return boolean shown false when the file exists in neither
function Review:show_outside(annotation)
    local root = self.changes.root
    local path = annotation.anchor.path --[[@as string]]
    local lines = git.blob_lines(root, 'HEAD:' .. path)

    if lines == nil then
        local abs = vim.fs.joinpath(root, path)

        if vim.uv.fs_stat(abs) == nil then
            return false
        end

        lines = vim.fn.readfile(abs)
    end

    local file = model.build({
        path = path,
        side = 'commit',
        base = 'HEAD',
        head = 'HEAD',
        code = ' ',
    }, { raw = {}, old_lines = lines, new_lines = lines, binary = false })

    model.expand(file, 2, #lines)
    self.preview.all_shown = false
    self.view:set_new_follows(true)
    self.view:show(file)
    self:shown()

    return true
end

--- Show the diff of the tree's file that holds `item`, all its changes,
--- with the tree's cursor on it.
---@param item IterChange
---@param force boolean
function Review:show_item(item, force)
    local file = self:file_at(item.path)

    if file ~= nil then
        self:select_path(file.path)
    end

    self.preview:show(file and file.items or { item }, force)
end

---@class IterReviewRow an annotation the review previews
---@field key string
---@field annotation IterAnnotation
---@field start? integer

--- Show an annotation in the diff window: the diff of the annotation's
--- file with the annotation focused and in view, or the file at `HEAD` when
--- the changes don't list it. Shown again, after a refresh, the diff cursor
--- stays where it is. A review annotation keeps the diff as it is.
---@param item IterReviewRow
---@param force boolean
function Review:preview_annotation(item, force)
    if self.picker ~= nil then
        return
    end

    local annotation = item.annotation
    local files = annotation and annotation_files(self.changes, annotation)
        or {}
    local view = self.view
    local again = self.preview.previewed == item.key

    if
        annotation ~= nil
        and #files == 0
        and annotation.scope ~= 'review'
        and annotation.anchor.path ~= nil
    then
        if not self:show_outside(annotation) then
            view:set_focus(nil)
            return
        end

        view:set_focus(annotation.id)

        local row = annotation_row(view, annotation)

        self.preview_target = { id = annotation.id, file = view.files[1] }

        if row ~= nil and not again then
            view:reveal(row, 'center')
        end

        return
    end

    if annotation == nil or #files == 0 then
        view:set_focus(nil)
        return
    end

    view:set_focus(annotation.id)

    -- A diff where the annotation sits below a gap hides its code; the
    -- next side may show it.
    local lnum, placed, shown

    for _, file in ipairs(files) do
        self:show_item(file, force)

        local row = annotation_row(view, annotation, file)

        if row ~= nil then
            placed = placed or { file = file, lnum = row }

            if
                view.rows[row].kind ~= 'gap'
                and (
                    annotation.scope == 'file'
                    or view.rows[row].kind ~= 'header'
                )
            then
                lnum, shown = row, file
                break
            end
        end
    end

    if lnum == nil then
        self:show_item(placed and placed.file or files[1], force)

        if placed == nil then
            return
        end

        lnum, shown = placed.lnum, placed.file
    end

    self.preview_target = { id = annotation.id, file = shown }

    if again then
        return
    end

    view:reveal(lnum, 'center')
end

--- Move into the diff pane at the selected annotation, showing a
--- collapsed file whole. One on a file outside the changes opens in the tab the review came from, a review
--- annotation in the editor.
---@param item IterReviewRow
---@param previewed? boolean the diff shows the annotation already
function Review:jump_to(item, previewed)
    local annotation = item.annotation

    if annotation == nil or self.picker ~= nil then
        return
    end

    if annotation.scope == 'review' then
        self:open_editor(annotation)
        return
    end

    local a = annotation.anchor

    if #annotation_files(self.changes, annotation) == 0 then
        local path = vim.fs.joinpath(self.changes.root, a.path)

        if vim.uv.fs_stat(path) == nil then
            util.warn(a.path .. ' is deleted')
            return
        end

        self:open_file(path, item.start or a.start_line or 1)
        return
    end

    if not previewed then
        self:preview_annotation(item, false)
    end

    local target = self.preview_target
    local file = target ~= nil and target.id == annotation.id and target.file
        or nil
    local view = self.view
    local lnum, collapsed = annotation_row(view, annotation, file)

    if collapsed ~= nil then
        local path = view.document.sections[collapsed].file.path

        self.expanded[path] = true
        view:expand_path(path)
        lnum = annotation_row(view, annotation, file)
    end

    if lnum ~= nil then
        view:reveal(lnum)
        vim.api.nvim_set_current_win(self.diff_win)
    end
end

--- The row the review previews for `item`, an annotation of the sidebar.
---@param item IterAnnotationItem
---@return IterReviewRow
local function sidebar_row(item)
    return {
        key = 'annotation\0' .. item.annotation.id,
        annotation = item.annotation,
        start = item.start,
    }
end

--- Show `item`, an annotation of the sidebar, in the diff window, unless
--- the window shows it already.
---@param item IterAnnotationItem
---@param force? boolean
function Review:preview_note(item, force)
    local row = sidebar_row(item)

    if force or self.preview.previewed ~= row.key then
        self:preview_annotation(row, force == true)
        self.preview.previewed = row.key
    end
end

--- What the sidebar does for the review: the tree's file order, the files
--- it lists, previews in the diff window, `<CR>` into it, `<C-j>` back to
--- the tree and `q` closing the review. Closed by the user, the window
--- stays closed until asked for.
---@return IterSidebarMode
function Review:sidebar_mode()
    ---@type IterSidebarMode
    local mode

    mode = {
        order = function()
            return file_order(self:paths())
        end,
        changed = function()
            local changed = {}

            for _, path in ipairs(file_order(self:paths())) do
                changed[path] = true
            end

            return changed
        end,
        on_cursor = function(item)
            if self.closed then
                return
            end

            if item == nil then
                self.view:set_focus(nil)
                return
            end

            self:preview_note(item)
        end,
        jump = function(item)
            if self.closed then
                return
            end

            self:preview_note(item)
            self:jump_to(sidebar_row(item), true)
        end,
        handlers = {
            focus_drawer = function()
                self:focus_tree()
            end,
            close = function()
                self:close()
            end,
        },
        on_close = function()
            self.annotations_closed = true
        end,
    }

    return mode
end

--- Whether the annotations sit below the tree: in a tab narrower than
--- `annotate.review_breakpoint`.
---@return boolean
function Review:narrow()
    return vim.o.columns < self.config.options.annotate.review_breakpoint
end

--- Open the annotations window right of the diff, or below the tree in a
--- narrow tab, with the cursor on the annotation with `id` when given. The
--- focus stays where it is.
---@param id? string
function Review:open_sidebar(id)
    if vim.api.nvim_get_current_tabpage() ~= self.tab then
        return
    end

    local opened = sidebar.open_review(
        self.config,
        self.changes.root,
        function()
            if self.on_annotations ~= nil then
                self.on_annotations()
            end
        end,
        self:sidebar_mode(),
        self:narrow()
                and {
                    below = self.panel.win,
                    -- A third of the column, so the tree keeps its key hints.
                    height = math.max(5, math.floor(self.panel:height() / 3)),
                }
            or nil
    )

    if id ~= nil then
        opened:select(id)
    end
end

--- Give the annotations right of the diff their configured width, and the
--- tree its own with `with_tree`, taking the cells from the diff's panes, which
--- then even out.
---@param self IterReview
---@param with_tree boolean
local function fit_widths(self, with_tree)
    local fixed = {}

    for _, win in ipairs({ self.view.win, self.view.old and self.view.old.win }) do
        if util.is_valid_win(win) then
            fixed[win] = vim.wo[win].winfixwidth
            vim.wo[win].winfixwidth = false
        end
    end

    if with_tree then
        self.panel:restore_width()
    end

    local open = sidebar.of(self.tab)

    if
        open ~= nil
        and open.placement == nil
        and util.is_valid_win(open.win)
    then
        vim.api.nvim_win_set_width(open.win, self.config.options.annotate.width)
    end

    for win, fix in pairs(fixed) do
        vim.wo[win].winfixwidth = fix
    end

    self.view:even_widths()
end

--- Put the annotations window where the tab's width wants it, right of
--- the diff from `annotate.review_breakpoint` tab columns, else below the
--- tree; the selected annotation and the focus stay. A window the user
--- closed stays closed.
function Review:place_annotations()
    if
        self.closed
        or self.annotations_closed
        or vim.api.nvim_get_current_tabpage() ~= self.tab
        or not self.panel:is_open()
    then
        return
    end

    local open = sidebar.of(self.tab)
    local below = self:narrow() and self.panel.win or nil

    if
        open ~= nil
        and open.mode ~= nil
        and (open.placement and open.placement.below) == below
    then
        return
    end

    local id, focused

    if open ~= nil then
        local row = open:row()

        id = row and row.item and row.item.annotation.id
        focused = vim.api.nvim_get_current_win() == open.win
        -- Moved, not closed by the user.
        open.mode = nil
        open:close()
    end

    local current = vim.api.nvim_get_current_win()

    self:open_sidebar(id)
    fit_widths(self, true)

    local opened = sidebar.of(self.tab)

    if focused and opened ~= nil then
        opened:focus()
    elseif util.is_valid_win(current) then
        vim.api.nvim_set_current_win(current)
    else
        self.panel:focus()
    end
end

--- Open the annotations window, or focus it, in the review's tab.
function Review:focus_annotations()
    vim.api.nvim_set_current_tabpage(self.tab)
    self.annotations_closed = false
    self:place_annotations()

    local open = sidebar.of(self.tab)

    if open ~= nil then
        open:focus()
    end
end

--- The row of `file` nearest to new-side line `line`: the row of that
--- line, else the gap that hides it, else the closest line.
---@param file IterFileDiff
---@param line integer
---@return integer?
local function row_of_line(file, line)
    local best, distance

    for index, row in ipairs(file.rows) do
        local d

        if row.gap ~= nil then
            local first = row.gap.new
            local last = first + row.gap.count - 1

            d = line < first and first - line or math.max(0, line - last)
        elseif row.new ~= nil then
            d = math.abs(line - row.new)
        end

        if d ~= nil and (distance == nil or d < distance) then
            best, distance = index, d
        end
    end

    return best
end

--- Select the file at `path`, relative to the root, and show its diff;
--- with `line` move into the diff window at that new-side line of its
--- first section, showing a collapsed file whole and the context around
--- the line. A path outside the changes warns.
---@param path string
---@param line? integer
function Review:reveal(path, line)
    local found

    for _, file in ipairs(self:paths()) do
        if file.path == path then
            found = file
        end
    end

    if found == nil then
        util.warn(path .. ' is not in the changes')
        return
    end

    local item = found.items[1]

    self:select_path(path)
    self:show_selection(false)

    if line == nil then
        return
    end

    local view = self.view
    local index = document.find(view.document, document.key(item))

    if index == nil then
        return
    end

    if view.document.sections[index].collapsed then
        self.expanded[item.path] = true
        view:expand_path(item.path)
    end

    local section = view.document.sections[index]

    local file = section.file
    local row = row_of_line(file, line)

    -- Context a gap hides shows in batches until the line does.
    while row ~= nil and file.rows[row].gap ~= nil do
        local gap = file.rows[row].gap
        local at_gap = document.line_of(view.document, index, row)

        if at_gap == nil or line < gap.new or line >= gap.new + gap.count then
            break
        end

        local rows, hidden = #file.rows, gap.count

        view:expand(at_gap)

        if
            #file.rows == rows
            and file.rows[row].gap == gap
            and gap.count == hidden
        then
            break
        end

        row = row_of_line(file, line)
    end

    local lnum = row and document.line_of(view.document, index, row)

    if lnum ~= nil then
        vim.api.nvim_set_current_win(self.diff_win)
        view:reveal(lnum, 'center')
    end
end

--- `iter://review/<path>#L<line>` for the cursor of the diff pane, with the
--- worktree line of the cursor row; nil outside the diff pane or between
--- two files.
---@return string?
function Review:uri()
    local view = self.view
    local win = vim.api.nvim_get_current_win()

    if
        not self:is_open()
        or not view:is_shown()
        or (win ~= view.win and not (view.old ~= nil and view.old.win == win))
    then
        return nil
    end

    local section, row = view:at()

    if section == nil or row == nil then
        return nil
    end

    return uri.of(
        'review',
        section.file.path,
        self.preview:worktree_line(section.file, row)
    )
end

--- Read the stored annotations again whatever the store file's stat says,
--- then refresh the review. For writes of this instance, which can keep the
--- stat.
function Review:refresh_annotations()
    self.fresh = true
    self:refresh()
end

--- Mark `path` reviewed and refresh. In all-files mode the file collapses.
--- With `advance` the tree moves on to the next file in tree order that is
--- not reviewed.
---@param path string
---@param advance? boolean
function Review:mark_reviewed(path, advance)
    local _, err = reviewed.set(
        self.changes.root,
        path,
        true,
        reviewed.base_key(self.base_spec)
    )

    if err ~= nil then
        util.error('Cannot mark reviewed: ' .. err)
        return
    end

    self.expanded[path] = nil

    local order = self:paths()

    self:refresh_annotations()

    if not advance then
        return
    end

    local after = false

    for _, file in ipairs(order) do
        if
            after
            and file.path ~= path
            and self.reviewed[file.path] ~= 'reviewed'
        then
            self:advance_to(file.path)
            return
        end

        after = after or file.path == path
    end
end

--- Remove the reviewed mark of `path` and refresh. The selection stays.
---@param path string
function Review:unmark_reviewed(path)
    local _, err = reviewed.set(
        self.changes.root,
        path,
        false,
        reviewed.base_key(self.base_spec)
    )

    if err ~= nil then
        util.error('Cannot unmark reviewed: ' .. err)
        return
    end

    self.expanded[path] = nil
    self:refresh_annotations()
end

--- Select the file at `path` and show it with its header at the top of
--- the diff window and the cursor on its first change, or on the header
--- without one. Focus stays where it is.
---@param path string
function Review:advance_to(path)
    local file = self:file_at(path)

    if file == nil then
        return
    end

    self:select_path(path)
    self:show_selection(false)

    local view = self.view
    local index = document.find(view.document, Preview.key(file.items[1]))

    if index == nil then
        return
    end

    local section = view.document.sections[index]

    view:reveal(section.first, 'top')

    for row, file_row in ipairs(section.file.rows) do
        if file_row.kind == 'add' or file_row.kind == 'del' then
            local lnum = document.line_of(view.document, index, row)

            if lnum ~= nil then
                local active = view:active()

                vim.api.nvim_win_set_cursor(active.win, { lnum, 0 })
                view:sync(active)
            end

            return
        end
    end
end

--- Open the help float with the keys of the diff window, or of the tree
--- with `view` 'tree', or close it.
---@param view? 'diff'|'tree'
function Review:toggle_help(view)
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    local config = self.config
    local tree_view = view == 'tree'

    self.help = help.open({
        view = tree_view and 'tree' or 'diff',
        keys = tree_view and config.keys.tree or self.view.keys,
        handlers = tree_view and self.tree.opts.handlers or self.view.handlers,
        close_keys = config.keys.help,
        zindex = config.options.drawer.zindex + 10,
    })
end

function Review:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.review.' .. self.buf,
        { clear = true }
    )

    -- A file opened in the left pane of the split layout opens in the tab
    -- the review came from, as one opened in the diff pane does.
    self.view.on_pane_replaced = function(buf, line)
        local path = vim.bo[buf].buftype == ''
                and vim.api.nvim_buf_get_name(buf)
            or ''

        if not self.closed and path ~= '' then
            self:open_file(path, line)
        end
    end

    vim.api.nvim_create_autocmd({ 'VimResized', 'TabEnter' }, {
        group = self.group,
        callback = function()
            vim.schedule(function()
                self:place_annotations()
            end)
        end,
    })
    vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = self.group,
        callback = function(args)
            if
                args.event == 'WinResized'
                and not tab.has_window(self, vim.v.event.windows)
            then
                return
            end

            self:resized()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = tostring(self.diff_win),
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = self.group,
        buffer = self.view.buf,
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = self.view.buf,
        callback = function()
            if vim.api.nvim_get_current_win() ~= self.diff_win then
                return
            end

            local cursor = vim.api.nvim_win_get_cursor(self.diff_win)

            vim.schedule(function()
                self:take_back(cursor)
            end)
        end,
    })
    self:guard_page(self.tree.buf)
end

--- Take the panel back when another buffer takes the place of the page
--- buffer `buf`, as `:edit` does.
---@param buf integer
function Review:guard_page(buf)
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = buf,
        callback = function()
            if vim.api.nvim_get_current_win() ~= self.panel.win then
                return
            end

            vim.schedule(function()
                self:take_back_list()
            end)
        end,
    })
end

--- After a resize: the 'auto' diff layout, the tree for the new size, even
--- split panes and wrapped lines.
function Review:resized()
    if not self:is_open() then
        return
    end

    self.preview:resized()
    self:render()
    fit_widths(self, false)
    self.view:rewrap()

    if
        self.summary ~= nil
        and vim.api.nvim_win_get_buf(self.diff_win) == self.summary_buf
    then
        self:render_summary()
    end
end

--- The file buffer that took the place of the tree or the diff, when
--- `win` shows one.
---@param win integer
---@return string? path
---@return integer line
function Review:file_in(win)
    local buf = vim.api.nvim_win_get_buf(win)
    local path = vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf)
        or ''

    return path ~= '' and path or nil, vim.api.nvim_win_get_cursor(win)[1]
end

--- Show the diff in the diff pane again after another buffer took its
--- place. A file buffer opens in the tab the review came from instead, at
--- the line it was opened on.
---@param cursor integer[] the diff pane's cursor before it changed
function Review:take_back(cursor)
    local view = self.view

    if
        self.closed
        or self.picker ~= nil
        or not util.is_valid_win(self.diff_win)
        or self.preview.previewed == nil
        or #view.document.sections == 0
        or view:is_shown()
    then
        return
    end

    local path, line = self:file_in(self.diff_win)

    -- The scratch buffer first, so the view borrows the pane from it again.
    vim.api.nvim_win_set_buf(self.diff_win, self.buf)
    view:show_document(view.document)
    vim.api.nvim_win_set_cursor(
        self.diff_win,
        { math.min(cursor[1], vim.api.nvim_buf_line_count(view.buf)), 0 }
    )
    -- The switches left jumps to the other buffer and to the scratch.
    vim.api.nvim_win_call(self.diff_win, function()
        vim.cmd.clearjumps()
    end)

    if path ~= nil then
        self:open_file(path, line)
    end
end

--- Show the panel's page again, the base list while it is open, else the
--- tree, after another buffer took its place, and open a file buffer in
--- the tab the review came from instead.
function Review:take_back_list()
    local win = self.panel.win

    local shown = self.panel:is_open() and vim.api.nvim_win_get_buf(win)
    local page = self.picker or self.tree

    -- One of the panel's own pages taking the other's place stays.
    if
        self.closed
        or not shown
        or shown == self.tree.buf
        or (self.picker ~= nil and shown == self.picker.buf)
    then
        return
    end

    local path, line = self:file_in(win)

    if page == self.tree then
        self:show_tree()
    else
        self.panel:show(page)
    end
    vim.api.nvim_win_call(win, function()
        vim.cmd.clearjumps()
    end)

    if path ~= nil then
        self:open_file(path, line)
    end
end

---@return boolean
function Review:is_open()
    return not self.closed and vim.api.nvim_tabpage_is_valid(self.tab)
end

--- What the review compares with while it is open on `root` against a
--- base, else nil.
---@param root string
---@return IterChangesBase?
function Review:since(root)
    local result = self:is_open() and self.changes or nil

    return result ~= nil and result.root == root and result.since or nil
end

--- Switch to the tab, focus the tree and reload.
function Review:focus()
    self:focus_tree()
    self:refresh()
end

--- Close the tab and go back to the tab the review came from.
function Review:close()
    if self.closed then
        return
    end

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if self.help ~= nil then
        self.help:close()
    end

    if self.watch ~= nil then
        self.watch:stop()
    end

    if self.preview_timer ~= nil then
        self.preview_timer:stop()
        self.preview_timer:close()
        self.preview_timer = nil
    end

    if self.panel ~= nil then
        self.panel:close({ silent = true })
    end

    local open = sidebar.of(self.tab)

    if open ~= nil then
        open.mode = nil
    end

    tab.close(self)

    -- With its windows gone, the view only wipes its buffer.
    self.preview:close()
    self:hide_summary()

    for _, page in ipairs({ self.tree, self.picker }) do
        page:close()
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

--- `review · <file> · <i>/<n>` for windows of the tab, `''` elsewhere,
--- with `all files` after `review` in all-files mode, where the file is the
--- one under the cursor, and then `split` in the split layout. The position
--- counts files in tree order. While the base list shows, `review · base ·
--- <i>/<n>` counts its items.
---@return string
function Review:statusline()
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()

    if
        not self:is_open()
        or not util.is_valid_win(win)
        or vim.api.nvim_win_get_tabpage(win) ~= self.tab
    then
        return ''
    end

    local page = self.picker

    if page ~= nil and self.panel.page == page then
        return string.format(
            'review · base · %d/%d',
            page:index() or 0,
            #page.opts.items
        )
    end

    local file = self:shown_file()
    local mode = self.preview.all_files and 'review · all files' or 'review'

    if self.view.layout == 'split' then
        mode = mode .. ' · split'
    end

    if file == nil then
        return mode
    end

    local paths = self:paths()

    for index, other in ipairs(paths) do
        if other.path == file.path then
            return string.format(
                '%s · %s · %d/%d',
                mode,
                file.path,
                index,
                #paths
            )
        end
    end

    return mode .. ' · ' .. file.path
end

--- Show every file in the diff window, or the tree's file alone.
function Review:toggle_mode()
    if not self.preview.all_files then
        self.expanded = {}
    end

    local file = self.tree:file()

    self.preview:set_all_files(
        not self.preview.all_files,
        file and file.items or nil
    )
    self:render()
end

--- Edit the file of the diff in the tab the review came from, at the
--- worktree line of the cursor row. The review stays open.
function Review:goto_file()
    local view = self.view
    local section, row = view:at()

    if section == nil or not view:is_shown() then
        return
    end

    local file = section.file

    local path = vim.fs.joinpath(self.changes.root, file.path)

    if vim.uv.fs_stat(path) == nil then
        util.warn(file.path .. ' is deleted')
        return
    end

    self:open_file(path, self.preview:worktree_line(file, row or #file.rows))
end

--- Edit `path`, an absolute file path, at `line` in the tab the review
--- came from. The review stays open.
---@param path string
---@param line integer
function Review:open_file(path, line)
    tab.open_file(self, path, line)
end

---@param annotation table
function Review:open_editor(annotation)
    editor.open({
        root = self.changes.root,
        annotation = annotation,
        config = self.config,
        pane = self.diff_win,
        on_save = function()
            self:annotations_changed()
        end,
    })
end

--- Draw the stored annotations again after this review wrote them.
function Review:annotations_changed()
    if self.on_annotations ~= nil then
        self.on_annotations()
    else
        self:refresh_annotations()
    end
end

--- The anchor of model rows `rows` of `file`. Rows with a new line number
--- anchor on the new side, which follows the worktree, so a staged line
--- goes through the unstaged diff; only deleted rows anchor on the old
--- side, against the version they were deleted from. On the old side of
--- the split layout (`side` 'old') rows with a deleted line anchor on the
--- old side over all of them, context included. `passage` (the rows the
--- selection starts and ends on, and its columns there) makes a new-side
--- anchor a passage when both rows are its first and last and show the
--- worktree's text of their lines.
---@param file IterFileDiff
---@param rows integer[]
---@param side? 'old'|'new'
---@param passage? { first: integer?, last: integer?, start_col: integer, end_col: integer }
---@return IterAnchor?
---@return string? error
function Review:anchor_rows(file, rows, side, passage)
    local new_rows, old = {}, {}
    local old_side = false

    for _, index in ipairs(rows) do
        old_side = old_side
            or (side == 'old' and file.rows[index].kind == 'del')
    end

    for _, index in ipairs(rows) do
        local row = file.rows[index]

        if row.kind == 'gap' then
            return nil, 'Expand the hidden lines first'
        elseif old_side then
            if row.old ~= nil then
                table.insert(old, row.old)
            end
        elseif row.new ~= nil then
            table.insert(new_rows, index)
        elseif row.kind == 'del' then
            table.insert(old, row.old)
        end
    end

    local changes = self.changes

    if #new_rows > 0 then
        local start = self.preview:worktree_line(file, new_rows[1])
        local stop = self.preview:worktree_line(file, new_rows[#new_rows])
        local path = vim.fs.joinpath(changes.root, file.path)
        local ok, lines = pcall(vim.fn.readfile, path)

        if not ok or lines[stop] == nil then
            return nil, file.path .. ' has no such line in the worktree'
        end

        local start_col, end_col

        if
            passage ~= nil
            and passage.first == new_rows[1]
            and passage.last == new_rows[#new_rows]
            and file.rows[passage.first].text == lines[start]
            and file.rows[passage.last].text == lines[stop]
        then
            start_col, end_col = passage.start_col, passage.end_col
        end

        return anchor.create({
            path = file.path,
            side = 'new',
            start_line = start,
            end_line = stop,
            start_col = start_col,
            end_col = end_col,
        }, lines)
    end

    if #old > 0 then
        local lines = file.old_lines

        if lines == nil then
            lines = {}

            for _, row in ipairs(file.rows) do
                if row.old ~= nil then
                    lines[row.old] = row.text
                end
            end
        end

        return anchor.create({
            path = file.orig_path or file.path,
            side = 'old',
            base = anchor.old_base(file),
            start_line = old[1],
            end_line = old[#old],
        }, lines)
    end

    return nil, 'No line under the cursor'
end

--- Annotate the line under the cursor of the diff pane, or on the
--- visual range; in the split layout the rows of the side in the current
--- window.
function Review:annotate()
    local view = self.view

    if not view:is_shown() then
        return
    end

    local side = view:active_side()
    local first, last, start_col, end_col = editor.selection()
    local section, rows = self:selected_section(first, last, side)

    if section == nil then
        return
    end

    local file = section.file

    if file.binary then
        util.warn('A binary file takes file annotations only')
        return
    end

    local passage

    if start_col ~= nil then
        local _, first_row = view:at(first)
        local _, last_row = view:at(last)
        passage = {
            first = first_row,
            last = last_row,
            start_col = start_col,
            end_col = end_col,
        }
    end

    local a, err = self:anchor_rows(file, rows, side, passage)

    if a == nil then
        util.warn(err or 'No line under the cursor')
        return
    end

    self:open_editor({
        scope = a.start_line == a.end_line and 'line' or 'range',
        anchor = a,
    })
end

--- Annotate the file at `path`.
---@param path string
function Review:annotate_file(path)
    self:open_editor({
        scope = 'file',
        anchor = { path = path, side = 'new' },
    })
end

--- Copy the annotations of `file`, matched by its path or its original path.
---@param file IterChange|IterFileDiff
function Review:yank_file(file)
    local ids = {}

    for _, annotation in ipairs(self.annotations) do
        local path = annotation.anchor.path

        if path ~= nil and (path == file.path or path == file.orig_path) then
            table.insert(ids, annotation.id)
        end
    end

    require('iter').yank({ ids = ids })
end

--- Copy the annotation under the cursor of the diff pane, else the notes of
--- the shown file.
function Review:yank_under_cursor()
    local annotation = self:find_annotation_under_cursor()

    if annotation ~= nil then
        require('iter').yank({ ids = { annotation.id } })
        return
    end

    local file = self:shown_file()

    if file == nil then
        util.warn('No annotation or file under the cursor')
        return
    end

    self:yank_file(file)
end

--- The first annotation placed below the cursor row of the diff pane, in
--- the split layout one shown on the side of the current window first.
---@return IterAnnotation?
function Review:find_annotation_under_cursor()
    local view = self.view

    if not view:is_shown() then
        return nil
    end

    local lnum = view:cursor_line()
    local side = view:active_side()
    local found

    for _, mark in ipairs(view.marks) do
        if mark.lnum == lnum and not mark.hidden then
            local mark_side = mark.annotation.anchor.side == 'old' and 'old'
                or 'new'

            if side == nil or mark_side == side then
                return mark.annotation
            end

            found = found or mark.annotation
        end
    end

    return found
end

--- `find_annotation_under_cursor` that warns when there is none.
---@return IterAnnotation?
function Review:annotation_under_cursor()
    local annotation = self:find_annotation_under_cursor()

    if annotation == nil then
        util.warn('No annotation on this line')
    end

    return annotation
end

function Review:edit_annotation()
    local annotation = self:annotation_under_cursor()

    if annotation ~= nil then
        self:open_editor(annotation)
    end
end

function Review:delete_annotation()
    local annotation = self:annotation_under_cursor()

    if annotation ~= nil then
        self:delete(annotation)
    end
end

--- Delete `annotation` after the confirm.
---@param annotation IterAnnotation
function Review:delete(annotation)
    if editor.delete(self.changes.root, annotation) ~= nil then
        self:annotations_changed()
    end
end

return Review
