local anchor = require('iter.annotations.anchor')
local document = require('iter.diff.document')
local Drawer = require('iter.ui.drawer')
local editor = require('iter.annotations.editor')
local float = require('iter.ui.float')
local git = require('iter.git')
local help = require('iter.ui.help')
local layout = require('iter.ui.layout')
local list = require('iter.annotations.list')
local patch = require('iter.diff.patch')
local store = require('iter.store')
local uri = require('iter.uri')
local util = require('iter.util')
local reviewed = require('iter.reviewed')

---@class IterReviewOpenOptions
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field side? IterSide side to look for `path` on first
---@field on_annotations? fun() after an annotation of the review is saved or deleted
---@field on_close? fun(review: IterReview)

---@class IterReview: IterDrawerExtras
---@field tab integer
---@field origin_tab integer tab the review was opened from; `gf` opens files there
---@field origin_win? integer normal window of that tab
---@field diff_win integer
---@field spacer_win integer bottom split the drawer float covers
---@field buf integer empty buffer of the split and of the diff window without a diff
---@field drawer IterDrawer
---@field annotations IterAnnotation[] stored annotations
---@field records table<string, IterReviewed> stored reviewed records
---@field reviewed table<string, IterReviewedState> state per file path in the drawer
---@field expanded table<string, true> per path, reviewed files shown whole in all-files mode
---@field fresh? boolean read the store on the next load whatever its stat says
---@field help? IterHelp help float of the diff pane
---@field preview_target? { id: string, file: IterChange } the annotation the Annotations column showed last and the file it showed it in
---@field group integer
---@field closed boolean
---@field on_annotations? fun()
---@field on_close? fun(review: IterReview)
local Review = {}
Review.__index = Review

-- The spacer only holds the place of the drawer float above it.
local SPACER_WINOPTS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    cursorline = false,
    cursorcolumn = false,
    colorcolumn = '',
    foldenable = false,
    list = false,
    spell = false,
    winfixheight = true,
    -- 'statusline' is global-local: an empty value would show the global one.
    statusline = ' ',
}

-- Id of the drawer column that lists the annotations.
local ANNOTATIONS = 'annotations'

-- Actions the key hint line shows in the Annotations column.
local ANNOTATION_HINTS = {
    { 'open', 'jump' },
    { 'edit', 'edit' },
    { 'discard', 'delete' },
    { 'yank', 'yank' },
    { 'column_left', 'files' },
    { 'help', 'help' },
}

---@class IterReviewRow an item of the Annotations column
---@field key string
---@field progress? IterLayoutProgress set on the reviewed progress row only
---@field annotation? IterAnnotation
---@field outdated? boolean
---@field label? string
---@field start? integer

-- Glyph and group per reviewed state in a drawer row.
local REVIEWED_MARKS = {
    reviewed = { '✓', 'IterReviewed' },
    changed = { '↻', 'IterReviewedChanged' },
    unreviewed = { '○', 'IterDrawerHint' },
}

--- A normal window of `tab`: `preferred` when it is one there, else the
--- tab's current window, else its first normal one.
---@param tab integer
---@param preferred? integer
---@return integer?
local function normal_win(tab, preferred)
    if
        util.is_normal_win(preferred)
        and vim.api.nvim_win_get_tabpage(preferred --[[@as integer]]) == tab
    then
        return preferred
    end

    local current = vim.api.nvim_tabpage_get_win(tab)

    if util.is_normal_win(current) then
        return current
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if util.is_normal_win(win) then
            return win
        end
    end

    return nil
end

--- Open the review tab after the current one, with the diff window above
--- and the drawer over a split at the bottom. The drawer gets the focus.
---@param opts IterReviewOpenOptions
---@return IterReview?
function Review.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.side', opts.side, 'string', true)
    vim.validate('opts.on_annotations', opts.on_annotations, 'function', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local origin_tab = vim.api.nvim_get_current_tabpage()
    local origin_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'

    vim.cmd('tab sbuffer ' .. buf)
    vim.t.radar_disabled = true
    vim.t.iter_label = 'iter review'

    local diff_win = vim.api.nvim_get_current_win()
    local spacer_win = vim.api.nvim_open_win(buf, false, {
        split = 'below',
        win = diff_win,
        height = 3,
    })

    for name, value in pairs(SPACER_WINOPTS) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = spacer_win }
        )
    end

    local self = setmetatable({
        tab = vim.api.nvim_get_current_tabpage(),
        origin_tab = origin_tab,
        origin_win = normal_win(origin_tab, origin_win),
        diff_win = diff_win,
        spacer_win = spacer_win,
        buf = buf,
        annotations = {},
        records = {},
        reviewed = {},
        expanded = {},
        closed = false,
        on_annotations = opts.on_annotations,
        on_close = opts.on_close,
    }, Review)

    local drawer = Drawer.open({
        pane = spacer_win,
        view_win = diff_win,
        context = 'review',
        extras = self,
        height = 1,
        config = opts.config,
        path = opts.path,
        side = opts.side,
        view_handlers = self:view_handlers(),
        on_close = function()
            self:close()
        end,
    })

    if drawer == nil then
        self.closed = true
        vim.cmd.tabclose({ bang = true })
        vim.api.nvim_buf_delete(buf, { force = true })
        return nil
    end

    -- New windows copy the jumplist of the window they open from, so a jump
    -- back would put the origin's files into the review's windows.
    for _, win in ipairs({ diff_win, spacer_win, drawer.win }) do
        vim.api.nvim_win_call(win, function()
            vim.cmd.clearjumps()
        end)
    end

    self.drawer = drawer
    self:attach()

    return self
end

---@return table<string, fun()>
function Review:view_handlers()
    return {
        next_hunk = function()
            self.drawer.view:jump_hunk(1)
        end,
        prev_hunk = function()
            self.drawer.view:jump_hunk(-1)
        end,
        next_annotation = function()
            self.drawer.view:jump_annotation(1)
        end,
        prev_annotation = function()
            self.drawer.view:jump_annotation(-1)
        end,
        next_file = function()
            self.drawer:step_file(1)
        end,
        prev_file = function()
            self.drawer:step_file(-1)
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

            if file ~= nil then
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

            if file ~= nil then
                self:mark_reviewed(file.path, file)
            end
        end,
        unreviewed = function()
            local file = self:shown_file()

            if file ~= nil then
                self:unmark_reviewed(file.path)
            end
        end,
        mode = function()
            self:toggle_mode()
        end,
        split = function()
            self.drawer:set_layout('split')
        end,
        unified = function()
            self.drawer:set_layout('unified')
        end,
        wrap = function()
            self.drawer:toggle_wrap()
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
    }
end

--- On the header of a collapsed file, show the whole file until the next
--- `=` into all-files mode or `r` marks it reviewed again; elsewhere expand
--- hidden context.
function Review:expand()
    local view = self.drawer.view
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
    local view = self.drawer.view

    return view:is_shown() and view:file() or nil
end

--- The section of the diff pane between buffer lines `first` and `last`,
--- with the model rows on those lines, in the split layout of `side` or of
--- both sides; nil and a warning when they span two files.
---@param first integer
---@param last integer
---@param side? 'old'|'new'
---@return IterDocSection?
---@return integer[] rows
function Review:selected_section(first, last, side)
    local view = self.drawer.view
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
--- diff pane, or in visual mode the selected del and add rows, in the split
--- layout those on both sides of the selected lines. The patch
--- comes from git's diff text of this moment, byte for byte, and only when
--- that text is still the one on screen; `git apply --check` runs before
--- the apply. After a hunk the cursor goes to the hunk that took its place,
--- else the last one.
---@param kind 'stage'|'unstage'
function Review:apply_change(kind)
    local view = self.drawer.view
    local visual = vim.fn.mode():find('^[vV\22]') ~= nil
    local first, last = editor.selection()

    if not view:is_shown() then
        return
    end

    local section, rows = self:selected_section(first, last)

    if section == nil then
        return
    end

    local file = section.file

    local what = visual and 'selected lines' or 'hunk'

    if kind == 'stage' and file.side ~= 'unstaged' then
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

    local root = self.drawer.changes.root
    local raw =
        git.file_diff_bytes(root, file, self.drawer.config.options.diff.args)

    if raw == nil or not vim.deep_equal(patch.text(raw), file.raw) then
        self.drawer:refresh()
        util.warn(
            file.path .. ' changed since it was shown; nothing was applied'
        )
        return
    end

    local lines = selection ~= nil and assert(patch.lines(raw, selection, kind))
        or assert(patch.hunk(raw, row.hunk))
    local ok, err = git.apply_patch(root, lines, kind, { check = true })

    if ok then
        ok, err = git.apply_patch(root, lines, kind)
    end

    -- After its last change the file lives on the other side; the selection
    -- follows it there.
    self.drawer:refresh(
        nil,
        { path = vim.fs.joinpath(root, file.path), side = file.side }
    )

    if not ok then
        util.error(string.format('Cannot %s the %s: %s', kind, what, err))
        return
    end

    self.drawer:staged(true, kind, { file.path })

    if not visual and view:is_shown() then
        cursor_to_hunk(view, section.key, row.hunk)
    end
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

--- Annotations on `item`; a directory counts those on the files inside it.
---@param counts table<string, integer>
---@param item IterChange
---@return integer
local function item_count(counts, item)
    if not item.dir then
        return counts[item.path] or 0
    end

    local count = 0

    for path, n in pairs(counts) do
        if vim.startswith(path, item.path) then
            count = count + n
        end
    end

    return count
end

--- Read the stored annotations and reviewed records through the store cache,
--- and the reviewed state of every file in the drawer. Files whose stat is
--- unchanged are not hashed again.
---@param drawer IterDrawer
---@return boolean changed
function Review:drawer_load(drawer)
    local root = drawer.changes.root
    local before_annotations, before_reviewed = self.annotations, self.reviewed
    local data = store.cached(root, self.fresh)
    local paths, seen = {}, {}

    self.fresh = nil
    self.annotations, self.records = data.annotations, data.reviewed

    for _, item in ipairs(drawer:files()) do
        if not seen[item.path] then
            seen[item.path] = true
            table.insert(paths, item.path)
        end
    end

    self.reviewed = reviewed.states(root, paths, self.records)

    local annotations_changed =
        not vim.deep_equal(before_annotations, self.annotations)

    if annotations_changed then
        drawer.view:set_annotations(self.annotations, root)
    end

    return annotations_changed
        or not vim.deep_equal(before_reviewed, self.reviewed)
end

--- A file row shows its reviewed mark after the code letter and its
--- annotation count at the end.
---@param _ IterDrawer
---@return fun(item: IterChange): IterLayoutDecor
function Review:drawer_decorator(_)
    local counts = annotation_counts(self.annotations)

    return function(item)
        return {
            mark = not item.dir and REVIEWED_MARKS[self.reviewed[item.path]]
                or nil,
            count = item_count(counts, item),
        }
    end
end

--- `<n> files` at the right edge, in place of the change summary.
---@param _ IterDrawer
---@param _summary [string, string]
---@param room integer
---@return [string, string][]
function Review:drawer_header(_, _summary, room)
    local total = reviewed.summary(self.reviewed).total
    local files =
        string.format('%d %s ', total, total == 1 and 'file' or 'files')

    return {
        {
            string.rep(' ', math.max(1, room - vim.fn.strdisplaywidth(files))),
            'IterDrawerHint',
        },
        { files, 'IterDrawerHint' },
    }
end

--- The Annotations column: the reviewed progress, then every annotation in
--- drawer file order, review annotations last. The progress row takes the
--- selection only while there are no annotations.
---@param drawer IterDrawer
---@return IterDrawerColumnSpec[]
function Review:drawer_columns(drawer)
    local order = {}

    for _, item in ipairs(drawer:files()) do
        table.insert(order, item.path)

        if item.orig_path ~= nil then
            table.insert(order, item.orig_path)
        end
    end

    ---@type IterReviewRow[]
    local rows = {}
    local outdated, label_width = 0, 0
    local groups =
        list.groups(self.annotations, order, list.reader(drawer.changes.root))

    for _, group in ipairs(groups) do
        for _, entry in ipairs(group.items) do
            local label = layout.annotation_label(entry.annotation, entry.start)

            table.insert(rows, {
                key = 'annotation\0' .. entry.annotation.id,
                annotation = entry.annotation,
                outdated = entry.outdated,
                label = label,
                start = entry.start,
            })
            label_width = math.max(label_width, vim.fn.strdisplaywidth(label))

            if entry.outdated then
                outdated = outdated + 1
            end
        end
    end

    local items =
        { { key = 'progress', progress = reviewed.summary(self.reviewed) } }
    vim.list_extend(items, rows)

    return {
        {
            id = ANNOTATIONS,
            title = 'Annotations',
            items = items,
            weight = 1.5,
            count = #rows,
            note = outdated > 0 and (outdated .. ' outdated') or nil,
            hints = ANNOTATION_HINTS,
            selectable = function(item)
                return item.annotation ~= nil or #rows == 0
            end,
            cell = function(line, item, first, width)
                if item.progress ~= nil then
                    return layout.progress_cell(
                        line,
                        item.progress,
                        first,
                        width
                    )
                end

                return layout.annotation_cell(
                    line,
                    item,
                    first,
                    width,
                    math.min(label_width, math.floor(width / 2))
                )
            end,
        },
    }
end

--- The files of the changes in `drawer` whose diff can place `annotation`,
--- the side of its old version first.
---@param drawer IterDrawer
---@param annotation IterAnnotation
---@return IterChange[]
local function annotation_files(drawer, annotation)
    local a = annotation.anchor
    local changes = drawer.changes
    local found = {}

    if annotation.scope == 'review' or a.path == nil then
        return found
    end

    local sides = a.side == 'old'
            and a.base == 'HEAD'
            and { 'staged', 'unstaged' }
        or { 'unstaged', 'staged' }

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

--- The line of the diff pane `annotation` sits below, in `file` when
--- given, nil when it isn't placed there; in a collapsed file its header
--- row, with the file's section index.
---@param drawer IterDrawer
---@param annotation IterAnnotation
---@param file? IterChange
---@return integer?
---@return integer? collapsed section index of the file, when collapsed
local function annotation_row(drawer, annotation, file)
    local view = drawer.view

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

--- Show an item of the Annotations column in the diff pane: the diff of
--- the annotation's file with the annotation focused and in view. Shown
--- again, after a refresh, the diff cursor stays where it is. The progress
--- row, a review annotation and one of a file outside the changes keep the
--- pane as it is.
---@param drawer IterDrawer
---@param item IterReviewRow
---@param force boolean
function Review:drawer_preview(drawer, item, force)
    local annotation = item.annotation
    local files = annotation and annotation_files(drawer, annotation) or {}
    local view = drawer.view
    local again = drawer.previewed == item.key

    if annotation == nil or #files == 0 then
        view:set_focus(nil)
        return
    end

    view:set_focus(annotation.id)

    -- A diff where the annotation sits below a gap hides its code; the
    -- next side may show it.
    local lnum, placed, shown

    for _, file in ipairs(files) do
        drawer:show(file, force)

        local row = annotation_row(drawer, annotation, file)

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
        drawer:show(placed and placed.file or files[1], force)

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
function Review:jump_to(item)
    local annotation = item.annotation

    if annotation == nil then
        return
    end

    if annotation.scope == 'review' then
        self:open_editor(annotation)
        return
    end

    local drawer = self.drawer
    local a = annotation.anchor

    if #annotation_files(drawer, annotation) == 0 then
        local path = vim.fs.joinpath(drawer.changes.root, a.path)

        if vim.uv.fs_stat(path) == nil then
            util.warn(a.path .. ' is deleted')
            return
        end

        self:open_file(path, item.start or a.start_line or 1)
        return
    end

    drawer:preview(false)

    local target = self.preview_target
    local file = target ~= nil and target.id == annotation.id and target.file
        or nil
    local lnum, collapsed = annotation_row(drawer, annotation, file)

    if collapsed ~= nil then
        local view = drawer.view

        local path = view.document.sections[collapsed].file.path

        self.expanded[path] = true
        view:expand_path(path)
        lnum = annotation_row(drawer, annotation, file)
    end

    if lnum ~= nil then
        drawer.view:reveal(lnum)
        vim.api.nvim_set_current_win(self.diff_win)
    end
end

--- Select the first row of the Annotations column and focus the drawer.
function Review:focus_annotations()
    local drawer = self.drawer
    local lines = drawer:item_lines(ANNOTATIONS)

    vim.api.nvim_set_current_tabpage(self.tab)

    if #lines > 0 then
        drawer:select(lines[1], ANNOTATIONS)
    end

    if util.is_valid_win(drawer.win) then
        vim.api.nvim_set_current_win(drawer:selection_win())
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

--- Select the file at `path`, relative to the root, Unstaged before
--- Staged, and show its diff; with `line` move into the diff pane at that
--- new-side line, showing a collapsed file whole and the context around
--- the line. A path outside the changes warns.
---@param path string
---@param line? integer
function Review:reveal(path, line)
    local drawer = self.drawer
    local at =
        drawer:find_path(vim.fs.joinpath(drawer.changes.root, path), 'unstaged')
    local item = at and drawer.rows[at.lnum][at.side]

    if item == nil or item.dir then
        util.warn(path .. ' is not in the changes')
        return
    end

    ---@cast at -nil
    drawer:select(at.lnum, at.side)
    drawer:preview(false)

    if line == nil then
        return
    end

    local view = drawer.view
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
    local view = self.drawer.view
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
        self.drawer:worktree_line(section.file, row)
    )
end

--- Size the spacer split to `drawer.height` of the spacer and the diff
--- window together, but at least `MIN_LINES` of the drawer's `count` lines
--- and chrome, up to half of them.
---@param drawer IterDrawer
---@param count integer
function Review:drawer_rendered(drawer, count)
    if not util.is_valid_win(drawer.view.win) then
        return
    end

    local current = vim.api.nvim_win_get_height(drawer.pane)
    local total = current + vim.api.nvim_win_get_height(drawer.view.win)
    local option = drawer.config.options.drawer.height
    local base = option <= 1 and math.floor(total * option) or option
    -- The review drawer has no rule: the split above it draws a line.
    local chrome = float.chrome_rows(false)
    local height = math.max(
        chrome + 1,
        math.floor(base),
        math.min(
            math.min(count, Drawer.MIN_LINES) + chrome,
            math.floor(total / 2)
        )
    )

    if height ~= current then
        vim.api.nvim_win_set_height(drawer.pane, height)
    end
end

--- A reviewed file shows its header row alone, unless `<CR>` or a jump to
--- one of its annotations expanded it.
---@param _ IterDrawer
---@param item IterChange
---@return boolean
function Review:drawer_collapsed(_, item)
    return self.reviewed[item.path] == 'reviewed'
        and not self.expanded[item.path]
end

--- Show the reviewed state of the shown files in their diff headers.
---@param drawer IterDrawer
function Review:drawer_shown(drawer)
    drawer.view:set_reviewed(self.reviewed)
end

--- The review's drawer actions: `open` moves into the diff, and the
--- annotation and reviewed actions work on the selected file.
---@param drawer IterDrawer
---@param handlers table<string, fun()>
function Review:drawer_handlers(drawer, handlers)
    ---@param fn fun(path: string)
    local function on_file(fn)
        return function()
            local item = drawer:selected()

            if item == nil or item.dir then
                util.warn('No file selected')
                return
            end

            fn(item.path)
        end
    end

    ---@param fn fun(item: IterReviewRow)
    local function on_annotation(fn)
        return function()
            local item = drawer:item()

            if
                drawer.column ~= ANNOTATIONS
                or item == nil
                or item.annotation == nil
            then
                util.warn('No annotation selected')
                return
            end

            fn(item)
        end
    end

    handlers.open = function()
        if drawer.column == ANNOTATIONS then
            local item = drawer:item()

            if item ~= nil then
                self:jump_to(item)
            end
        else
            drawer:enter_view()
        end
    end
    handlers.edit = on_annotation(function(item)
        self:open_editor(item.annotation)
    end)
    local discard = handlers.discard
    local delete = on_annotation(function(item)
        self:delete(item.annotation)
    end)
    handlers.discard = function()
        if drawer.column == ANNOTATIONS then
            delete()
        else
            discard()
        end
    end
    handlers.review = nil
    handlers.annotate_file = on_file(function(path)
        self:annotate_file(path)
    end)
    handlers.reviewed = on_file(function(path)
        self:mark_reviewed(path, drawer:selected())
    end)
    handlers.unreviewed = on_file(function(path)
        self:unmark_reviewed(path)
    end)
    handlers.yank = function()
        local item = drawer:item()

        if drawer.column == ANNOTATIONS then
            if item ~= nil and item.annotation ~= nil then
                require('iter').yank({ ids = { item.annotation.id } })
                return
            end
        elseif item ~= nil and not item.dir then
            self:yank_file(item)
            return
        end

        require('iter').yank()
    end
    handlers.yank_all = function()
        require('iter').yank()
    end
    handlers.mode = function()
        self:toggle_mode()
    end
end

--- Read the stored annotations again whatever the store file's stat says,
--- then refresh the drawer. For writes of this instance, which can keep the
--- stat.
function Review:refresh_annotations()
    self.fresh = true
    self.drawer:refresh()
end

--- Mark `path` reviewed and refresh. In all-files mode the file collapses.
--- With `from`, the file the mark was set on, the selection moves on to the
--- next file in drawer order that is not reviewed.
---@param path string
---@param from? IterChange|IterFileDiff
function Review:mark_reviewed(path, from)
    local _, err = reviewed.set(self.drawer.changes.root, path, true)

    if err ~= nil then
        util.error('Cannot mark reviewed: ' .. err)
        return
    end

    self.expanded[path] = nil

    local order = self.drawer:files()

    self:refresh_annotations()

    if from == nil then
        return
    end

    local after = false

    for _, item in ipairs(order) do
        if
            after
            and item.path ~= path
            and self.reviewed[item.path] ~= 'reviewed'
        then
            self:advance_to(item)
            return
        end

        after = after or document.key(item) == document.key(from)
    end
end

--- Remove the reviewed mark of `path` and refresh. The selection stays.
---@param path string
function Review:unmark_reviewed(path)
    local _, err = reviewed.set(self.drawer.changes.root, path, false)

    if err ~= nil then
        util.error('Cannot unmark reviewed: ' .. err)
        return
    end

    self.expanded[path] = nil
    self:refresh_annotations()
end

--- Select `item` and show it with its header at the top of the diff pane
--- and the cursor on its first change, or on the header without one. Focus
--- stays where it is.
---@param item IterChange
function Review:advance_to(item)
    local drawer = self.drawer
    local at = drawer:find_path(
        vim.fs.joinpath(drawer.changes.root, item.path),
        item.side
    )

    if at == nil then
        return
    end

    drawer:select(at.lnum, at.side)
    drawer:preview(false)

    local view = drawer.view
    local index = document.find(view.document, document.key(item))

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

--- Open the help float with the diff pane's keys, or close it.
function Review:toggle_help()
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    local view = self.drawer.view
    local config = self.drawer.config

    self.help = help.open({
        view = 'diff',
        keys = view.keys,
        handlers = view.handlers,
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
    self.drawer.view.on_pane_replaced = function(buf, line)
        local path = vim.bo[buf].buftype == ''
                and vim.api.nvim_buf_get_name(buf)
            or ''

        if not self.closed and path ~= '' then
            self:open_file(path, line)
        end
    end

    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = { tostring(self.diff_win), tostring(self.spacer_win) },
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
    vim.api.nvim_create_autocmd('WinEnter', {
        group = self.group,
        callback = function()
            if
                vim.api.nvim_get_current_win() == self.spacer_win
                and util.is_valid_win(self.drawer.win)
            then
                vim.api.nvim_set_current_win(self.drawer:selection_win())
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = self.drawer.view.buf,
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
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = self.drawer.buf,
        callback = function()
            if vim.api.nvim_get_current_win() ~= self.drawer.win then
                return
            end

            vim.schedule(function()
                self:take_back_drawer()
            end)
        end,
    })
end

--- The file buffer that took the place of the drawer or the diff, when
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
    local view = self.drawer.view

    if
        self.closed
        or not util.is_valid_win(self.diff_win)
        or self.drawer.previewed == nil
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

--- Show the drawer in its float again after another buffer took its place,
--- and open a file buffer in the tab the review came from instead.
function Review:take_back_drawer()
    local drawer = self.drawer

    if
        self.closed
        or not util.is_valid_win(drawer.win)
        or not vim.api.nvim_buf_is_valid(drawer.buf)
        or vim.api.nvim_win_get_buf(drawer.win) == drawer.buf
    then
        return
    end

    local path, line = self:file_in(drawer.win)

    vim.api.nvim_win_set_buf(drawer.win, drawer.buf)
    vim.api.nvim_win_call(drawer.win, function()
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

--- Switch to the tab and focus the drawer.
function Review:focus()
    vim.api.nvim_set_current_tabpage(self.tab)
    self.drawer:focus()
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

    local current = vim.api.nvim_get_current_tabpage() == self.tab

    if vim.api.nvim_tabpage_is_valid(self.tab) then
        if #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd.tabnew()
        end

        vim.cmd.tabclose({
            vim.api.nvim_tabpage_get_number(self.tab),
            bang = true,
        })
    end

    -- With its windows gone, the view only wipes its buffer.
    self.drawer:close()

    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end

    if current and vim.api.nvim_tabpage_is_valid(self.origin_tab) then
        vim.api.nvim_set_current_tabpage(self.origin_tab)
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

--- `review · <file> · <i>/<n>` for windows of the tab, `''` elsewhere,
--- with `all files` after `review` in all-files mode, where the file is the
--- one under the cursor, and then `split` in the split layout. The position
--- counts files in drawer order.
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

    local file = self:shown_file()
    local mode = self.drawer.all_files and 'review · all files' or 'review'

    if self.drawer.view.layout == 'split' then
        mode = mode .. ' · split'
    end

    if file == nil then
        return mode
    end

    local files = self.drawer:files()

    for index, item in ipairs(files) do
        if item.side == file.side and item.path == file.path then
            return string.format(
                '%s · %s · %d/%d',
                mode,
                file.path,
                index,
                #files
            )
        end
    end

    return mode .. ' · ' .. file.path
end

--- Show every file in the diff pane, or the selected one alone.
function Review:toggle_mode()
    if not self.drawer.all_files then
        self.expanded = {}
    end

    self.drawer:set_all_files(not self.drawer.all_files)
end

--- Edit the file of the diff in the tab the review came from, at the
--- worktree line of the cursor row. The review stays open.
function Review:goto_file()
    local view = self.drawer.view
    local section, row = view:at()

    if section == nil or not view:is_shown() then
        return
    end

    local file = section.file

    local changes = self.drawer.changes
    local path = vim.fs.joinpath(changes.root, file.path)

    if vim.uv.fs_stat(path) == nil then
        util.warn(file.path .. ' is deleted')
        return
    end

    self:open_file(path, self.drawer:worktree_line(file, row or #file.rows))
end

--- Edit `path`, an absolute file path, at `line` in the tab the review
--- came from. The review stays open.
---@param path string
---@param line integer
function Review:open_file(path, line)
    if not vim.api.nvim_tabpage_is_valid(self.origin_tab) then
        vim.cmd.tabnew({ range = { 0 } })
        self.origin_tab = vim.api.nvim_get_current_tabpage()
    end

    local win = normal_win(self.origin_tab, self.origin_win)

    if win == nil then
        return
    end

    self.origin_win = win

    if not util.can_leave(vim.api.nvim_win_get_buf(win), path) then
        return
    end

    vim.api.nvim_set_current_tabpage(self.origin_tab)
    vim.api.nvim_set_current_win(win)
    util.edit_at(path, line)
end

---@param annotation table
function Review:open_editor(annotation)
    editor.open({
        root = self.drawer.changes.root,
        annotation = annotation,
        config = self.drawer.config,
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

    local changes = self.drawer.changes

    if #new_rows > 0 then
        local start = self.drawer:worktree_line(file, new_rows[1])
        local stop = self.drawer:worktree_line(file, new_rows[#new_rows])
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
            base = anchor.OLD_BASE[file.side],
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
    local view = self.drawer.view

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
    local view = self.drawer.view

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
    if editor.delete(self.drawer.changes.root, annotation) ~= nil then
        self:annotations_changed()
    end
end

return Review
