local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local model = require('iter.diff.model')
local syntax = require('iter.diff.syntax')
local words = require('iter.diff.words')

---@class IterDiffViewOptions
---@field win integer window the view borrows
---@field keys? table<string, string[]> resolved `keys.diff`
---@field expand_step? integer
---@field syntax_max_lines? integer
---@field word_diff? boolean

---@class IterDiffView
---@field buf integer
---@field win integer
---@field files IterFileDiff[] one in file mode
---@field rows IterDiffRow[] concatenated
---@field file_ranges { first: integer, last: integer }[]
---@field saved_winopts? table<string, any> restored when the view leaves a user window
---@field width integer digits of the widest line number
---@field keys table<string, string[]>
---@field expand_step integer
---@field syntax_max_lines integer versions longer than this get no syntax
---@field word_diff boolean
---@field generation integer bumped by every render
---@field decorated integer last generation whose syntax is applied
---@field prev_buf? integer buffer the window showed before the view
local View = {}
View.__index = View

local NS = vim.api.nvim_create_namespace('iter.diff')
local NS_SYNTAX = vim.api.nvim_create_namespace('iter.diff.syntax')
local NS_WORDS = vim.api.nvim_create_namespace('iter.diff.words')

-- Del and add rows draw below syntax, word emphasis above it, so an
-- emphasis background also shows over a capture that sets one.
local ROW_PRIORITY = vim.hl.priorities.treesitter - 50
local WORD_PRIORITY = vim.hl.priorities.treesitter + 50

local WORD_HL = { add = 'IterDiffAddText', del = 'IterDiffDeleteText' }

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
    vim.validate('opts.expand_step', opts.expand_step, 'number', true)
    vim.validate('opts.syntax_max_lines', opts.syntax_max_lines, 'number', true)
    vim.validate('opts.word_diff', opts.word_diff, 'boolean', true)

    local config = require('iter').config

    highlight.setup()

    local self = setmetatable({
        buf = vim.api.nvim_create_buf(false, true),
        win = opts.win,
        files = {},
        rows = {},
        file_ranges = {},
        width = 1,
        keys = opts.keys or config.keys.diff,
        expand_step = opts.expand_step or config.options.diff.expand_step,
        syntax_max_lines = opts.syntax_max_lines
            or config.options.diff.syntax_max_lines,
        word_diff = opts.word_diff,
        generation = 0,
        decorated = 0,
    }, View)

    if self.word_diff == nil then
        self.word_diff = config.options.diff.word_diff
    end

    vim.bo[self.buf].bufhidden = 'wipe'
    vim.bo[self.buf].modifiable = false
    views[self.buf] = self

    vim.api.nvim_create_autocmd('BufWinLeave', {
        buffer = self.buf,
        callback = function()
            self:restore_winopts()
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        buffer = self.buf,
        callback = function(args)
            views[args.buf] = nil
        end,
    })

    keymap.attach(self.buf, 'diff', self.keys, {
        expand = function()
            self:expand()
        end,
    })

    return self
end

---@param rows IterDiffRow[]
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

---@param row IterDiffRow
---@param file IterFileDiff
---@param lnum integer
---@param expand_lhs? string
function View:decorate(row, file, lnum, expand_lhs)
    local mark = { line_hl_group = ROW_HL[row.kind] }

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
    elseif row.kind == 'header' then
        local stat = file.binary and 'binary'
            or string.format('+%d −%d', file.stat.add, file.stat.del)
        mark.virt_text = { { stat .. ' ', 'IterDiffHunk' } }
        mark.virt_text_pos = 'right_align'

        vim.api.nvim_buf_set_extmark(self.buf, NS, lnum - 1, 0, {
            virt_text = { { file.code .. ' ', 'IterDiffHeader' } },
            virt_text_pos = 'inline',
        })
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

        mark.virt_text = chunks
        mark.virt_text_pos = 'overlay'
    end

    vim.api.nvim_buf_set_extmark(self.buf, NS, lnum - 1, 0, mark)
end

function View:decorate_words()
    for lnum, row in ipairs(self.rows) do
        for _, range in ipairs(row.words or {}) do
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
    end
end

---@class IterDiffSyntaxJob
---@field lines string[] version the rows come from
---@field lang string
---@field lnums integer[] version lines to highlight
---@field targets integer[] buffer line of each entry in `lnums`

--- One job per version: del rows read the old version, context and add
--- rows the new one. A version without a parser, above the size cap or
--- missing (hunk-only rows) gets none.
---@param file IterFileDiff
---@return IterDiffSyntaxJob[]
function View:syntax_jobs(file)
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

            for lnum, row in ipairs(self.rows) do
                local line = index == 1 and row.kind == 'del' and row.old
                    or index == 2
                        and (row.kind == 'context' or row.kind == 'add')
                        and row.new

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

--- Request the syntax of the shown rows and apply it when it arrives,
--- unless a later render came first.
function View:decorate_syntax()
    self.generation = self.generation + 1

    local generation = self.generation
    local file = self.files[1]
    local jobs = file ~= nil and self:syntax_jobs(file) or {}
    local pending = #jobs

    if pending == 0 then
        self.decorated = generation
        return
    end

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

            pending = pending - 1

            if pending == 0 then
                self.decorated = generation
            end
        end)
    end
end

--- Write the rows into the buffer with their highlights.
function View:render()
    local lines = vim.tbl_map(function(row)
        return row.text
    end, self.rows)

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false

    self.width = number_width(self.rows)
    self.file_ranges = { { first = 1, last = #self.rows } }

    local expand_lhs = (self.keys.expand or {})[1]

    for _, ns in ipairs({ NS, NS_SYNTAX, NS_WORDS }) do
        vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    end

    for lnum, row in ipairs(self.rows) do
        self:decorate(row, self.files[1], lnum, expand_lhs)
    end

    if self.word_diff then
        words.annotate(self.rows)
        self:decorate_words()
    end

    self:decorate_syntax()

    if self:is_shown() then
        -- Setting the option again lets the rail shrink to a new width.
        set_winopts(self.win, { statuscolumn = WINOPTS.statuscolumn })
    end
end

---@return boolean
function View:is_shown()
    return vim.api.nvim_win_is_valid(self.win)
        and vim.api.nvim_win_get_buf(self.win) == self.buf
end

--- Show `file` in the borrowed window. The window's own options are saved
--- the first time and come back as soon as the view leaves it.
---@param file IterFileDiff
function View:show(file)
    self.files = { file }
    self.rows = file.rows
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
    vim.bo[self.buf].bufhidden = 'hide'
    vim.api.nvim_win_set_buf(self.win, target)
    vim.bo[self.buf].bufhidden = 'wipe'
end

--- Give the window back its previous buffer and options. The view's buffer
--- is wiped with it.
function View:close()
    self:hide()

    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end
end

--- The row at `lnum`, the cursor line by default.
---@param lnum? integer
---@return IterDiffRow?
function View:row(lnum)
    if lnum == nil and self:is_shown() then
        lnum = vim.api.nvim_win_get_cursor(self.win)[1]
    end

    return self.rows[lnum]
end

--- Reveal hidden context of the gap at `lnum`, the cursor line by default.
---@param lnum? integer
function View:expand(lnum)
    local cursor = self:is_shown() and vim.api.nvim_win_get_cursor(self.win)
        or nil

    if lnum == nil and cursor ~= nil then
        lnum = cursor[1]
    end

    local file = self.files[1]

    if lnum == nil or file == nil then
        return
    end

    if model.expand(file, lnum, self.expand_step) == 0 then
        return
    end

    self.rows = file.rows
    self:render()

    if cursor ~= nil then
        vim.api.nvim_win_set_cursor(self.win, cursor)
    end
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
