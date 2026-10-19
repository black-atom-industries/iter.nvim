local changes = require('iter.changes')
local float = require('iter.ui.float')
local git = require('iter.git')
local help = require('iter.ui.help')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local model = require('iter.diff.model')
local render = require('iter.ui.render')
local store = require('iter.store')
local util = require('iter.util')
local viewed = require('iter.viewed')
local View = require('iter.diff.view')
local watch = require('iter.watch')

---@class IterDrawerRow buffer line → cells
---@field unstaged? IterChange
---@field staged? IterChange

---@class IterDrawerCell byte columns of one cell on its line
---@field first integer
---@field last integer

---@class IterDrawerOpenOptions
---@field pane integer window the float is anchored to
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field side? IterSide side to look for `path` on first
---@field context? 'status'|'review'
---@field view_win? integer window the diff view borrows, the pane by default
---@field view_handlers? table<string, fun()> diff view actions
---@field height? number float height, `drawer.height` by default
---@field on_close? fun(drawer: IterDrawer)

---@class IterDrawer
---@field context 'status'|'review'
---@field keys_view IterView view whose keys the drawer maps
---@field keys table<string, string[]>
---@field pane integer
---@field win integer
---@field buf integer
---@field float IterFloat
---@field view IterDiffView diff of the selected file, shown in the pane
---@field watch? IterWatch refreshes the drawer on external changes
---@field help? IterHelp
---@field handlers table<string, fun()> drawer actions by name
---@field config IterConfig
---@field changes IterChanges
---@field comments IterComment[] stored comments, read in the review context only
---@field records table<string, IterViewed> stored viewed records, same context
---@field viewed? table<string, IterViewedState> state per file path, review context only
---@field store_branch? string branch `store_path` belongs to
---@field store_path? string
---@field store_stat? string stat of `store_path` when `comments` was read
---@field rows IterDrawerRow[]
---@field cells table<IterSide, IterDrawerCell>[]
---@field column IterSide selected column
---@field lnum integer selected line
---@field layout 'columns'|'stacked'
---@field expanded table<string, boolean> untracked directories shown open
---@field previewed? string key of the item the view shows
---@field previewed_stat? string worktree stat of that item when it was read
---@field preview_tick integer bumped per scheduled preview; only the last one runs
---@field group integer
---@field closed boolean
---@field on_close? fun(drawer: IterDrawer)
local Drawer = {}
Drawer.__index = Drawer

local SELECTED_NS = vim.api.nvim_create_namespace('iter.drawer.selected')
local PREVIEW_DELAY_MS = 50
local SEPARATOR = '│'
local SIDES = { 'unstaged', 'staged' }
local TITLES = { unstaged = 'Unstaged', staged = 'Staged' }
-- Glyph and group per viewed state in a review row.
local VIEWED_MARKS = {
    viewed = { '✓', 'IterViewed' },
    changed = { '↻', 'IterViewedChanged' },
    unviewed = { '○', 'IterDrawerHint' },
}
-- Actions the key hint line shows, in order, with their short labels.
local HINTS = {
    { 'stage', 'stage' },
    { 'unstage', 'unstage' },
    { 'discard', 'discard' },
    { 'open', 'open' },
    { 'review', 'review' },
    { 'help', 'help' },
}

---@param item IterChange
---@return string
local function key(item)
    return item.side .. '\0' .. item.path
end

---@param item IterChange
---@return string
local function code_group(item)
    if item.code == '?' then
        return 'IterUntracked'
    elseif item.code == 'U' then
        return 'IterConflict'
    end

    return item.side == 'staged' and 'IterStage' or 'IterUnstage'
end

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    return text .. string.rep(' ', width - vim.fn.strdisplaywidth(text))
end

---@class IterDrawerReview what a review row shows besides the file
---@field counts table<string, integer> comments per path
---@field viewed table<string, IterViewedState> state per file path

---@class IterDrawerEntry
---@field item IterChange
---@field parent? IterChange expanded directory the item belongs to

--- Items of one side in display order, children after their directory.
---@param items IterChange[]
---@return IterDrawerEntry[]
local function flatten(items)
    local entries = {}

    for _, item in ipairs(items) do
        table.insert(entries, { item = item })

        if item.expanded then
            for _, child in ipairs(item.children or {}) do
                table.insert(entries, { item = child, parent = item })
            end
        end
    end

    return entries
end

--- Every item in drawer order: Unstaged, then Staged, children after their
--- directory.
---@param result IterChanges
---@return IterChange[]
local function ordered(result)
    local items = {}

    for _, side in ipairs(SIDES) do
        for _, entry in ipairs(flatten(result[side])) do
            table.insert(items, entry.item)
        end
    end

    return items
end

---@param path string
---@return string
local function stat_key(path)
    local stat = vim.uv.fs_stat(path)

    if stat == nil then
        return ''
    end

    return string.format('%d.%d:%d', stat.mtime.sec, stat.mtime.nsec, stat.size)
end

--- Comments per path, review comments left out.
---@param comments IterComment[]
---@return table<string, integer>
local function comment_counts(comments)
    local counts = {}

    for _, comment in ipairs(comments) do
        local path = comment.anchor.path

        if comment.scope ~= 'review' and path ~= nil then
            counts[path] = (counts[path] or 0) + 1
        end
    end

    return counts
end

--- Comments on `item`; a directory counts those on the files inside it.
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

--- One cell: code letter and path, the path cut from the left to fit. In a
--- review, the viewed mark of a file follows the code letter and the
--- item's comment count ends the cell.
---@param line IterRenderLine
---@param entry IterDrawerEntry
---@param first integer byte column the cell starts at
---@param width integer
---@param review? IterDrawerReview
---@return string
local function cell_text(line, entry, first, width, review)
    local item = entry.item
    local indent = entry.parent ~= nil and '   ' or ' '
    local name = entry.parent ~= nil and item.path:sub(#entry.parent.path + 1)
        or item.path
    local prefix = indent .. item.code .. ' '
    local mark

    if review ~= nil then
        mark = not item.dir and VIEWED_MARKS[review.viewed[item.path]] or nil
        prefix = prefix .. (mark and mark[1] or ' ') .. ' '
    end

    local count = review and item_count(review.counts, item) or 0
    local suffix = count > 0 and string.format(' [%d] ', count) or ''
    local text = prefix
        .. changes.truncate(
            name,
            width
                - vim.fn.strdisplaywidth(prefix)
                - vim.fn.strdisplaywidth(suffix)
        )

    render.add_highlight(line, code_group(item), first + #indent)

    if mark ~= nil then
        local start = first + #indent + #item.code + 1

        render.add_highlight(line, mark[2], start, start + #mark[1])
    end

    if suffix == '' then
        return pad(text, width)
    end

    text = pad(text, width - #suffix)
    render.add_highlight(
        line,
        'IterDrawerCount',
        first + #text,
        first + #text + #suffix
    )

    return text .. suffix
end

---@param line IterRenderLine
---@param side IterSide
---@param count integer
---@param first integer
---@param width integer
---@return string
local function title_text(line, side, count, first, width)
    local text = string.format(' %s (%d)', TITLES[side], count)
    render.add_highlight(line, 'IterDrawerTitle', first, first + #text)

    return pad(text, width)
end

---@class IterDrawerLayout
---@field lines IterRenderLine[]
---@field rows IterDrawerRow[]
---@field cells table<IterSide, IterDrawerCell>[]

--- Unstaged and Staged side by side, each half of `width`.
---@param lists table<IterSide, IterDrawerEntry[]>
---@param counts table<IterSide, integer>
---@param width integer
---@param review? IterDrawerReview
---@return IterDrawerLayout
local function columns_layout(lists, counts, width, review)
    local widths = { unstaged = math.floor((width - 1) / 2) }
    widths.staged = width - 1 - widths.unstaged
    local result = { lines = {}, rows = {}, cells = {} }
    local height = math.max(#lists.unstaged, #lists.staged)

    for index = 0, height do
        local line = render.line('')
        local row, cells, parts = {}, {}, {}
        local first = 0

        for i, side in ipairs(SIDES) do
            local text
            local entry = lists[side][index]

            if index == 0 then
                text = title_text(line, side, counts[side], first, widths[side])
            elseif entry ~= nil then
                text = cell_text(line, entry, first, widths[side], review)
                row[side] = entry.item
                cells[side] = { first = first, last = first + #text }
            else
                text = string.rep(' ', widths[side])
            end

            table.insert(parts, text)
            first = first + #text

            if i == 1 then
                table.insert(parts, SEPARATOR)
                render.add_highlight(
                    line,
                    'WinSeparator',
                    first,
                    first + #SEPARATOR
                )
                first = first + #SEPARATOR
            end
        end

        line.text = table.concat(parts)
        table.insert(result.lines, line)
        table.insert(result.rows, row)
        table.insert(result.cells, cells)
    end

    return result
end

--- Unstaged above Staged, both the full `width`.
---@param lists table<IterSide, IterDrawerEntry[]>
---@param counts table<IterSide, integer>
---@param width integer
---@param review? IterDrawerReview
---@return IterDrawerLayout
local function stacked_layout(lists, counts, width, review)
    local result = { lines = {}, rows = {}, cells = {} }

    for i, side in ipairs(SIDES) do
        if i > 1 then
            table.insert(result.lines, render.line(''))
            table.insert(result.rows, {})
            table.insert(result.cells, {})
        end

        local title = render.line('')
        title.text = title_text(title, side, counts[side], 0, width)
        table.insert(result.lines, title)
        table.insert(result.rows, {})
        table.insert(result.cells, {})

        for _, entry in ipairs(lists[side]) do
            local line = render.line('')
            line.text = cell_text(line, entry, 0, width, review)
            table.insert(result.lines, line)
            table.insert(result.rows, { [side] = entry.item })
            table.insert(
                result.cells,
                { [side] = { first = 0, last = #line.text } }
            )
        end
    end

    return result
end

--- The line in place of the columns when nothing changed.
---@return IterDrawerLayout
local function clean_layout()
    local line = render.line(' Working tree clean')
    render.add_highlight(line, 'IterDrawerHint', 0, #line.text)

    return { lines = { line }, rows = { {} }, cells = { {} } }
end

---@param chunks [string, string][]
---@return integer
local function chunks_width(chunks)
    local width = 0

    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end

    return width
end

---@class IterDrawerReviewHeader
---@field summary IterViewedSummary
---@field comments integer
---@field outdated integer

--- `HEAD <branch> ↑<ahead> · <n> changes`; `↑` only when HEAD is ahead of
--- its upstream. A file on both sides counts once. Stacked, the counts are
--- per side, since the Staged title may sit below the visible lines.
--- A review with files has `viewed <n> of <m> · ↻ <k> changed` in place of
--- the changes, then `· <c> comments · <o> outdated`, each only above 0.
---@param result IterChanges
---@param layout 'columns'|'stacked'
---@param review? IterDrawerReviewHeader
---@return [string, string][]
local function header_chunks(result, layout, review)
    local paths = {}
    local count = 0

    for _, side in ipairs(SIDES) do
        for _, item in ipairs(result[side]) do
            if not paths[item.path] then
                paths[item.path] = true
                count = count + 1
            end
        end
    end

    local chunks = {
        { 'HEAD ', 'IterDrawerHint' },
        {
            result.branch == 'HEAD' and '(detached)' or result.branch,
            'IterHead',
        },
    }

    if result.ahead ~= nil and result.ahead > 0 then
        table.insert(chunks, { ' ↑' .. result.ahead, 'IterUnpushed' })
    end

    local summary =
        string.format(' · %d %s', count, count == 1 and 'change' or 'changes')

    if layout == 'stacked' and count > 0 then
        summary = string.format(
            ' · %d unstaged · %d staged',
            #result.unstaged,
            #result.staged
        )
    end

    if review ~= nil and review.summary.total > 0 then
        table.insert(chunks, {
            string.format(
                ' · viewed %d of %d',
                review.summary.viewed,
                review.summary.total
            ),
            'IterDrawerHint',
        })

        if review.summary.changed > 0 then
            table.insert(chunks, {
                string.format(' · ↻ %d changed', review.summary.changed),
                'IterViewedChanged',
            })
        end
    else
        table.insert(chunks, { summary, 'IterDrawerHint' })
    end

    if review ~= nil and review.comments > 0 then
        table.insert(chunks, {
            string.format(
                ' · %d %s',
                review.comments,
                review.comments == 1 and 'comment' or 'comments'
            ),
            'IterDrawerCount',
        })
    end

    if review ~= nil and review.outdated > 0 then
        table.insert(chunks, {
            string.format(' · %d outdated', review.outdated),
            'IterDrawerHint',
        })
    end

    return chunks
end

--- The bound keys of the hint actions, as many as fit in `width`; help
--- stays last.
---@param entries IterKeymapEntry[]
---@param width integer
---@return [string, string][]
local function hint_chunks(entries, width)
    local lhs = {}

    for _, entry in ipairs(entries) do
        lhs[entry.action] = entry.lhs[1]
    end

    local items = {}

    for _, hint in ipairs(HINTS) do
        if lhs[hint[1]] ~= nil then
            table.insert(items, { lhs[hint[1]], hint[2] })
        end
    end

    local function build()
        ---@type [string, string][]
        local chunks = {}

        for i, item in ipairs(items) do
            table.insert(chunks, { item[1], 'IterDrawerKey' })
            table.insert(chunks, {
                ' ' .. item[2] .. (i < #items and '  ' or ''),
                'IterDrawerHint',
            })
        end

        return chunks
    end

    local chunks = build()

    while #items > 1 and chunks_width(chunks) > width do
        table.remove(items, #items - 1)
        chunks = build()
    end

    return chunks
end

--- Open the drawer over the bottom of `opts.pane`, focused, with the diff of
--- the selected file in the pane.
--- With 'nohidden' a modified buffer can't leave its window (E37), so the
--- pane can neither show the preview nor switch to another file.
---@param buf? integer
---@param path? string file the window would switch to
---@return boolean
local function is_stuck(buf, path)
    return not vim.o.hidden
        and buf ~= nil
        and vim.api.nvim_buf_is_valid(buf)
        and vim.bo[buf].modified
        and vim.api.nvim_buf_get_name(buf) ~= path
end

---@param opts IterDrawerOpenOptions
---@return IterDrawer?
function Drawer.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.side', opts.side, 'string', true)
    vim.validate('opts.context', opts.context, 'string', true)
    vim.validate('opts.view_win', opts.view_win, 'number', true)
    vim.validate('opts.view_handlers', opts.view_handlers, 'table', true)
    vim.validate('opts.height', opts.height, 'number', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local view_win = opts.view_win or opts.pane

    if is_stuck(vim.api.nvim_win_get_buf(view_win)) then
        util.warn('The pane has unsaved changes')
        return nil
    end

    highlight.setup()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'
    vim.api.nvim_buf_set_name(buf, 'iter://drawer/' .. buf)

    local context = opts.context or 'status'
    local keys_view = context == 'review' and 'review_drawer' or 'drawer'

    local self = setmetatable({
        context = context,
        keys_view = keys_view,
        keys = opts.config.keys[keys_view],
        pane = opts.pane,
        buf = buf,
        config = opts.config,
        rows = {},
        cells = {},
        column = 'unstaged',
        lnum = 1,
        layout = 'columns',
        expanded = {},
        preview_tick = 0,
        closed = false,
        on_close = opts.on_close,
    }, Drawer)

    if not self:load() then
        vim.api.nvim_buf_delete(buf, { force = true })
        return nil
    end

    self.handlers = self:make_handlers()
    self.view = View.new({
        win = view_win,
        keys = opts.config.keys.diff,
        handlers = opts.view_handlers,
    })
    self.view:set_comments(self.comments)
    self.float = float.open({
        pane = opts.pane,
        buf = buf,
        zindex = opts.config.options.drawer.zindex,
        height = opts.height or opts.config.options.drawer.height,
        enter = true,
        chrome = true,
    })
    self.win = self.float.win
    vim.api.nvim_set_option_value(
        'wrap',
        false,
        { scope = 'local', win = self.win }
    )

    self:render()
    self:restore_selection(self:find_path(opts.path, opts.side))
    self:attach()
    self:preview(true)
    self.watch = watch.start({
        root = self.changes.root,
        poll_ms = opts.config.options.refresh.poll_ms,
        on_change = function(reason)
            self:refresh(reason)
        end,
    })

    return self
end

---@return table<string, fun()>
function Drawer:make_handlers()
    local function act(method)
        return function()
            self[method](self)
        end
    end

    local handlers = {
        open = act('open_file'),
        review = act('open_review'),
        stage = act('stage'),
        unstage = act('unstage'),
        discard = act('discard'),
        expand = act('toggle'),
        close = act('close'),
        help = act('toggle_help'),
        column_left = function()
            self:switch('unstaged')
        end,
        column_right = function()
            self:switch('staged')
        end,
    }

    if self.context == 'review' then
        handlers.open = act('enter_view')
        handlers.review = nil
        handlers.comment_file = act('comment_file')
        handlers.viewed = function()
            self:toggle_viewed()
        end
        handlers.picker = function()
            require('iter').comments()
        end
        handlers.yank = function()
            require('iter').yank()
        end
    end

    return handlers
end

function Drawer:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.drawer.' .. self.buf,
        { clear = true }
    )

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = self.group,
        buffer = self.buf,
        callback = function()
            self:follow_cursor()
        end,
    })
    vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = self.group,
        callback = function()
            self:resized()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = { tostring(self.win), tostring(self.pane) },
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

    keymap.attach(self.buf, self.keys_view, self.keys, self.handlers)
end

---@return boolean
function Drawer:is_open()
    return not self.closed and util.is_valid_win(self.win)
end

--- Read the status afresh, keeping open directories open. Once loaded, the
--- drawer stays on its root whatever the cwd becomes.
---@return boolean loaded
function Drawer:load()
    local snapshot =
        git.status_snapshot(self.changes and self.changes.root or nil)

    if snapshot.error ~= nil then
        util.error(snapshot.error, 'Cannot read the git status')
        return false
    end

    self.changes = changes.build(snapshot)

    for _, item in ipairs(self.changes.unstaged) do
        if item.dir and self.expanded[item.path] then
            changes.expand(self.changes.root, item)
        end
    end

    self.comments = self.comments or {}
    self.records = self.records or {}

    if self.context == 'review' then
        self:load_comments()
        self:load_viewed()
    end

    return true
end

--- Read the stored comments and viewed records when the store file changed
--- since the last read. A failed read keeps what there is.
function Drawer:load_comments()
    local root = self.changes.root

    if self.store_path == nil or self.store_branch ~= self.changes.branch then
        self.store_path = store.path(root)
        self.store_branch = self.changes.branch
        self.store_stat = nil
    end

    local stat = self.store_path and stat_key(self.store_path)

    if stat ~= nil and stat == self.store_stat then
        return
    end

    local data = store.load(root)

    if data ~= nil then
        self.comments = data.comments
        self.records = data.viewed
        self.store_stat = stat
    end
end

--- The viewed state of every file in the drawer, from the records and the
--- worktree. Files whose stat is unchanged are not hashed again.
function Drawer:load_viewed()
    local paths, seen = {}, {}

    for _, item in ipairs(self:files()) do
        if not seen[item.path] then
            seen[item.path] = true
            table.insert(paths, item.path)
        end
    end

    self.viewed = viewed.states(self.changes.root, paths, self.records)
end

--- Write the items into the buffer in the layout the pane's width allows,
--- with the header and key hint line around them. The float grows to fit
--- them, up to half the pane.
function Drawer:render()
    local width = vim.api.nvim_win_get_width(self.pane)
    local lists = {
        unstaged = flatten(self.changes.unstaged),
        staged = flatten(self.changes.staged),
    }
    local counts = {
        unstaged = #self.changes.unstaged,
        staged = #self.changes.staged,
    }

    self.layout = width >= self.config.options.drawer.breakpoint and 'columns'
        or 'stacked'

    ---@type IterDrawerReview?, IterDrawerReviewHeader?
    local review, header

    if self.context == 'review' then
        review = {
            counts = comment_counts(self.comments),
            viewed = self.viewed,
        }
        header = {
            summary = viewed.summary(self.viewed),
            comments = #self.comments,
            outdated = #vim.tbl_filter(function(comment)
                return comment.outdated
            end, self.comments),
        }
    end

    local layout

    if #lists.unstaged + #lists.staged == 0 then
        layout = clean_layout()
    elseif self.layout == 'columns' then
        layout = columns_layout(lists, counts, width, review)
    else
        layout = stacked_layout(lists, counts, width, review)
    end

    self.rows, self.cells = layout.rows, layout.cells

    if self.context == 'review' then
        self:fit_pane(#layout.lines)
    end

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        self.buf,
        0,
        -1,
        false,
        render.text_lines(layout.lines)
    )
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.buf, SELECTED_NS, 0, -1)
    render.apply(self.buf, layout.lines)

    self.float:reposition({
        fit = #layout.lines,
        title = header_chunks(self.changes, self.layout, header),
        footer = hint_chunks(
            keymap.list(self.keys_view, self.keys, self.handlers),
            width
        ),
    })

    self:sync_viewed()
end

--- Show the viewed state of the shown file in the diff header.
function Drawer:sync_viewed()
    if self.viewed == nil then
        return
    end

    local file = self.view.files[1]

    self.view:set_viewed(file and self.viewed[file.path])
end

--- Size the pane, a split of its own in the review tab, to the drawer's
--- lines and chrome: at least `drawer.height` of the pane and the view's
--- window together, at most half of them.
---@param count integer
function Drawer:fit_pane(count)
    if not util.is_valid_win(self.view.win) then
        return
    end

    local current = vim.api.nvim_win_get_height(self.pane)
    local total = current + vim.api.nvim_win_get_height(self.view.win)
    local option = self.config.options.drawer.height
    local base = option <= 1 and math.floor(total * option) or option
    local height = math.max(
        3,
        math.floor(base),
        math.min(count + 2, math.floor(total / 2))
    )

    if height ~= current then
        vim.api.nvim_win_set_height(self.pane, height)
    end
end

---@return IterChange?
function Drawer:selected()
    local row = self.rows[self.lnum]

    return row and row[self.column]
end

--- The line nearest to `lnum` that holds an item of one of `sides`, looking
--- in direction `dir` first.
---@param lnum integer
---@param sides IterSide[]
---@param dir 1|-1
---@return integer? lnum
---@return IterSide? side
function Drawer:find(lnum, sides, dir)
    for _, step in ipairs({ dir, -dir }) do
        local l = lnum

        while l >= 1 and l <= #self.rows do
            for _, side in ipairs(sides) do
                if self.rows[l][side] ~= nil then
                    return l, side
                end
            end

            l = l + step
        end
    end

    return nil, nil
end

--- Line and side of the item at `path`, an absolute file path, looking on
--- `first` before the other side.
---@param path? string
---@param first? IterSide
---@return { lnum: integer, side: IterSide }?
function Drawer:find_path(path, first)
    if path == nil or path == '' then
        return nil
    end

    local sides = first == 'staged' and { 'staged', 'unstaged' } or SIDES

    for _, side in ipairs(sides) do
        for lnum, row in ipairs(self.rows) do
            local item = row[side]

            if
                item ~= nil
                and vim.fs.joinpath(self.changes.root, item.path) == path
            then
                return { lnum = lnum, side = side }
            end
        end
    end

    return nil
end

--- Select the item on `lnum` in `column`, mark its cell and follow it with
--- the preview.
---@param lnum integer
---@param column IterSide
function Drawer:select(lnum, column)
    local cell = self.cells[lnum] and self.cells[lnum][column]

    if cell == nil then
        return
    end

    self.lnum, self.column = lnum, column

    vim.api.nvim_buf_clear_namespace(self.buf, SELECTED_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(self.buf, SELECTED_NS, lnum - 1, cell.first, {
        end_col = cell.last,
        hl_group = 'IterDrawerSelected',
        priority = 100,
    })

    if util.is_valid_win(self.win) then
        local cursor = vim.api.nvim_win_get_cursor(self.win)

        if cursor[1] ~= lnum or cursor[2] ~= cell.first then
            vim.api.nvim_win_set_cursor(self.win, { lnum, cell.first })
        end
    end

    local item = self:selected()

    if item ~= nil and key(item) ~= self.previewed then
        self:schedule_preview()
    end
end

function Drawer:follow_cursor()
    if not util.is_valid_win(self.win) then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
    local dir = lnum < self.lnum and -1 or 1
    local sides = self.layout == 'stacked' and SIDES or { self.column }
    local target, side = self:find(lnum, sides, dir)

    if target ~= nil and side ~= nil then
        self:select(target, side)
    end
end

---@param column IterSide
function Drawer:switch(column)
    local lnum, side = self:find(self.lnum, { column }, 1)

    if lnum ~= nil and side ~= nil then
        self:select(lnum, side)
    end
end

--- Lines that hold an item of `column`, top to bottom.
---@param column IterSide
---@return integer[]
function Drawer:item_lines(column)
    local lines = {}

    for lnum, row in ipairs(self.rows) do
        if row[column] ~= nil then
            table.insert(lines, lnum)
        end
    end

    return lines
end

---@class IterDrawerMark selection to restore after a render
---@field column IterSide
---@field path? string
---@field index integer position among the column's items

---@return IterDrawerMark
function Drawer:mark()
    local item = self:selected()
    local index = 1

    for i, lnum in ipairs(self:item_lines(self.column)) do
        if lnum <= self.lnum then
            index = i
        end
    end

    return { column = self.column, path = item and item.path, index = index }
end

--- Select the marked item again, else the item now at its position in the
--- column, else the nearest item of the other column.
---@param target? IterDrawerMark|{ lnum: integer, side: IterSide }
function Drawer:restore_selection(target)
    if target ~= nil and target.lnum ~= nil then
        return self:select(target.lnum, target.side)
    end

    local column = target and target.column or self.column
    local lines = self:item_lines(column)

    if target ~= nil and target.path ~= nil then
        for _, lnum in ipairs(lines) do
            if self.rows[lnum][column].path == target.path then
                return self:select(lnum, column)
            end
        end
    end

    if #lines > 0 then
        local index = math.min(target and target.index or 1, #lines)
        return self:select(lines[index], column)
    end

    local lnum, side = self:find(self.lnum, SIDES, 1)

    if lnum ~= nil and side ~= nil then
        self:select(lnum, side)
    end
end

function Drawer:resized()
    if not self:is_open() then
        return
    end

    local mark = self:mark()
    self:render()
    self:restore_selection(mark)
    self.view:rewrap()
end

--- Reload the status, keep the selection on its path and show its diff
--- afresh. A poll that finds nothing changed leaves everything as it is.
---@param reason? IterWatchReason nil after an action of the drawer
function Drawer:refresh(reason)
    if not self:is_open() then
        return
    end

    local before, before_comments = self.changes, self.comments
    local before_viewed = self.viewed
    local mark = self:mark()

    if not self:load() then
        return
    end

    local comments_changed = not vim.deep_equal(before_comments, self.comments)
    local viewed_changed = not vim.deep_equal(before_viewed, self.viewed)

    if comments_changed then
        self.view:set_comments(self.comments)
    end

    if reason == 'poll' and vim.deep_equal(before, self.changes) then
        local item = self:selected()

        if comments_changed or viewed_changed then
            self:render()
            self:restore_selection(mark)
        end

        -- The review's diff also follows writes from outside Neovim, which
        -- leave the status as it was.
        if
            self.context == 'review'
            and item ~= nil
            and key(item) == self.previewed
            and stat_key(vim.fs.joinpath(self.changes.root, item.path))
                ~= self.previewed_stat
        then
            self:preview(true)
        end

        return
    end

    self:render()
    self:restore_selection(mark)
    self:preview(true)
end

--- Read the stored comments again whatever the store file's stat says,
--- then refresh. For writes of this instance, which can keep the stat.
function Drawer:refresh_comments()
    self.store_stat = nil
    self:refresh()
end

--- Toggle the viewed mark of `path`, the selected file by default, and
--- refresh.
---@param path? string
function Drawer:toggle_viewed(path)
    if path == nil then
        local item = self:selected()

        if item == nil or item.dir then
            util.warn('No file selected')
            return
        end

        path = item.path
    end

    local _, err = viewed.toggle(self.changes.root, path)

    if err ~= nil then
        util.warn('Cannot toggle viewed: ' .. err)
        return
    end

    self:refresh_comments()
end

--- Open the comment float on the selected file.
function Drawer:comment_file()
    local item = self:selected()

    if item == nil or item.dir then
        util.warn('No file selected')
        return
    end

    require('iter.comments.editor').open({
        root = self.changes.root,
        comment = {
            scope = 'file',
            anchor = { path = item.path, side = 'new' },
        },
        config = self.config,
        pane = self.view.win,
        on_save = function()
            self:refresh_comments()
        end,
    })
end

--- Select the file `comment` belongs to, show its diff and put the diff
--- cursor on the comment's row. A comment is found in the staged diff or
--- the unstaged one, the side of its old version first. False when the file
--- isn't among the changes.
---@param comment IterComment
---@return boolean
function Drawer:show_comment(comment)
    local a = comment.anchor

    if a.path == nil then
        return false
    end

    local first = a.side == 'old' and a.base == 'HEAD' and 'staged'
        or 'unstaged'
    local sides = first == 'staged' and { 'staged', 'unstaged' } or SIDES
    local found = {}

    for _, side in ipairs(sides) do
        for lnum, row in ipairs(self.rows) do
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
        self:select(target.lnum, target.side)
        self:preview(false)

        for _, mark in ipairs(self.view.marks) do
            if mark.comment.id == comment.id then
                vim.api.nvim_win_set_cursor(self.view.win, { mark.lnum, 0 })
                return true
            end
        end
    end

    if found[1] == nil then
        return false
    end

    self:select(found[1].lnum, found[1].side)
    self:preview(false)

    return true
end

--- Reload after a git action and show the selection's new diff.
---@param ok boolean
---@param err? string
---@param fallback string
function Drawer:refresh_after(ok, err, fallback)
    if not ok then
        util.error(err, fallback)
    end

    self:refresh()
end

function Drawer:schedule_preview()
    self.preview_tick = self.preview_tick + 1
    local tick = self.preview_tick

    vim.defer_fn(function()
        if tick == self.preview_tick then
            self:preview(false)
        end
    end, PREVIEW_DELAY_MS)
end

--- Show the selected file's diff in the pane. Directories leave the pane as
--- it is; without a selection the pane gets its own buffer back.
---@param force boolean also when the view already shows the item
function Drawer:preview(force)
    local item = self:selected()

    if not self:is_open() then
        return
    end

    if item == nil then
        self.previewed = nil
        self.view:hide()
        return
    end

    if item.dir then
        return
    end

    if not force and key(item) == self.previewed then
        return
    end

    local stat = stat_key(vim.fs.joinpath(self.changes.root, item.path))
    local source, err = git.file_diff(self.changes.root, item)

    if source == nil then
        util.error(err, 'Cannot read the diff of ' .. item.path)
        return
    end

    self.previewed_stat = stat
    self.view:set_new_follows(
        item.side == 'staged' and not self:has_unstaged(item.path)
    )

    -- The same diff again keeps the view as it is, expanded gaps included.
    local shown = self.view.files[1]

    if
        key(item) == self.previewed
        and self.view:is_shown()
        and shown ~= nil
        and shown.code == item.code
        and vim.deep_equal(shown.raw, source.raw)
    then
        self:sync_viewed()
        return
    end

    self.previewed = key(item)
    self.view:show(model.build(item, source))
    self:sync_viewed()
end

---@param path string
---@return boolean
function Drawer:has_unstaged(path)
    for _, item in ipairs(self.changes.unstaged) do
        if item.path == path then
            return true
        end
    end

    return false
end

--- The files an action on `item` touches. Nested repositories inside an
--- untracked directory are left out.
---@param item IterChange
---@return string[]
function Drawer:paths(item)
    local paths = {}

    for _, path in ipairs(changes.files(self.changes.root, item)) do
        if vim.endswith(path, '/') then
            util.warn('Skipped the nested repository ' .. path)
        else
            table.insert(paths, path)
        end
    end

    return paths
end

function Drawer:stage()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.side == 'staged' then
        return self:unstage()
    end

    local paths = self:paths(item)

    if #paths == 0 then
        util.warn('Nothing to stage')
        return
    end

    local ok, err = git.stage(self.changes.root, paths)
    self:refresh_after(ok, err, 'Cannot stage ' .. item.path)
end

function Drawer:unstage()
    local item = self:selected()

    if item == nil then
        return
    end

    local target = item.side == 'staged' and item or nil

    if target == nil then
        for _, staged in ipairs(self.changes.staged) do
            if staged.path == item.path then
                target = staged
            end
        end
    end

    if target == nil then
        util.warn('Nothing to unstage')
        return
    end

    local paths = { target.path }

    if target.orig_path ~= nil then
        table.insert(paths, 1, target.orig_path)
    end

    local ok, err = git.unstage(self.changes.root, paths)
    self:refresh_after(ok, err, 'Cannot unstage ' .. item.path)
end

--- Discard the unstaged changes of the selection after a confirm that names
--- every path: a tracked file goes back to its index version, untracked
--- files are deleted.
function Drawer:discard()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.side == 'staged' then
        util.warn('Unstage first')
        return
    end

    local untracked = item.code == '?'
    local paths = untracked and self:paths(item) or { item.path }

    if #paths == 0 then
        util.warn('Nothing to discard')
        return
    end

    local message = (
        untracked and 'Delete untracked files:\n'
        or 'Discard unstaged changes in:\n'
    ) .. table.concat(paths, '\n')

    if
        self.config.options.confirm.discard
        and vim.fn.confirm(message, '&Discard\n&No', 2) ~= 1
    then
        return
    end

    local root = self.changes.root
    local ok, err

    if untracked then
        ok, err = git.delete_untracked(root, paths)
    else
        ok, err = git.discard(root, paths)
    end

    self:refresh_after(ok, err, 'Cannot discard ' .. item.path)
end

--- Expand or collapse the selected untracked directory, or the directory
--- the selected file belongs to.
function Drawer:toggle()
    local item = self:selected()

    if item == nil or item.side ~= 'unstaged' then
        return
    end

    ---@type IterChange?
    local dir = item

    if not item.dir then
        dir = nil

        for _, candidate in ipairs(self.changes.unstaged) do
            if
                candidate.expanded and vim.startswith(item.path, candidate.path)
            then
                dir = candidate
            end
        end
    end

    if dir == nil then
        return
    end

    if dir.expanded then
        changes.collapse(dir)
        self.expanded[dir.path] = nil
    else
        changes.expand(self.changes.root, dir)
        self.expanded[dir.path] = true
    end

    if self.context == 'review' then
        self:load_viewed()
    end

    self:render()
    self:restore_selection({ column = 'unstaged', path = dir.path, index = 1 })
end

--- Close the drawer and edit the selected file in the pane. A deleted file
--- keeps the drawer open.
function Drawer:open_file()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.dir then
        return self:toggle()
    end

    local path = vim.fs.joinpath(self.changes.root, item.path)

    if vim.uv.fs_stat(path) == nil then
        util.warn(item.path .. ' is deleted')
        return
    end

    if is_stuck(self.view.prev_buf, path) then
        util.warn('The pane has unsaved changes')
        return
    end

    self:close()

    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))

    if not ok then
        util.error(tostring(err), 'Cannot open ' .. item.path)
    end
end

--- Show the selected file's diff and move into the diff view.
function Drawer:enter_view()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.dir then
        return self:toggle()
    end

    self:preview(false)

    if self.view:is_shown() then
        vim.api.nvim_set_current_win(self.view.win)
    end
end

--- Close the drawer and open the review tab on the selected file.
function Drawer:open_review()
    local item = self:selected()
    local target

    if item ~= nil and not item.dir then
        target = {
            path = vim.fs.joinpath(self.changes.root, item.path),
            side = item.side,
        }
    end

    self:close()
    require('iter').review(target)
end

--- Files in drawer order, directories left out.
---@return IterChange[]
function Drawer:files()
    return vim.tbl_filter(function(item)
        return not item.dir
    end, ordered(self.changes))
end

--- Select the next (`dir` 1) or previous (-1) file in drawer order and show
--- its diff now. At the last or first file nothing changes.
---@param dir 1|-1
function Drawer:step_file(dir)
    local items = ordered(self.changes)
    local current = self:selected()
    local index = dir == 1 and 0 or #items + 1

    for i, item in ipairs(items) do
        if current ~= nil and key(item) == key(current) then
            index = i
        end
    end

    index = index + dir

    while items[index] ~= nil and items[index].dir do
        index = index + dir
    end

    local target = items[index]

    if target == nil then
        return
    end

    for lnum, row in ipairs(self.rows) do
        local item = row[target.side]

        if item ~= nil and key(item) == key(target) then
            self:select(lnum, target.side)
            self:preview(false)
            return
        end
    end
end

--- Close the float and give the pane back its buffer and options.
function Drawer:close()
    if self.closed then
        return
    end

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if self.watch ~= nil then
        self.watch:stop()
    end

    if self.help ~= nil then
        self.help:close()
    end

    self.float:close()
    self.view:close()

    if util.is_valid_win(self.pane) then
        vim.api.nvim_set_current_win(self.pane)
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

--- Focus the drawer again and reload its items.
function Drawer:focus()
    if util.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    self:refresh()
end

--- Open the help float with the drawer's keys, or close it.
function Drawer:toggle_help()
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    self.help = help.open({
        view = self.keys_view,
        keys = self.keys,
        handlers = self.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

return Drawer
