local document = require('iter.diff.document')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local marks = require('iter.annotations.marks')
local model = require('iter.diff.model')
local syntax = require('iter.diff.syntax')
local util = require('iter.util')
local words = require('iter.diff.words')

---@class IterDiffViewOptions
---@field win integer window the view borrows
---@field keys? table<string, string[]> resolved `keys.diff`
---@field handlers? table<string, fun()> diff actions; an `expand` here replaces the view's own
---@field expand_step? integer
---@field syntax_max_lines? integer
---@field word_diff? boolean
---@field name? string buffer name, `iter://diff/<buf>` by default
---@field bufhidden? string 'bufhidden' of the buffer, `wipe` by default

---@class IterDiffView
---@field buf integer
---@field win integer
---@field document IterDocument the files shown and the line of each row
---@field files IterFileDiff[] the files of the document, in order
---@field rows (IterDiffRow|IterDocSeparator)[] one per buffer line
---@field headers { mark?: integer, code?: integer }[] extmark ids of each section's header row
---@field saved_winopts? table<string, any> restored when the view leaves a user window
---@field width integer digits of the widest line number
---@field keys table<string, string[]>
---@field handlers table<string, fun()> bound actions, for help
---@field expand_step integer
---@field syntax_max_lines integer versions longer than this get no syntax
---@field word_diff boolean
---@field generation integer bumped by every render
---@field decorated integer equals `generation` once the syntax requested for it is applied
---@field pending integer syntax requests of this generation not answered yet
---@field drawn table<integer, true> lines whose syntax and words this render requested
---@field paired table<integer, true> sections whose words this render paired
---@field prev_buf? integer buffer the window showed before the view
---@field annotations IterAnnotation[] stored annotations the view places on its files
---@field marks IterAnnotationMark[] annotations placed on the rows, by buffer line
---@field marks_drawn table<integer, true> lines whose annotations are drawn
---@field marks_width? integer text width the marks were wrapped to
---@field focus? string id of the annotation drawn as focused
---@field new_follows boolean a staged file's index equals its worktree, for a section that doesn't say
---@field viewed? table<string, IterViewedState> state per path the header rows show; nil shows no state and no annotation count
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
}

local ROW_HL = {
    header = 'IterDiffHeader',
    hunk = 'IterDiffHunk',
    gap = 'IterDiffGap',
    add = 'IterDiffAdd',
    del = 'IterDiffDelete',
}

-- Header text and group per viewed state.
local VIEWED_HEADER = {
    viewed = { '✓ viewed', 'IterViewed' },
    changed = { '↻ changed since viewed', 'IterViewedChanged' },
    unviewed = { '○ not viewed', 'IterDrawerHint' },
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
    vim.validate('opts.keys', opts.keys, 'table', true)
    vim.validate('opts.handlers', opts.handlers, 'table', true)
    vim.validate('opts.expand_step', opts.expand_step, 'number', true)
    vim.validate('opts.syntax_max_lines', opts.syntax_max_lines, 'number', true)
    vim.validate('opts.word_diff', opts.word_diff, 'boolean', true)
    vim.validate('opts.name', opts.name, 'string', true)
    vim.validate('opts.bufhidden', opts.bufhidden, 'string', true)

    local config = require('iter').config

    highlight.setup()

    local self = setmetatable({
        buf = vim.api.nvim_create_buf(false, true),
        win = opts.win,
        document = document.build({}),
        files = {},
        rows = {},
        headers = {},
        width = 1,
        keys = opts.keys or config.keys.diff,
        expand_step = opts.expand_step or config.options.diff.expand_step,
        syntax_max_lines = opts.syntax_max_lines
            or config.options.diff.syntax_max_lines,
        word_diff = opts.word_diff,
        generation = 0,
        decorated = 0,
        pending = 0,
        drawn = {},
        paired = {},
        annotations = {},
        marks = {},
        marks_drawn = {},
        new_follows = false,
    }, View)

    if self.word_diff == nil then
        self.word_diff = config.options.diff.word_diff
    end

    vim.bo[self.buf].bufhidden = opts.bufhidden or 'wipe'
    vim.bo[self.buf].modifiable = false
    util.name_buf(self.buf, opts.name or ('iter://diff/' .. self.buf))
    views[self.buf] = self

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
            if vim.v.event[tostring(self.win)] ~= nil then
                self:update_viewport()
            end
        end,
    })

    self.handlers = vim.tbl_extend('force', {
        expand = function()
            self:expand()
        end,
    }, opts.handlers or {})
    keymap.attach(self.buf, 'diff', self.keys, self.handlers)

    return self
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

--- Draw the header row of section `index`: the code letter, and at the
--- right the viewed state, a mode change, the stat (`untracked · +n` for
--- an untracked file) and, where the viewed state shows, the count of
--- annotations placed in the file, for an untracked file only when it has
--- any. Drawn again in place, so the viewed state and the count can change
--- alone.
---@param index integer
function View:decorate_header(index)
    local section = self.document.sections[index]
    local file = section.file
    local ids = self.headers[index] or {}
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

    if self.viewed ~= nil and (count > 0 or not untracked) then
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

    local state = VIEWED_HEADER[self.viewed and self.viewed[file.path]]

    if state ~= nil then
        table.insert(virt_text, 1, { state[1] .. '  ', state[2] })
    end

    ids.code =
        vim.api.nvim_buf_set_extmark(self.buf, NS, section.first - 1, 0, {
            id = ids.code,
            virt_text = { { file.code .. ' ', 'IterDiffHeader' } },
            virt_text_pos = 'inline',
        })
    ids.mark =
        vim.api.nvim_buf_set_extmark(self.buf, NS, section.first - 1, 0, {
            id = ids.mark,
            line_hl_group = ROW_HL.header,
            virt_text = virt_text,
            virt_text_pos = 'right_align',
        })
    self.headers[index] = ids
end

---@param row IterDiffRow|IterDocSeparator
---@param lnum integer
---@param expand_lhs? string
function View:decorate(row, lnum, expand_lhs)
    local mark

    if row.kind == 'add' or row.kind == 'del' then
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
                    '··· %d unchanged lines ···',
                    row.gap.count
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
        vim.api.nvim_buf_set_extmark(self.buf, NS, lnum - 1, 0, mark)
    end
end

---@class IterDiffSyntaxJob
---@field lines string[] version the rows come from
---@field lang string
---@field lnums integer[] version lines to highlight
---@field targets integer[] buffer line of each entry in `lnums`

--- One job per version of `section` for its lines between `first` and
--- `last` not drawn yet: del rows read the old version, context and add
--- rows the new one. A version without a parser, above the size cap or
--- missing (hunk-only rows) gets none.
---@param section IterDocSection
---@param first integer
---@param last integer
---@return IterDiffSyntaxJob[]
function View:syntax_jobs(section, first, last)
    local file = section.file
    local sides = {
        { lines = file.old_lines, path = file.orig_path or file.path },
        { lines = file.new_lines, path = file.path },
    }
    local jobs = {}

    for index, side in ipairs(sides) do
        local lines = side.lines
        local lang = lines ~= nil
            and #lines > 0
            and #lines <= self.syntax_max_lines
            and syntax.lang(side.path)

        if lang then
            local job = { lines = lines, lang = lang, lnums = {}, targets = {} }

            for lnum = math.max(first, section.first), math.min(last, section.last) do
                local row = self.rows[lnum]
                local line = not self.drawn[lnum]
                    and (
                        index == 1 and row.kind == 'del' and row.old
                        or index == 2
                            and (row.kind == 'context' or row.kind == 'add')
                            and row.new
                    )

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

            for i, lnum in ipairs(job.targets) do
                local width = #self.rows[lnum].text

                for _, span in ipairs(spans and spans[job.lnums[i]] or {}) do
                    if span.col < width then
                        vim.api.nvim_buf_set_extmark(
                            self.buf,
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
    local jobs = {}

    for _, index in ipairs(document.sections_in(doc, first, last)) do
        local section = doc.sections[index]

        if self.word_diff and not self.paired[index] then
            words.annotate(section.file.rows)
            self.paired[index] = true
        end

        vim.list_extend(jobs, self:syntax_jobs(section, first, last))
    end

    for lnum = first, last do
        if not self.drawn[lnum] then
            local row = self.rows[lnum]

            for _, range in ipairs(self.word_diff and row.words or {}) do
                vim.api.nvim_buf_set_extmark(
                    self.buf,
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

            self.drawn[lnum] = true
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

--- Write the rows into the buffer with their highlights.
function View:render()
    local lines = vim.tbl_map(function(row)
        return row.text
    end, self.rows)

    -- Cleared first: replacing the lines moves every extmark still there.
    for _, ns in ipairs({ NS, NS_SYNTAX, NS_WORDS, NS_ANNOTATIONS }) do
        vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    end

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false

    self.width = number_width(self.rows)
    self.generation = self.generation + 1
    self.pending = 0
    self.drawn, self.paired, self.headers = {}, {}, {}

    local expand_lhs = (self.keys.expand or {})[1]

    self:place_marks()

    for index in ipairs(self.document.sections) do
        self:decorate_header(index)
    end

    for lnum, row in ipairs(self.rows) do
        self:decorate(row, lnum, expand_lhs)
    end

    self:update_viewport()

    if self:is_shown() then
        -- Setting the option again lets the rail shrink to a new width.
        set_winopts(self.win, { statuscolumn = WINOPTS.statuscolumn })
    end
end

--- Width of the text area right of the rail, which the view's options make
--- the only column in front of the text.
---@return integer
function View:text_width()
    if not vim.api.nvim_win_is_valid(self.win) then
        return 1
    end

    return math.max(
        1,
        vim.api.nvim_win_get_width(self.win) - 2 * self.width - 4
    )
end

--- Place the annotations on the rows of every section, by buffer line.
function View:place_marks()
    local doc = self.document

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
                    { new_follows = new_follows }
                )
            )
        do
            mark.lnum = section.first + mark.lnum - 1
            mark.section = index
            table.insert(self.marks, mark)
        end
    end
end

--- Draw the annotations below lines `first` to `last` not drawn yet,
--- wrapped to the window.
---@param first integer
---@param last integer
function View:draw_marks(first, last)
    local width = self:text_width()
    local icon = require('iter').config.options.icons.annotation
    local by_row, order = {}, {}

    self.marks_width = width

    for _, mark in ipairs(self.marks) do
        local lnum = mark.lnum

        if lnum >= first and lnum <= last and not self.marks_drawn[lnum] then
            if by_row[lnum] == nil then
                by_row[lnum] = {}
                table.insert(order, lnum)
            end

            vim.list_extend(
                by_row[lnum],
                marks.lines(
                    mark.annotation,
                    mark.outdated,
                    width,
                    self.focus ~= nil and mark.annotation.id == self.focus,
                    icon
                )
            )
        end
    end

    for _, lnum in ipairs(order) do
        vim.api.nvim_buf_set_extmark(self.buf, NS_ANNOTATIONS, lnum - 1, 0, {
            virt_lines = by_row[lnum],
        })
        self.marks_drawn[lnum] = true
    end
end

--- Place and draw the annotations again, and the header counts with them.
function View:render_marks()
    vim.api.nvim_buf_clear_namespace(self.buf, NS_ANNOTATIONS, 0, -1)
    self:place_marks()

    for index in ipairs(self.document.sections) do
        self:decorate_header(index)
    end

    local first, last = self:decor_range()

    self.marks_width = self:text_width()
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

--- Show `annotations`, the stored ones of the repository, on the files.
---@param annotations IterAnnotation[]
function View:set_annotations(annotations)
    self.annotations = annotations

    if vim.api.nvim_buf_is_valid(self.buf) then
        self:render_marks()
    end
end

--- Show the viewed state of each file, by path, in its header row with the
--- count of its annotations; nil shows neither.
---@param states? table<string, IterViewedState>
function View:set_viewed(states)
    self.viewed = states

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
    if
        vim.api.nvim_buf_is_valid(self.buf)
        and self:text_width() ~= self.marks_width
    then
        self:render_marks()
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

    local rows = doc.sections[index].file.rows

    return document.line_of(
        doc,
        index,
        nearest_row(rows, before.file.rows[row], row)
    )
end

--- Show `doc` in the borrowed window. The window's own options are saved
--- the first time and come back as soon as the view leaves it. The file
--- under the cursor stays under it near its row when `doc` shows it again;
--- else the cursor starts at the top.
---@param doc IterDocument
function View:show_document(doc)
    local cursor, view, before, row, position

    if self:is_shown() then
        cursor = vim.api.nvim_win_get_cursor(self.win)
        view = vim.api.nvim_win_call(self.win, vim.fn.winsaveview)
        before, row, position = document.at(self.document, cursor[1])

        if before ~= nil and row == nil then
            row = #before.file.rows
        end
    end

    self.document = doc
    self.files = vim.tbl_map(function(section)
        return section.file
    end, doc.sections)
    self.rows = doc.rows
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

    set_winopts(self.win, WINOPTS)

    local lnum = before ~= nil
        and row ~= nil
        and restored_line(doc, before, row, position --[[@as integer]])

    if lnum and cursor ~= nil and view ~= nil then
        local topline = math.max(1, view.topline + lnum - cursor[1])

        vim.api.nvim_win_call(self.win, function()
            vim.fn.winrestview({
                lnum = lnum,
                col = cursor[2],
                topline = topline,
            })
        end)
    else
        vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
    end

    self:update_viewport()
end

--- Show `file` alone in the borrowed window, see `show_document`.
---@param file IterFileDiff
function View:show(file)
    self:show_document(document.build({ { file = file } }))
end

--- Show the files of `entries` one below the other, see `show_document`.
---@param entries IterDocEntry[]
function View:show_all(entries)
    self:show_document(document.build(entries))
end

function View:restore_winopts()
    if self.saved_winopts == nil or not vim.api.nvim_win_is_valid(self.win) then
        return
    end

    set_winopts(self.win, self.saved_winopts)
    self.saved_winopts = nil
end

--- Give the window back its previous buffer and options. The view stays
--- usable: the next `show()` borrows the window again.
function View:hide()
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

---@param lnum? integer
---@return integer?
function View:cursor_line(lnum)
    if lnum == nil and self:is_shown() then
        lnum = vim.api.nvim_win_get_cursor(self.win)[1]
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
--- of its file there (nil on a separator) and the section's index.
---@param lnum? integer
---@return IterDocSection? section
---@return integer? row
---@return integer? index
function View:at(lnum)
    lnum = self:cursor_line(lnum)

    if lnum == nil then
        return nil, nil, nil
    end

    return document.at(self.document, lnum)
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

    self:update_viewport(lnum)
    vim.api.nvim_win_set_cursor(self.win, { lnum, 0 })

    if align ~= nil then
        vim.api.nvim_win_call(self.win, function()
            vim.cmd(align == 'center' and 'normal! zz' or 'normal! zt')
        end)
    end
end

--- Reveal hidden context of the gap at `lnum`, the cursor line by default.
---@param lnum? integer
function View:expand(lnum)
    local cursor = self:is_shown() and vim.api.nvim_win_get_cursor(self.win)
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

    local doc = document.build(self.document.sections)

    self.document = doc
    self.rows = doc.rows
    self:render()

    if cursor ~= nil then
        vim.api.nvim_win_set_cursor(self.win, cursor)
        self:update_viewport()
    end
end

--- Move the cursor to the next (`dir` 1) or previous (-1) hunk row. At the
--- last or first hunk the cursor stays.
---@param dir 1|-1
function View:jump_hunk(dir)
    if not self:is_shown() then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1] + dir

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

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
    local first = dir == 1 and 1 or #self.marks
    local last = dir == 1 and #self.marks or 1

    for i = first, last, dir do
        local target = self.marks[i].lnum

        if (target - lnum) * dir > 0 then
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

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
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

---@type table<integer, IterDiffRailFormats>
local rail_formats = {}

---@param width integer
---@return IterDiffRailFormats
local function formats_for(width)
    local formats = rail_formats[width]

    if formats == nil then
        local number = '%' .. width .. 'd'
        local none = string.rep(' ', width)

        formats = {
            blank = string.rep(' ', 2 * width + 4),
            context = '%%#IterDiffNr#' .. number .. ' ' .. number .. '   ',
            del = '%%#IterDiffDeleteNr#' .. number .. ' ' .. none .. ' - ',
            add = '%%#IterDiffAddNr#' .. none .. ' ' .. number .. ' + ',
        }
        rail_formats[width] = formats
    end

    return formats
end

--- 'statuscolumn' of a diff view: old and new line numbers and the change
--- sign, blank on virtual and wrapped lines.
---@return string
function View.statuscolumn()
    local view = views[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]

    if view == nil then
        return ''
    end

    local formats = formats_for(view.width)
    local row = view.rows[vim.v.lnum]

    if row == nil or vim.v.virtnum ~= 0 then
        return formats.blank
    end

    local kind = row.kind

    if kind == 'context' then
        return string.format(formats.context, row.old, row.new)
    elseif kind == 'del' then
        return string.format(formats.del, row.old)
    elseif kind == 'add' then
        return string.format(formats.add, row.new)
    end

    return formats.blank
end

return View
