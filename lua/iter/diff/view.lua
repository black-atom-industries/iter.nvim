local anchor = require('iter.annotations.anchor')
local document = require('iter.diff.document')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local list = require('iter.annotations.list')
local marks = require('iter.annotations.marks')
local model = require('iter.diff.model')
local syntax = require('iter.diff.syntax')
local util = require('iter.util')
local words = require('iter.diff.words')

---@class IterDiffViewOptions
---@field win integer window the view borrows
---@field keys table<string, string[]> resolved `keys.diff`
---@field handlers? table<string, fun()> diff actions; an `expand` here replaces the view's own
---@field expand_step integer hidden context lines revealed per expand
---@field syntax_max_lines integer versions longer than this get no syntax
---@field word_diff boolean
---@field icon string shown before each annotation, '' for none
---@field name? string buffer name, see `set_name`
---@field bufhidden? string 'bufhidden' of the buffer, `wipe` by default
---@field layout? IterDocLayout layout the view starts in, `unified` by default
---@field on_cursor? fun() after the cursor moved in a window of the view while it is the current one
---@field on_layout? fun() after the layout changed
---@field on_pane_replaced? fun(buf: integer, line: integer) after another buffer took the old side's window, with that buffer and its cursor line; the pane is back in a window of its own

--- A buffer of the view in its window: the view itself, or in the split
--- layout also the old side left of it.
---@class IterDiffPane
---@field buf integer
---@field win integer
---@field side? 'old'|'new' side the pane shows in the split layout
---@field rows IterDocRow[] one per buffer line
---@field headers { mark?: integer, code?: integer, label?: integer }[] extmark ids of each section's header row
---@field width integer digits of the widest line number
---@field drawn table<integer, true> lines whose syntax and words this render requested
---@field marks_width? integer text width the marks were wrapped to
---@field autocmds? integer[] autocommands of the old side's pane

---@class IterDiffView: IterDiffPane
---@field document IterDocument the files shown and the line of each row
---@field layout IterDocLayout layout of the documents the view shows
---@field old? IterDiffPane the old side, in the split layout
---@field name? string buffer name, see `set_name`
---@field files IterFileDiff[] the files of the document, in order
---@field saved_winopts? table<string, any> restored when the view leaves a user window
---@field keys table<string, string[]>
---@field handlers table<string, fun()> bound actions, for help
---@field expand_step integer
---@field syntax_max_lines integer versions longer than this get no syntax
---@field word_diff boolean
---@field icon string shown before each annotation
---@field generation integer bumped by every render
---@field decorated integer equals `generation` once the syntax requested for it is applied
---@field pending integer syntax requests of this generation not answered yet
---@field paired table<integer, true> sections whose words this render paired
---@field prev_buf? integer buffer the window showed before the view
---@field annotations IterAnnotation[] stored annotations the view places on its files
---@field root? string repository of the annotations, whose versions decide outdated
---@field marks IterAnnotationMark[] annotations placed on the rows, by buffer line
---@field marks_drawn table<integer, true> lines whose annotations are drawn
---@field focus? string id of the annotation drawn as focused
---@field new_follows boolean a staged file's index equals its worktree, for a section that doesn't say
---@field reviewed? table<string, IterReviewedState> state per path the header rows show; nil shows no state and no annotation count
---@field on_cursor? fun()
---@field on_layout? fun()
---@field on_pane_replaced? fun(buf: integer, line: integer)
---@field group integer
local View = {}
View.__index = View

local NS = vim.api.nvim_create_namespace('iter.diff')
local NS_SYNTAX = vim.api.nvim_create_namespace('iter.diff.syntax')
local NS_WORDS = vim.api.nvim_create_namespace('iter.diff.words')
local NS_ANNOTATIONS = vim.api.nvim_create_namespace('iter.diff.annotations')

-- Del and add rows draw below syntax, word emphasis above it, so an
-- emphasis background also shows over a capture that sets one.
local ROW_PRIORITY = vim.hl.priorities.treesitter - 50
local WORD_PRIORITY = vim.hl.priorities.treesitter + 50

local WORD_HL = { add = 'IterDiffAddText', del = 'IterDiffDeleteText' }

-- Fill of a filler row, wider than any pane.
local FILL = string.rep('╱', 300)
local RULE = string.rep('─', 300)

-- Screens above and below the visible lines that a document of several
-- files decorates ahead, so scrolling shows them done.
local MARGIN_SCREENS = 2

-- Window-local options the view sets on the window it borrows.
local WINOPTS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    foldenable = false,
    wrap = false,
    list = false,
    spell = false,
    statuscolumn = "%!v:lua.require'iter.diff.view'.statuscolumn()",
    scrollbind = false,
    cursorbind = false,
}

-- The window options of both panes in the split layout.
local SPLIT_WINOPTS =
    vim.tbl_extend('force', WINOPTS, { scrollbind = true, cursorbind = true })

local ROW_HL = {
    header = 'IterDiffHeader',
    hunk = 'IterDiffHunk',
    gap = 'IterDiffGap',
    add = 'IterDiffAdd',
    del = 'IterDiffDelete',
}

-- Header text and group per reviewed state.
local REVIEWED_HEADER = {
    reviewed = { '✓ reviewed', 'IterReviewed' },
    changed = { '↻ changed since reviewed', 'IterReviewedChanged' },
    unreviewed = { '○ not reviewed', 'IterDrawerHint' },
}

---@type table<integer, IterDiffView>
local views = {}

---@param win integer
---@param values table<string, any>
local function set_winopts(win, values)
    for name, value in pairs(values) do
        pcall(
            vim.api.nvim_set_option_value,
            name,
            value,
            { scope = 'local', win = win }
        )
    end
end

---@param opts IterDiffViewOptions
---@return IterDiffView
function View.new(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.win', opts.win, 'number')
    vim.validate('opts.keys', opts.keys, 'table')
    vim.validate('opts.handlers', opts.handlers, 'table', true)
    vim.validate('opts.expand_step', opts.expand_step, 'number')
    vim.validate('opts.syntax_max_lines', opts.syntax_max_lines, 'number')
    vim.validate('opts.word_diff', opts.word_diff, 'boolean')
    vim.validate('opts.icon', opts.icon, 'string')
    vim.validate('opts.name', opts.name, 'string', true)
    vim.validate('opts.bufhidden', opts.bufhidden, 'string', true)
    vim.validate('opts.layout', opts.layout, 'string', true)
    vim.validate('opts.on_cursor', opts.on_cursor, 'function', true)
    vim.validate('opts.on_layout', opts.on_layout, 'function', true)
    vim.validate(
        'opts.on_pane_replaced',
        opts.on_pane_replaced,
        'function',
        true
    )

    highlight.setup()

    local self = setmetatable({
        buf = vim.api.nvim_create_buf(false, true),
        win = opts.win,
        document = document.build({}),
        layout = opts.layout or 'unified',
        files = {},
        rows = {},
        headers = {},
        width = 1,
        keys = opts.keys,
        expand_step = opts.expand_step,
        syntax_max_lines = opts.syntax_max_lines,
        word_diff = opts.word_diff,
        icon = opts.icon,
        generation = 0,
        decorated = 0,
        pending = 0,
        drawn = {},
        paired = {},
        annotations = {},
        marks = {},
        marks_drawn = {},
        new_follows = false,
        on_cursor = opts.on_cursor,
        on_layout = opts.on_layout,
        on_pane_replaced = opts.on_pane_replaced,
    }, View)

    vim.bo[self.buf].bufhidden = opts.bufhidden or 'wipe'
    vim.bo[self.buf].modifiable = false
    views[self.buf] = self
    self:own(self.buf)

    if opts.name ~= nil then
        self:set_name(opts.name)
    end

    self.group = vim.api.nvim_create_augroup(
        'iter.diff.view.' .. self.buf,
        { clear = true }
    )

    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = self.buf,
        callback = function()
            self:restore_winopts()
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = self.group,
        buffer = self.buf,
        callback = function(args)
            views[args.buf] = nil
            pcall(vim.api.nvim_del_augroup_by_id, self.group)
        end,
    })
    vim.api.nvim_create_autocmd('WinScrolled', {
        group = self.group,
        callback = function()
            for _, pane in ipairs(self:panes()) do
                if vim.v.event[tostring(pane.win)] ~= nil then
                    self:update_viewport()
                    return
                end
            end
        end,
    })
    self:watch_cursor(self.buf)

    self.handlers = vim.tbl_extend('force', {
        expand = function()
            self:expand()
        end,
    }, opts.handlers or {})
    keymap.attach(self.buf, 'diff', self.keys, self.handlers)

    return self
end

--- Name the view's buffer `name`, and the old side's `name#old`.
---@param name string
function View:set_name(name)
    self.name = name
    util.name_buf(self.buf, name)

    if self.old ~= nil then
        util.name_buf(self.old.buf, name .. '#old')
    end
end

--- Mark `buf`, a pane's buffer, as the view's: shown only in the view's
--- windows, drawn again after `:edit` emptied it.
---@param buf integer
function View:own(buf)
    require('iter.uri').own(buf, {
        owns = function(win)
            return win == self.win or (self.old ~= nil and self.old.win == win)
        end,
        reload = function()
            if self:is_shown() then
                self:show_document(self.document)
            end
        end,
        prev = function()
            return self.prev_buf
        end,
    })
end

--- Run `on_cursor` when the cursor moves in a window of the view that shows
--- `buf` and is the current one.
---@param buf integer
function View:watch_cursor(buf)
    vim.api.nvim_create_autocmd('CursorMoved', {
        group = self.group,
        buffer = buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()

            if
                self.on_cursor ~= nil
                and (win == self.win or (self.old and self.old.win == win))
            then
                self.on_cursor()
            end
        end,
    })
end

--- The panes of the view, left to right: the old side in the split layout,
--- then the view itself.
---@return IterDiffPane[]
function View:panes()
    return self.old ~= nil and { self.old, self } or { self }
end

--- The pane in the current window, else the view itself.
---@return IterDiffPane
function View:active()
    local old = self.old

    if old ~= nil and old.win == vim.api.nvim_get_current_win() then
        return old
    end

    return self
end

--- The side of the pane in the current window in the split layout, nil in
--- the unified layout.
---@return 'old'|'new'|nil
function View:active_side()
    return self:active().side
end

--- Open the old side's pane left of the view's window, unless it is open.
function View:open_old()
    if self.old ~= nil then
        return
    end

    local buf = vim.api.nvim_create_buf(false, true)

    -- Hidden, not wiped, when another buffer takes the window, so the
    -- pane can tell that from a close.
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].modifiable = false
    self:own(buf)

    if self.name ~= nil then
        util.name_buf(buf, self.name .. '#old')
    end

    -- Even from the start, as `even_widths` makes them: an equalize that a
    -- plugin schedules on the new window then changes the widths, so the
    -- WinResized that follows evens them again.
    local win = vim.api.nvim_open_win(buf, false, {
        split = 'left',
        win = self.win,
        width = math.floor((vim.api.nvim_win_get_width(self.win) - 1) / 2),
    })

    -- A new window copies the jumplist of the window it opens from.
    vim.api.nvim_win_call(win, function()
        vim.cmd.clearjumps()
    end)

    self.old = {
        buf = buf,
        win = win,
        side = 'old',
        rows = {},
        headers = {},
        width = 1,
        drawn = {},
    }
    views[buf] = self
    keymap.attach(buf, 'diff', self.keys, self.handlers)
    self:watch_cursor(buf)

    local old = self.old

    -- Closed or wiped from outside, the pane leaves the view unified.
    local function gone()
        if self.old ~= old then
            return
        end

        vim.schedule(function()
            if self.old ~= old then
                return
            end

            self:close_old()

            if vim.api.nvim_buf_is_valid(self.buf) then
                self:set_layout('unified')
            end
        end)
    end

    -- Another buffer in the window: the pane comes back in a window of its
    -- own and `on_pane_replaced` gets that buffer.
    local function replaced()
        vim.schedule(function()
            if
                self.old ~= old
                or not util.is_valid_win(win)
                or vim.api.nvim_win_get_buf(win) == buf
            then
                return
            end

            local other = vim.api.nvim_win_get_buf(win)
            local line = vim.api.nvim_win_get_cursor(win)[1]

            self:close_old()

            if self:is_shown() then
                self:show_document(self.document)
            end

            -- A buffer `:edit` made for an iter address is gone already.
            if
                self.on_pane_replaced ~= nil
                and vim.api.nvim_buf_is_valid(other)
            then
                self.on_pane_replaced(other, line)
            end
        end)
    end

    old.autocmds = {
        vim.api.nvim_create_autocmd('BufWipeout', {
            group = self.group,
            buffer = buf,
            callback = gone,
        }),
        vim.api.nvim_create_autocmd('BufWinLeave', {
            group = self.group,
            buffer = buf,
            callback = replaced,
        }),
        vim.api.nvim_create_autocmd('WinClosed', {
            group = self.group,
            pattern = tostring(win),
            callback = gone,
        }),
    }
end

--- Close the old side's pane, its window and its buffer.
function View:close_old()
    local old = self.old

    if old == nil then
        return
    end

    self.old = nil
    views[old.buf] = nil

    for _, id in ipairs(old.autocmds or {}) do
        pcall(vim.api.nvim_del_autocmd, id)
    end

    if util.is_valid_win(old.win) then
        if vim.api.nvim_get_current_win() == old.win then
            if util.is_valid_win(self.win) then
                vim.api.nvim_set_current_win(self.win)
            end
        end

        vim.api.nvim_win_close(old.win, true)
    end

    if vim.api.nvim_buf_is_valid(old.buf) then
        vim.api.nvim_buf_delete(old.buf, { force = true })
    end
end

--- Give both panes of the split layout half of their width together.
function View:even_widths()
    local old = self.old

    if
        old == nil
        or not util.is_valid_win(old.win)
        or not util.is_valid_win(self.win)
    then
        return
    end

    local width = vim.api.nvim_win_get_width(old.win)
    local half = math.floor((width + vim.api.nvim_win_get_width(self.win)) / 2)

    if width ~= half then
        vim.api.nvim_win_set_width(old.win, half)
    end
end

--- Give the other panes the cursor line and the top line of `from`, the
--- pane in the current window by default.
---@param from? IterDiffPane
function View:sync(from)
    if self.old == nil or not self:is_shown() then
        return
    end

    from = from or self:active()

    if not util.is_valid_win(from.win) then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(from.win)[1]

    -- Scrollbind keeps the offset between the windows at the time it was
    -- set; syncbind makes it 0 again.
    vim.api.nvim_win_call(from.win, function()
        vim.cmd('syncbind')
    end)

    for _, pane in ipairs(self:panes()) do
        if pane ~= from and util.is_valid_win(pane.win) then
            vim.api.nvim_win_set_cursor(pane.win, { lnum, 0 })
        end
    end
end

--- Show the documents in `layout` from now on, the one shown at once.
---@param layout IterDocLayout
function View:set_layout(layout)
    if layout == self.layout then
        return
    end

    self.layout = layout

    if self:is_shown() and #self.document.sections > 0 then
        self:show_document(self.document)
    elseif layout ~= 'split' then
        self:close_old()
    end

    if self.on_layout ~= nil then
        self.on_layout()
    end
end

---@param rows (IterDiffRow|IterDocSeparator)[]
---@return integer
local function number_width(rows)
    local max = 0

    for _, row in ipairs(rows) do
        max = math.max(max, row.old or 0, row.new or 0)

        if row.gap ~= nil then
            max = math.max(
                max,
                row.gap.old + row.gap.count - 1,
                row.gap.new + row.gap.count - 1
            )
        end
    end

    return math.max(3, #tostring(max))
end

--- The version a side of `file` shows: `HEAD`, `index` or `worktree`.
---@param file IterFileDiff
---@param side 'old'|'new'
---@return string
local function version_label(file, side)
    if side == 'old' then
        return anchor.OLD_BASE[file.side]
    end

    return file.side == 'staged' and 'index' or 'worktree'
end

--- The chunks of `chunks` that fit in `width` cells, dropping from the
--- front.
---@param chunks [string, string][]
---@param width integer
---@return [string, string][]
local function fit_chunks(chunks, width)
    local total = 0

    for _, chunk in ipairs(chunks) do
        total = total + vim.fn.strdisplaywidth(chunk[1])
    end

    local first = 1

    while first <= #chunks and total > width do
        total = total - vim.fn.strdisplaywidth(chunks[first][1])
        first = first + 1
    end

    return vim.list_slice(chunks, first)
end

--- Draw the header row of section `index`: the code letter, and at the
--- right the reviewed state, a mode change, the stat (`untracked · +n` for
--- an untracked file) and, where the reviewed state shows, the count of
--- annotations placed in the file, for an untracked file only when it has
--- any. In the split layout each side names its version after the path,
--- and only the new side shows the right part, with the reviewed state as its
--- glyph. The right part sheds its parts from the left where it would cover
--- the path. Drawn again in place, so the reviewed state and the count can
--- change alone.
---@param index integer
function View:decorate_header(index)
    local section = self.document.sections[index]
    local file = section.file
    local untracked = file.code == '?'
    local stat = file.binary and 'binary'
        or untracked and string.format('+%d', file.stat.add)
        or string.format('+%d −%d', file.stat.add, file.stat.del)

    if untracked then
        stat = 'untracked · ' .. stat
    end

    local count = 0

    for _, mark in ipairs(self.marks) do
        if mark.section == index then
            count = count + 1
        end
    end

    if self.reviewed ~= nil and (count > 0 or not untracked) then
        stat = string.format(
            '%s · %d %s',
            stat,
            count,
            count == 1 and 'annotation' or 'annotations'
        )
    end

    local virt_text = { { stat .. ' ', 'IterDiffHunk' } }

    if file.mode ~= nil then
        table.insert(virt_text, 1, {
            string.format('mode %s → %s  ', file.mode.old, file.mode.new),
            'IterDiffHunk',
        })
    end

    local state = REVIEWED_HEADER[self.reviewed and self.reviewed[file.path]]

    if state ~= nil then
        -- Half a window wide, the split layout shows the state's glyph only.
        local text = self.old ~= nil and vim.fn.strcharpart(state[1], 0, 1)
            or state[1]

        table.insert(virt_text, 1, { text .. '  ', state[2] })
    end

    local lnum = section.first - 1

    for _, pane in ipairs(self:panes()) do
        local ids = pane.headers[index] or {}
        local text =
            vim.api.nvim_buf_get_lines(pane.buf, lnum, lnum + 1, true)[1]
        local label = pane.side ~= nil
            and '  ' .. version_label(file, pane.side)
        local right = pane.side ~= 'old' and virt_text or nil

        if right ~= nil and vim.api.nvim_win_is_valid(pane.win) then
            local left = vim.fn.strdisplaywidth(file.code .. ' ' .. text)
                + vim.fn.strdisplaywidth(label or '')

            right = fit_chunks(right, self:text_width(pane) - left - 1)
            right = #right > 0 and right or nil
        end

        ids.code = vim.api.nvim_buf_set_extmark(pane.buf, NS, lnum, 0, {
            id = ids.code,
            virt_text = {
                {
                    file.code .. ' ',
                    { 'IterDiffHeader', 'IterDiffHeaderRule' },
                },
            },
            virt_text_pos = 'inline',
        })
        ids.mark = vim.api.nvim_buf_set_extmark(pane.buf, NS, lnum, 0, {
            id = ids.mark,
            line_hl_group = ROW_HL.header,
            virt_text = right,
            virt_text_pos = right and 'right_align' or nil,
            hl_mode = 'combine',
        })

        if label then
            ids.label =
                vim.api.nvim_buf_set_extmark(pane.buf, NS, lnum, #text, {
                    id = ids.label,
                    virt_text = { { label, 'IterDiffHunk' } },
                    virt_text_pos = 'inline',
                    hl_mode = 'combine',
                })
        end

        pane.headers[index] = ids
    end
end

---@param pane IterDiffPane
---@param row IterDocRow
---@param lnum integer
---@param expand_lhs? string
function View:decorate(pane, row, lnum, expand_lhs)
    local mark

    if row.kind == 'filler' then
        mark = {
            virt_text = { { FILL, 'IterDiffFiller' } },
            virt_text_pos = 'overlay',
        }
    elseif row.kind == 'blank' then
        mark = {
            virt_text = { { RULE, 'IterDiffHeaderRule' } },
            virt_text_pos = 'overlay',
        }
    elseif row.kind == 'add' or row.kind == 'del' then
        -- A line highlight would cover the word emphasis; a range under it
        -- lets syntax and words draw on top.
        mark = {
            end_row = lnum,
            end_col = 0,
            hl_eol = true,
            hl_group = ROW_HL[row.kind],
            priority = ROW_PRIORITY,
        }
    elseif row.kind == 'hunk' then
        mark = { line_hl_group = ROW_HL.hunk }
    elseif row.kind == 'gap' then
        local chunks = {
            {
                string.format(
                    '··· %d unchanged %s ···',
                    row.gap.count,
                    row.gap.count == 1 and 'line' or 'lines'
                ),
                'IterDiffGap',
            },
        }

        if expand_lhs ~= nil then
            table.insert(
                chunks,
                { '  ' .. expand_lhs .. ' expand', 'IterDiffHunk' }
            )
        end

        mark = {
            line_hl_group = ROW_HL.gap,
            virt_text = chunks,
            virt_text_pos = 'overlay',
        }
    end

    if mark ~= nil then
        vim.api.nvim_buf_set_extmark(pane.buf, NS, lnum - 1, 0, mark)
    end
end

---@class IterDiffSyntaxJob
---@field pane IterDiffPane
---@field lines string[] version the rows come from
---@field lang string
---@field lnums integer[] version lines to highlight
---@field targets integer[] buffer line of each entry in `lnums`

--- One job per version of `section` for the lines of `pane` between
--- `first` and `last` not drawn yet: del rows read the old version, add
--- rows the new one, context rows the new one, or on the old side the old
--- one. A version without a parser, above the size cap or missing
--- (hunk-only rows) gets none.
---@param pane IterDiffPane
---@param section IterDocSection
---@param first integer
---@param last integer
---@return IterDiffSyntaxJob[]
function View:syntax_jobs(pane, section, first, last)
    local file = section.file
    local sides = {
        { lines = file.old_lines, path = file.orig_path or file.path },
        { lines = file.new_lines, path = file.path },
    }
    local jobs = {}

    for index, side in ipairs(sides) do
        local lines = side.lines
        local old = index == 1
        local lang = (pane.side == nil or (pane.side == 'old') == old)
            and lines ~= nil
            and #lines > 0
            and #lines <= self.syntax_max_lines
            and syntax.lang(side.path)

        if lang then
            local job = {
                pane = pane,
                lines = lines,
                lang = lang,
                lnums = {},
                targets = {},
            }
            local kinds = old and { del = true, context = pane.side == 'old' }
                or { add = true, context = pane.side ~= 'old' }

            for lnum = math.max(first, section.first), math.min(last, section.last) do
                local row = pane.rows[lnum]
                local line = not pane.drawn[lnum]
                    and kinds[row.kind]
                    and (old and row.old or not old and row.new)

                if line then
                    table.insert(job.lnums, line)
                    table.insert(job.targets, lnum)
                end
            end

            if #job.lnums > 0 then
                table.insert(jobs, job)
            end
        end
    end

    return jobs
end

--- Request the syntax of `jobs` and apply it when it arrives, unless a
--- later render came first.
---@param jobs IterDiffSyntaxJob[]
function View:request_syntax(jobs)
    local generation = self.generation

    if #jobs == 0 then
        if self.pending == 0 then
            self.decorated = generation
        end

        return
    end

    self.pending = self.pending + #jobs
    self.decorated = math.min(self.decorated, generation - 1)

    for _, job in ipairs(jobs) do
        syntax.request(job.lines, job.lang, job.lnums, function(spans)
            if
                generation ~= self.generation
                or not vim.api.nvim_buf_is_valid(self.buf)
            then
                return
            end

            local pane = job.pane
            local targets = vim.api.nvim_buf_is_valid(pane.buf) and job.targets
                or {}

            for i, lnum in ipairs(targets) do
                local width = #pane.rows[lnum].text

                for _, span in ipairs(spans and spans[job.lnums[i]] or {}) do
                    if span.col < width then
                        vim.api.nvim_buf_set_extmark(
                            pane.buf,
                            NS_SYNTAX,
                            lnum - 1,
                            span.col,
                            {
                                end_col = math.min(span.end_col, width),
                                hl_group = span.hl,
                                priority = span.priority,
                            }
                        )
                    end
                end
            end

            self.pending = self.pending - 1

            if self.pending == 0 then
                self.decorated = generation
            end
        end)
    end
end

--- Syntax, word emphasis and annotations of lines `first` to `last` that
--- this render has not drawn yet.
---@param first integer
---@param last integer
function View:decorate_lines(first, last)
    local doc = self.document
    local panes = self:panes()
    local jobs = {}

    for _, index in ipairs(document.sections_in(doc, first, last)) do
        local section = doc.sections[index]

        if self.word_diff and not self.paired[index] then
            words.annotate(section.file.rows)
            self.paired[index] = true
        end

        for _, pane in ipairs(panes) do
            vim.list_extend(jobs, self:syntax_jobs(pane, section, first, last))
        end
    end

    for _, pane in ipairs(panes) do
        for lnum = first, last do
            if not pane.drawn[lnum] then
                local row = pane.rows[lnum]

                for _, range in ipairs(self.word_diff and row.words or {}) do
                    vim.api.nvim_buf_set_extmark(
                        pane.buf,
                        NS_WORDS,
                        lnum - 1,
                        range[1],
                        {
                            end_col = range[2],
                            hl_group = WORD_HL[row.kind],
                            priority = WORD_PRIORITY,
                        }
                    )
                end

                pane.drawn[lnum] = true
            end
        end
    end

    self:request_syntax(jobs)
    self:draw_marks(first, last)
end

--- The lines to decorate: all of them for one file, else the lines in view
--- and `MARGIN_SCREENS` screens around them, or around `lnum` when given.
---@param lnum? integer
---@return integer first
---@return integer last
function View:decor_range(lnum)
    local count = #self.rows

    if #self.document.sections <= 1 then
        return 1, count
    end

    if not self:is_shown() then
        return 1, 0
    end

    local height = vim.api.nvim_win_get_height(self.win)
    local top, bottom

    if lnum ~= nil then
        top, bottom = lnum - height, lnum + height
    else
        top, bottom = unpack(vim.api.nvim_win_call(self.win, function()
            return { vim.fn.line('w0'), vim.fn.line('w$') }
        end))
    end

    local margin = MARGIN_SCREENS * height

    return math.max(1, top - margin), math.min(count, bottom + margin)
end

--- Decorate the lines in view that are not yet; around `lnum` when given.
---@param lnum? integer
function View:update_viewport(lnum)
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end

    local first, last = self:decor_range(lnum)

    if first <= last then
        self:decorate_lines(first, last)
    end
end

--- The text of `row` in `pane`: the row's own, except that in the split
--- layout a header names the path of its side and a hunk row its range on
--- that side.
---@param pane IterDiffPane
---@param row IterDocRow
---@param file? IterFileDiff
---@return string
local function line_text(pane, row, file)
    if pane.side == nil or file == nil then
        return row.text
    end

    local old = pane.side == 'old'

    if row.kind == 'header' then
        return old and (file.orig_path or file.path) or file.path
    end

    local hunk = row.kind == 'hunk' and file.hunks[row.hunk]

    if hunk then
        local start = old and hunk.old_start or hunk.new_start
        local count = old and hunk.old_count or hunk.new_count

        return string.format(
            '@@ %s%d%s',
            old and '-' or '+',
            start,
            count == 1 and '' or (',' .. count)
        )
    end

    return row.text
end

--- Open or close the old side's pane for the document's layout. A pane
--- that comes or goes changes the windows around the view, so `on_layout`
--- runs then too.
function View:arrange()
    local had_old = self.old ~= nil

    if self.document.layout == 'split' and util.is_valid_win(self.win) then
        self:open_old()
        self.old.rows = self.document.old_rows
        self.side = 'new'
    else
        self:close_old()
        self.side = nil
    end

    if (self.old ~= nil) ~= had_old and self.on_layout ~= nil then
        self.on_layout()
    end
end

--- Write the rows into the buffers with their highlights.
function View:render()
    local doc = self.document
    local panes = self:panes()
    local width = 1

    for _, pane in ipairs(panes) do
        local lines = {}

        for lnum, row in ipairs(pane.rows) do
            local section = document.at(doc, lnum)

            lines[lnum] = line_text(pane, row, section and section.file)
        end

        -- Cleared first: replacing the lines moves every extmark still there.
        for _, ns in ipairs({ NS, NS_SYNTAX, NS_WORDS, NS_ANNOTATIONS }) do
            vim.api.nvim_buf_clear_namespace(pane.buf, ns, 0, -1)
        end

        vim.bo[pane.buf].modifiable = true
        vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
        vim.bo[pane.buf].modifiable = false

        width = math.max(width, number_width(pane.rows))
        pane.drawn, pane.headers = {}, {}
    end

    for _, pane in ipairs(panes) do
        pane.width = width
    end

    self.generation = self.generation + 1
    self.pending = 0
    self.paired = {}

    local expand_lhs = (self.keys.expand or {})[1]

    self:place_marks()

    for index in ipairs(doc.sections) do
        self:decorate_header(index)
    end

    for _, pane in ipairs(panes) do
        for lnum, row in ipairs(pane.rows) do
            self:decorate(pane, row, lnum, expand_lhs)
        end
    end

    self:update_viewport()

    if self:is_shown() then
        -- Setting the option again lets the rail shrink to a new width.
        for _, pane in ipairs(panes) do
            set_winopts(pane.win, { statuscolumn = WINOPTS.statuscolumn })
        end
    end
end

--- Width of the text area of `pane`, the view's own by default, right of
--- the rail, which the view's options make the only column in front of the
--- text.
---@param pane? IterDiffPane
---@return integer
function View:text_width(pane)
    pane = pane or self

    if not vim.api.nvim_win_is_valid(pane.win) then
        return 1
    end

    local rail = pane.side ~= nil and pane.width + 3 or 2 * pane.width + 4

    return math.max(1, vim.api.nvim_win_get_width(pane.win) - rail)
end

--- Place the annotations on the rows of every section, by buffer line; in
--- a collapsed section hidden, on its header row.
function View:place_marks()
    local doc = self.document
    local lines_of = self.root and list.reader(self.root)

    self.marks = {}
    self.marks_drawn = {}

    for index, section in ipairs(doc.sections) do
        local new_follows = section.new_follows

        if new_follows == nil then
            new_follows = self.new_follows
        end

        for _, mark in
            ipairs(
                marks.place(
                    section.file,
                    self.annotations,
                    { new_follows = new_follows, lines_of = lines_of or nil }
                )
            )
        do
            local lnum = document.line_of(doc, index, mark.lnum)

            mark.lnum = lnum or section.first
            mark.hidden = lnum == nil or section.collapsed or nil
            mark.section = index
            table.insert(self.marks, mark)
        end
    end
end

--- Draw the annotations below lines `first` to `last` not drawn yet,
--- wrapped to the window. In the split layout an annotation shows on the
--- side it anchors to, a file annotation on the new side, and the other
--- side gets as many blank lines, so the rows stay aligned.
---@param first integer
---@param last integer
function View:draw_marks(first, last)
    local panes = self:panes()
    local icon = self.icon
    local by_row, order = {}, {}

    for _, pane in ipairs(panes) do
        pane.marks_width = self:text_width(pane)
    end

    for _, mark in ipairs(self.marks) do
        local lnum = mark.lnum

        if
            not mark.hidden
            and lnum >= first
            and lnum <= last
            and not self.marks_drawn[lnum]
        then
            if by_row[lnum] == nil then
                by_row[lnum] = {}
                table.insert(order, lnum)
            end

            table.insert(by_row[lnum], mark)
        end
    end

    for _, lnum in ipairs(order) do
        local lines, height = {}, 0

        for i, pane in ipairs(panes) do
            lines[i] = {}

            for _, mark in ipairs(by_row[lnum]) do
                local side = mark.annotation.anchor.side == 'old' and 'old'
                    or 'new'

                if pane.side == nil or pane.side == side then
                    vim.list_extend(
                        lines[i],
                        marks.lines(
                            mark.annotation,
                            mark.outdated,
                            pane.marks_width,
                            self.focus ~= nil
                                and mark.annotation.id == self.focus,
                            icon
                        )
                    )
                end
            end

            height = math.max(height, #lines[i])
        end

        for i, pane in ipairs(panes) do
            while #lines[i] < height do
                table.insert(lines[i], {})
            end

            vim.api.nvim_buf_set_extmark(
                pane.buf,
                NS_ANNOTATIONS,
                lnum - 1,
                0,
                { virt_lines = lines[i] }
            )
        end

        self.marks_drawn[lnum] = true
    end
end

--- Place and draw the annotations again, and the header counts with them.
function View:render_marks()
    for _, pane in ipairs(self:panes()) do
        vim.api.nvim_buf_clear_namespace(pane.buf, NS_ANNOTATIONS, 0, -1)
    end

    self:place_marks()

    for index in ipairs(self.document.sections) do
        self:decorate_header(index)
    end

    local first, last = self:decor_range()

    self:draw_marks(first, last)
end

--- Draw the annotation with id `id` as focused, the others as usual; nil
--- focuses none.
---@param id? string
function View:set_focus(id)
    if id == self.focus then
        return
    end

    self.focus = id

    if vim.api.nvim_buf_is_valid(self.buf) then
        self:render_marks()
    end
end

--- Show `annotations`, the stored ones of the repository at `root`, on the
--- files.
---@param annotations IterAnnotation[]
---@param root? string
function View:set_annotations(annotations, root)
    self.annotations = annotations
    self.root = root

    if vim.api.nvim_buf_is_valid(self.buf) then
        self:render_marks()
    end
end

--- Show the reviewed state of each file, by path, in its header row with the
--- count of its annotations; nil shows neither.
---@param states? table<string, IterReviewedState>
function View:set_reviewed(states)
    self.reviewed = states

    if vim.api.nvim_buf_is_valid(self.buf) then
        for index in ipairs(self.document.sections) do
            self:decorate_header(index)
        end
    end
end

--- Tell the view whether a staged file's index is also its worktree
--- version, which lets a miss there outdate a new-side annotation. Sections
--- that carry `new_follows` themselves keep theirs.
---@param value boolean
function View:set_new_follows(value)
    if value == self.new_follows then
        return
    end

    self.new_follows = value

    if vim.api.nvim_buf_is_valid(self.buf) then
        self:render_marks()
    end
end

--- Wrap the annotations again when the window width changed.
function View:rewrap()
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end

    for _, pane in ipairs(self:panes()) do
        if self:text_width(pane) ~= pane.marks_width then
            self:render_marks()
            return
        end
    end
end

---@return boolean
function View:is_shown()
    return vim.api.nvim_win_is_valid(self.win)
        and vim.api.nvim_win_get_buf(self.win) == self.buf
end

---@param row IterDiffRow
---@return 'new'|'old'|nil side
---@return integer? number
local function row_number(row)
    if row.new ~= nil then
        return 'new', row.new
    elseif row.gap ~= nil then
        return 'new', row.gap.new
    elseif row.old ~= nil then
        return 'old', row.old
    end

    return nil, nil
end

--- The row of `rows` nearest to `row` of an earlier render: the same kind
--- and text closest by line number, else the closest line number on the
--- same side, else `lnum` itself.
---@param rows IterDiffRow[]
---@param row IterDiffRow
---@param lnum integer
---@return integer
local function nearest_row(rows, row, lnum)
    local side, number = row_number(row)

    if side == nil then
        return math.min(lnum, #rows)
    end

    local best, best_same, distance, distance_same

    for index, candidate in ipairs(rows) do
        local candidate_side, candidate_number = row_number(candidate)

        if candidate_side == side then
            local d = math.abs(candidate_number - number)

            if distance == nil or d < distance then
                best, distance = index, d
            end

            if
                candidate.kind == row.kind
                and candidate.text == row.text
                and (distance_same == nil or d < distance_same)
            then
                best_same, distance_same = index, d
            end
        end
    end

    return best_same or best or math.min(lnum, #rows)
end

--- The line of `doc` that shows what row `row` of section `before` of an
--- earlier document showed: the same file near that row. With several
--- files, a file gone from its side falls back to the same path on the
--- other side, then to the header of the file at the same position.
---@param doc IterDocument
---@param before IterDocSection
---@param row integer
---@param position integer index of `before` in its document
---@return integer?
local function restored_line(doc, before, row, position)
    local index = document.find(doc, before.key)
    local several = #doc.sections > 1

    if index == nil and several then
        for i, section in ipairs(doc.sections) do
            if section.file.path == before.file.path then
                index = i
                break
            end
        end

        if index == nil then
            local fallback = doc.sections[math.min(position, #doc.sections)]

            return fallback and fallback.first
        end
    end

    if index == nil then
        return nil
    end

    local section = doc.sections[index]

    return document.line_of(
        doc,
        index,
        nearest_row(section.file.rows, before.file.rows[row], row)
    ) or section.first
end

--- Show `doc` in the borrowed window, built again in the view's layout
--- when it has another; the split layout opens the old side left of it.
--- The window's own options are saved the first time and come back as soon
--- as the view leaves it. The file under the cursor stays under it near its
--- row when `doc` shows it again, and so does the row at the top of the
--- window while it belongs to that file; else the cursor starts at the top.
---@param doc IterDocument
function View:show_document(doc)
    local cursor, view, before, row, position, top_row

    if doc.layout ~= self.layout then
        doc = document.build(doc.sections, self.layout)
    end

    if self:is_shown() then
        local active = self:active()

        cursor = vim.api.nvim_win_get_cursor(active.win)
        view = vim.api.nvim_win_call(active.win, vim.fn.winsaveview)
        before, row, position =
            document.at(self.document, cursor[1], active.side)

        if before ~= nil and row == nil then
            row = #before.file.rows
        end

        local top_section
        top_section, top_row =
            document.at(self.document, view.topline, active.side)

        if top_section ~= before then
            top_row = nil
        end
    end

    self.document = doc
    self.files = vim.tbl_map(function(section)
        return section.file
    end, doc.sections)
    self.rows = doc.rows
    self:arrange()
    self:render()

    if not vim.api.nvim_win_is_valid(self.win) then
        return
    end

    if not self:is_shown() then
        self.prev_buf = vim.api.nvim_win_get_buf(self.win)
        self.saved_winopts = {}

        for name in pairs(WINOPTS) do
            self.saved_winopts[name] = vim.api.nvim_get_option_value(
                name,
                { scope = 'local', win = self.win }
            )
        end

        vim.api.nvim_win_set_buf(self.win, self.buf)
    end

    for _, pane in ipairs(self:panes()) do
        set_winopts(pane.win, self.old and SPLIT_WINOPTS or WINOPTS)
    end

    local lnum = before ~= nil
        and row ~= nil
        and restored_line(doc, before, row, position --[[@as integer]])
    local active = self:active()

    if lnum and cursor ~= nil and view ~= nil then
        local top = top_row
            and before
            and restored_line(doc, before, top_row, position --[[@as integer]])
        local topline = top and top <= lnum and top
            or math.max(1, view.topline + lnum - cursor[1])

        vim.api.nvim_win_call(active.win, function()
            vim.fn.winrestview({
                lnum = lnum,
                col = cursor[2],
                topline = topline,
            })
        end)
    else
        vim.api.nvim_win_set_cursor(active.win, { 1, 0 })
    end

    self:sync(active)
    self:update_viewport()
end

--- Show `file` alone in the borrowed window, see `show_document`.
---@param file IterFileDiff
function View:show(file)
    self:show_document(document.build({ { file = file } }, self.layout))
end

--- Show the files of `entries` one below the other, see `show_document`.
---@param entries IterDocEntry[]
function View:show_all(entries)
    self:show_document(document.build(entries, self.layout))
end

function View:restore_winopts()
    if self.saved_winopts == nil or not vim.api.nvim_win_is_valid(self.win) then
        return
    end

    set_winopts(self.win, self.saved_winopts)
    self.saved_winopts = nil
end

--- Give the window back its previous buffer and options, and close the old
--- side's pane. The view stays usable: the next `show()` borrows the window
--- again.
function View:hide()
    self:close_old()

    if not self:is_shown() then
        return
    end

    local target = self.prev_buf

    if target == nil or not vim.api.nvim_buf_is_valid(target) then
        target = vim.api.nvim_create_buf(true, false)
    end

    -- 'bufhidden' only acts when the buffer leaves its last window.
    local bufhidden = vim.bo[self.buf].bufhidden
    vim.bo[self.buf].bufhidden = 'hide'
    vim.api.nvim_win_set_buf(self.win, target)
    vim.bo[self.buf].bufhidden = bufhidden
end

--- Give the window back its previous buffer and options. The view's buffer
--- is wiped with it.
function View:close()
    self:hide()

    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end
end

--- `lnum`, else the cursor line of the pane in the current window, else
--- of the view's window.
---@param lnum? integer
---@return integer?
function View:cursor_line(lnum)
    if lnum == nil and self:is_shown() then
        lnum = vim.api.nvim_win_get_cursor(self:active().win)[1]
    end

    return lnum
end

--- The row at `lnum`, the cursor line by default.
---@param lnum? integer
---@return (IterDiffRow|IterDocSeparator)?
function View:row(lnum)
    lnum = self:cursor_line(lnum)

    return lnum and self.rows[lnum]
end

--- The section at `lnum`, the cursor line by default, with the model row
--- of its file there (nil on a separator; in the split layout the row of
--- the side in the current window) and the section's index.
---@param lnum? integer
---@return IterDocSection? section
---@return integer? row
---@return integer? index
function View:at(lnum)
    lnum = self:cursor_line(lnum)

    if lnum == nil then
        return nil, nil, nil
    end

    return document.at(self.document, lnum, self:active_side())
end

--- The file at `lnum`, the cursor line by default.
---@param lnum? integer
---@return IterFileDiff?
function View:file(lnum)
    local section = self:at(lnum)

    return section and section.file
end

--- Move the cursor to `lnum` with the lines around it decorated first, so
--- annotations drawn later never shift the view. `align` scrolls the line
--- to the middle (`center`) or the top (`top`) of the window.
---@param lnum integer
---@param align? 'center'|'top'
function View:reveal(lnum, align)
    if not self:is_shown() then
        return
    end

    local active = self:active()

    self:update_viewport(lnum)
    vim.api.nvim_win_set_cursor(active.win, { lnum, 0 })

    if align ~= nil then
        vim.api.nvim_win_call(active.win, function()
            vim.cmd(align == 'center' and 'normal! zz' or 'normal! zt')
        end)
    end

    self:sync(active)
end

--- Reveal hidden context of the gap at `lnum`, the cursor line by default.
---@param lnum? integer
function View:expand(lnum)
    local active = self:active()
    local cursor = self:is_shown() and vim.api.nvim_win_get_cursor(active.win)
        or nil

    if lnum == nil and cursor ~= nil then
        lnum = cursor[1]
    end

    local section, row = self:at(lnum)

    if section == nil or row == nil then
        return
    end

    if model.expand(section.file, row, self.expand_step) == 0 then
        return
    end

    local doc = document.build(self.document.sections, self.layout)

    self.document = doc
    self.rows = doc.rows
    self:arrange()
    self:render()

    if cursor ~= nil then
        vim.api.nvim_win_set_cursor(active.win, cursor)
        self:sync(active)
        self:update_viewport()
    end
end

--- Show every row of the collapsed sections of `path`, on both sides; the
--- cursor stays on the row it is on.
---@param path string
function View:expand_path(path)
    local found = false

    for _, section in ipairs(self.document.sections) do
        if section.collapsed and section.file.path == path then
            section.collapsed = nil
            found = true
        end
    end

    if found then
        self:show_document(document.build(self.document.sections, self.layout))
    end
end

--- Move the cursor to the next (`dir` 1) or previous (-1) hunk row. At the
--- last or first hunk the cursor stays.
---@param dir 1|-1
function View:jump_hunk(dir)
    if not self:is_shown() then
        return
    end

    local lnum = self:cursor_line() + dir

    while lnum >= 1 and lnum <= #self.rows do
        if self.rows[lnum].kind == 'hunk' then
            self:reveal(lnum)
            return
        end

        lnum = lnum + dir
    end
end

--- Move the cursor to the next (`dir` 1) or previous (-1) row with a
--- annotation. At the last or first one the cursor stays.
---@param dir 1|-1
function View:jump_annotation(dir)
    if not self:is_shown() then
        return
    end

    local lnum = self:cursor_line() --[[@as integer]]
    local first = dir == 1 and 1 or #self.marks
    local last = dir == 1 and #self.marks or 1

    for i = first, last, dir do
        local target = self.marks[i].lnum

        if not self.marks[i].hidden and (target - lnum) * dir > 0 then
            self:reveal(target)
            return
        end
    end
end

--- Move the cursor to the next (`dir` 1) or previous (-1) file header. At
--- the last or first one the cursor stays.
---@param dir 1|-1
---@return boolean moved
function View:jump_file(dir)
    if not self:is_shown() then
        return false
    end

    local lnum = self:cursor_line() --[[@as integer]]
    local sections = self.document.sections
    local first = dir == 1 and 1 or #sections
    local last = dir == 1 and #sections or 1

    for i = first, last, dir do
        local target = sections[i].first

        if (target - lnum) * dir > 0 then
            self:reveal(target)
            return true
        end
    end

    return false
end

---@class IterDiffRailFormats
---@field blank string rail of a row without numbers
---@field context string
---@field del string
---@field add string
---@field filler? string
---@field header string rail of a file header row
---@field rule string rail of the blank row above a file header

---@type table<string, IterDiffRailFormats>
local rail_formats = {}

--- The rail formats of a pane on `side` (nil in the unified layout) for
--- line numbers `width` digits wide: old and new numbers and the sign, or
--- in the split layout the number of the pane's side and the sign.
---@param width integer
---@param side? 'old'|'new'
---@return IterDiffRailFormats
local function formats_for(width, side)
    local id = (side or 'unified') .. width
    local formats = rail_formats[id]

    if formats == nil then
        local number = '%' .. width .. 'd'
        local none = string.rep(' ', width)
        local cells = side == nil and 2 * width + 4 or width + 3
        local blank = string.rep(' ', cells)
        local header = '%#IterDiffHeader#' .. blank
        local rule = '%#IterDiffHeaderRule#' .. RULE:sub(1, 3 * cells)

        if side == nil then
            formats = {
                blank = blank,
                header = header,
                rule = rule,
                context = '%%#IterDiffNr#' .. number .. ' ' .. number .. '   ',
                del = '%%#IterDiffDeleteNr#' .. number .. ' ' .. none .. ' - ',
                add = '%%#IterDiffAddNr#' .. none .. ' ' .. number .. ' + ',
            }
        else
            formats = {
                blank = blank,
                header = header,
                rule = rule,
                context = '%%#IterDiffNr#' .. number .. '   ',
                del = '%%#IterDiffDeleteNr#' .. number .. ' - ',
                add = '%%#IterDiffAddNr#' .. number .. ' + ',
                filler = '%#IterDiffFiller#' .. FILL:sub(1, 3 * (width + 3)),
            }
        end

        rail_formats[id] = formats
    end

    return formats
end

--- 'statuscolumn' of a diff view: old and new line numbers and the change
--- sign, in the split layout the number of the pane's side, the header
--- band on a file header, the rule above it, blank on virtual and wrapped
--- lines.
---@return string
function View.statuscolumn()
    local buf = vim.api.nvim_win_get_buf(vim.g.statusline_winid)
    local view = views[buf]

    if view == nil then
        return ''
    end

    local pane = view.old ~= nil and view.old.buf == buf and view.old or view
    local formats = formats_for(pane.width, pane.side)
    local row = pane.rows[vim.v.lnum]

    if row == nil or vim.v.virtnum ~= 0 then
        return formats.blank
    end

    local kind = row.kind

    if kind == 'filler' then
        return formats.filler or formats.blank
    elseif kind == 'header' then
        return formats.header
    elseif kind == 'blank' then
        return formats.rule
    elseif kind == 'context' then
        if pane.side ~= nil then
            return string.format(
                formats.context,
                pane.side == 'old' and row.old or row.new
            )
        end

        return string.format(formats.context, row.old, row.new)
    elseif kind == 'del' then
        return string.format(formats.del, row.old)
    elseif kind == 'add' then
        return string.format(formats.add, row.new)
    end

    return formats.blank
end

return View
