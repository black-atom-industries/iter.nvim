local anchor = require('iter.annotations.anchor')
local Drawer = require('iter.ui.drawer')
local editor = require('iter.annotations.editor')
local git = require('iter.git')
local help = require('iter.ui.help')
local patch = require('iter.diff.patch')
local store = require('iter.store')
local util = require('iter.util')
local viewed = require('iter.viewed')

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
---@field records table<string, IterViewed> stored viewed records
---@field viewed table<string, IterViewedState> state per file path in the drawer
---@field fresh? boolean read the store on the next load whatever its stat says
---@field help? IterHelp help float of the diff pane
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

-- Glyph and group per viewed state in a drawer row.
local VIEWED_MARKS = {
    viewed = { '✓', 'IterViewed' },
    changed = { '↻', 'IterViewedChanged' },
    unviewed = { '○', 'IterDrawerHint' },
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
        viewed = {},
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
            local view = self.drawer.view
            local file = view:is_shown() and view.files[1] or nil

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
        viewed = function()
            local view = self.drawer.view
            local file = view:is_shown() and view.files[1] or nil

            if file ~= nil then
                self:toggle_viewed(file.path)
            end
        end,
        picker = function()
            require('iter').annotations()
        end,
        yank = function()
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

--- Put the cursor on the `@@` row of hunk `index`, else of the last hunk.
---@param view IterDiffView
---@param index integer
local function cursor_to_hunk(view, index)
    local file = view.files[1]
    local target = math.min(index, #file.hunks)

    for lnum, row in ipairs(view.rows) do
        if row.kind == 'hunk' and row.hunk == target then
            vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
            return
        end
    end
end

--- The selected del and add rows of `file` between rows `first` and `last`;
--- nil when there are none.
---@param file IterFileDiff
---@param first integer
---@param last integer
---@return IterLineSelection?
local function line_selection(file, first, last)
    local selection = { old = {}, new = {} }
    local any = false

    for lnum = first, last do
        local row = file.rows[lnum]

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
--- diff pane, or in visual mode the selected del and add rows. The patch
--- comes from git's diff text of this moment, byte for byte, and only when
--- that text is still the one on screen; `git apply --check` runs before
--- the apply. After a hunk the cursor goes to the hunk that took its place,
--- else the last one.
---@param kind 'stage'|'unstage'
function Review:apply_change(kind)
    local view = self.drawer.view
    local visual = vim.fn.mode():find('^[vV\22]') ~= nil
    local first, last = editor.selection()
    local file = view:is_shown() and view.files[1] or nil

    if file == nil then
        return
    end

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

    local row = view:row()
    local selection

    if visual and is_link(file.raw) then
        util.warn('Lines of a symlink or submodule cannot be staged one by one')
        return
    elseif visual then
        selection = line_selection(file, first, last)

        if selection == nil then
            util.warn('No added or deleted lines selected')
            return
        end
    elseif row == nil or row.hunk == nil then
        util.warn('No hunk under the cursor')
        return
    end

    local root = self.drawer.changes.root
    local raw = git.file_diff_bytes(root, file)

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
        util.warn(string.format('Cannot %s the %s: %s', kind, what, err))
        return
    end

    local shown = view.files[1]

    if
        not visual
        and view:is_shown()
        and shown ~= nil
        and shown.path == file.path
        and shown.side == file.side
    then
        cursor_to_hunk(view, row.hunk)
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

--- Read the stored annotations and viewed records through the store cache,
--- and the viewed state of every file in the drawer. Files whose stat is
--- unchanged are not hashed again.
---@param drawer IterDrawer
---@return boolean changed
function Review:drawer_load(drawer)
    local root = drawer.changes.root
    local before_annotations, before_viewed = self.annotations, self.viewed
    local data = store.cached(root, self.fresh)
    local paths, seen = {}, {}

    self.fresh = nil
    self.annotations, self.records = data.annotations, data.viewed

    for _, item in ipairs(drawer:files()) do
        if not seen[item.path] then
            seen[item.path] = true
            table.insert(paths, item.path)
        end
    end

    self.viewed = viewed.states(root, paths, self.records)

    local annotations_changed =
        not vim.deep_equal(before_annotations, self.annotations)

    if annotations_changed then
        drawer.view:set_annotations(self.annotations)
    end

    return annotations_changed or not vim.deep_equal(before_viewed, self.viewed)
end

--- A file row shows its viewed mark after the code letter and its
--- annotation count at the end.
---@param _ IterDrawer
---@return fun(item: IterChange): IterLayoutDecor
function Review:drawer_decorator(_)
    local counts = annotation_counts(self.annotations)

    return function(item)
        return {
            mark = not item.dir and VIEWED_MARKS[self.viewed[item.path]] or nil,
            count = item_count(counts, item),
        }
    end
end

--- With files, `viewed <n> of <m> · ↻ <k> changed` in place of the change
--- summary, then `· <c> annotations · <o> outdated`, each only above 0.
---@param _ IterDrawer
---@param summary [string, string]
---@return [string, string][]
function Review:drawer_header(_, summary)
    local counts = viewed.summary(self.viewed)
    local outdated = #vim.tbl_filter(function(annotation)
        return annotation.outdated
    end, self.annotations)
    local chunks = {}

    if counts.total > 0 then
        table.insert(chunks, {
            string.format(' · viewed %d of %d', counts.viewed, counts.total),
            'IterDrawerHint',
        })

        if counts.changed > 0 then
            table.insert(chunks, {
                string.format(' · ↻ %d changed', counts.changed),
                'IterViewedChanged',
            })
        end
    else
        table.insert(chunks, summary)
    end

    if #self.annotations > 0 then
        table.insert(chunks, {
            string.format(
                ' · %d %s',
                #self.annotations,
                #self.annotations == 1 and 'annotation' or 'annotations'
            ),
            'IterDrawerCount',
        })
    end

    if outdated > 0 then
        table.insert(chunks, {
            string.format(' · %d outdated', outdated),
            'IterDrawerHint',
        })
    end

    return chunks
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
    local height = math.max(
        3,
        math.floor(base),
        math.min(math.min(count, Drawer.MIN_LINES) + 2, math.floor(total / 2))
    )

    if height ~= current then
        vim.api.nvim_win_set_height(drawer.pane, height)
    end
end

--- Show the viewed state of the shown file in the diff header.
---@param drawer IterDrawer
function Review:drawer_shown(drawer)
    local file = drawer.view.files[1]

    drawer.view:set_viewed(file and self.viewed[file.path])
end

--- The review's drawer actions: `open` moves into the diff, and the
--- annotation and viewed actions work on the selected file.
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

    handlers.open = function()
        drawer:enter_view()
    end
    handlers.review = nil
    handlers.annotate_file = on_file(function(path)
        self:annotate_file(path)
    end)
    handlers.viewed = on_file(function(path)
        self:toggle_viewed(path)
    end)
    handlers.picker = function()
        require('iter').annotations()
    end
    handlers.yank = function()
        require('iter').yank()
    end
end

--- Read the stored annotations again whatever the store file's stat says,
--- then refresh the drawer. For writes of this instance, which can keep the
--- stat.
function Review:refresh_annotations()
    self.fresh = true
    self.drawer:refresh()
end

--- Toggle the viewed mark of `path` and refresh.
---@param path string
function Review:toggle_viewed(path)
    local _, err = viewed.toggle(self.drawer.changes.root, path)

    if err ~= nil then
        util.warn('Cannot toggle viewed: ' .. err)
        return
    end

    self:refresh_annotations()
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
                vim.api.nvim_set_current_win(self.drawer.win)
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
    local file = view.files[1]

    if
        self.closed
        or not util.is_valid_win(self.diff_win)
        or self.drawer.previewed == nil
        or file == nil
        or view:is_shown()
    then
        return
    end

    local path, line = self:file_in(self.diff_win)

    -- The scratch buffer first, so the view borrows the pane from it again.
    vim.api.nvim_win_set_buf(self.diff_win, self.buf)
    view:show(file)
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

--- `review · <file> · <i>/<n>` for windows of the tab, `''` elsewhere. The
--- position counts files in drawer order.
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

    local view = self.drawer.view
    local file = view:is_shown() and view.files[1] or nil

    if file == nil then
        return 'review'
    end

    local files = self.drawer:files()

    for index, item in ipairs(files) do
        if item.side == file.side and item.path == file.path then
            return string.format(
                'review · %s · %d/%d',
                file.path,
                index,
                #files
            )
        end
    end

    return 'review · ' .. file.path
end

--- Edit the file of the diff in the tab the review came from, at the
--- worktree line of the cursor row. The review stays open.
function Review:goto_file()
    local view = self.drawer.view
    local file = view.files[1]

    if file == nil or not view:is_shown() then
        return
    end

    local changes = self.drawer.changes
    local path = vim.fs.joinpath(changes.root, file.path)

    if vim.uv.fs_stat(path) == nil then
        util.warn(file.path .. ' is deleted')
        return
    end

    self:open_file(
        path,
        self.drawer:worktree_line(
            file,
            vim.api.nvim_win_get_cursor(view.win)[1]
        )
    )
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

--- Show the diff that places `annotation` and put the cursor on its row,
--- switching to the review tab. False, and nothing switched, when the
--- annotation's file isn't among the changes.
---@param annotation IterAnnotation
---@return boolean
function Review:show_annotation(annotation)
    self:refresh_annotations()

    if not self:select_annotation(annotation) then
        return false
    end

    vim.api.nvim_set_current_tabpage(self.tab)

    if self.drawer.view:is_shown() then
        vim.api.nvim_set_current_win(self.diff_win)
    end

    return true
end

--- Select the file `annotation` belongs to in the drawer, show its diff and
--- put the diff cursor on the annotation's row. An annotation is found in
--- the staged diff or the unstaged one, the side of its old version first.
--- False when the file isn't among the changes.
---@param annotation IterAnnotation
---@return boolean
function Review:select_annotation(annotation)
    local a = annotation.anchor
    local drawer = self.drawer

    if a.path == nil then
        return false
    end

    local sides = a.side == 'old'
            and a.base == 'HEAD'
            and { 'staged', 'unstaged' }
        or { 'unstaged', 'staged' }
    local found = {}

    for _, side in ipairs(sides) do
        for lnum, row in ipairs(drawer.rows) do
            local item = row[side]

            if
                item ~= nil
                and not item.dir
                and (item.path == a.path or item.orig_path == a.path)
            then
                table.insert(found, { lnum = lnum, side = side })
            end
        end
    end

    for _, target in ipairs(found) do
        drawer:select(target.lnum, target.side)
        drawer:preview(false)

        for _, mark in ipairs(drawer.view.marks) do
            if mark.annotation.id == annotation.id then
                vim.api.nvim_win_set_cursor(drawer.view.win, { mark.lnum, 0 })
                return true
            end
        end
    end

    if found[1] == nil then
        return false
    end

    drawer:select(found[1].lnum, found[1].side)
    drawer:preview(false)

    return true
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

--- The anchor of rows `first` to `last` of the shown diff. Rows with a new
--- line number anchor on the new side, which follows the worktree, so a
--- staged line goes through the unstaged diff; only deleted rows anchor on
--- the old side, against the version they were deleted from.
---@param file IterFileDiff
---@param first integer
---@param last integer
---@return IterAnchor?
---@return string? error
function Review:anchor_rows(file, first, last)
    local new_rows, old = {}, {}

    for lnum = first, last do
        local row = file.rows[lnum]

        if row.kind == 'gap' then
            return nil, 'Expand the hidden lines first'
        elseif row.new ~= nil then
            table.insert(new_rows, lnum)
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

        return anchor.create({
            path = file.path,
            side = 'new',
            start_line = start,
            end_line = stop,
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
--- visual range.
function Review:annotate()
    local view = self.drawer.view
    local file = view:is_shown() and view.files[1] or nil

    if file == nil then
        return
    end

    local first, last = editor.selection()

    if file.binary then
        util.warn('A binary file takes file annotations only')
        return
    end

    local a, err = self:anchor_rows(file, first, last)

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

--- The first annotation placed below the cursor row of the diff pane.
---@return IterAnnotation?
function Review:annotation_under_cursor()
    local view = self.drawer.view

    if not view:is_shown() then
        return nil
    end

    local lnum = vim.api.nvim_win_get_cursor(view.win)[1]

    for _, mark in ipairs(view.marks) do
        if mark.lnum == lnum then
            return mark.annotation
        end
    end

    util.warn('No annotation on this line')
    return nil
end

function Review:edit_annotation()
    local annotation = self:annotation_under_cursor()

    if annotation ~= nil then
        self:open_editor(annotation)
    end
end

function Review:delete_annotation()
    local annotation = self:annotation_under_cursor()

    if annotation == nil then
        return
    end

    if editor.delete(self.drawer.changes.root, annotation) ~= nil then
        self:annotations_changed()
    end
end

return Review
