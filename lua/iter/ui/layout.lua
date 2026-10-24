--- The drawer's lines from its columns and the width: titled columns side by
--- side above the breakpoint, stacked sections below it, cells cut to fit.
--- Pure: it builds render lines and touches no window or buffer.

local changes = require('iter.changes')
local render = require('iter.ui.render')

---@alias IterLayoutMode 'columns'|'stacked'

---@class IterLayoutColumn one list of the drawer
---@field id string key of the column's items in a row
---@field title string
---@field items any[]
---@field weight? number share of the width among the columns, 1 by default
---@field count? integer number in the title, `#items` by default
---@field note? string dimmed text after the title, such as `1 outdated`
---@field selectable? fun(item: any): boolean false for an item shown but never selected; every item is selectable by default
---@field cell fun(line: IterRenderLine, item: any, first: integer, width: integer): string text of one item's cell, `width` cells wide, highlights added at byte column `first`

---@class IterLayoutStack sections one below the other in one column
---@field sections IterLayoutColumn[] each with its title, a blank line between them
---@field weight? number share of the width among the columns, 1 by default

---@alias IterLayoutSlot IterLayoutColumn|IterLayoutStack one column side by side

---@class IterLayoutCell byte columns of one cell on its line
---@field first integer
---@field last integer

---@class IterLayout
---@field lines IterRenderLine[]
---@field rows table<string, any>[] per line, the item of each column id on it
---@field cells table<string, IterLayoutCell>[] per line, the cell of each item

---@class IterLayoutDecor what a file row shows besides its code and path
---@field mark? [string, string] glyph and group after the code letter
---@field count? integer shown as `[n]` at the end of the cell above 0

---@class IterLayoutProgress the reviewed progress of the review
---@field reviewed integer
---@field changed integer files changed since they were reviewed
---@field total integer

local M = {}

M.SEPARATOR = '│'

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    return text .. string.rep(' ', width - vim.fn.strdisplaywidth(text))
end

--- `text` padded to `width` cells, or cut to fit with `…` at the end.
---@param text string
---@param width integer
---@return string
local function fit(text, width)
    if vim.fn.strdisplaywidth(text) <= width then
        return pad(text, width)
    end

    if width <= 0 then
        return ''
    end

    local kept = ''

    for i = 0, vim.fn.strchars(text) - 1 do
        local next = kept .. vim.fn.strcharpart(text, i, 1)

        if vim.fn.strdisplaywidth(next) > width - 1 then
            break
        end

        kept = next
    end

    return pad(kept .. '…', width)
end

M.fit = fit

--- Highlight bytes `start` to `stop` of a cell that starts at byte column
--- `first` and ends at `last`, cut to the cell.
---@param line IterRenderLine
---@param group string
---@param first integer
---@param last integer
---@param start integer
---@param stop integer
local function highlight_in(line, group, first, last, start, stop)
    start, stop = first + start, math.min(first + stop, last)

    if start < stop then
        render.add_highlight(line, group, start, stop)
    end
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

---@param chunks [string, string][]
---@return integer
local function chunks_width(chunks)
    local width = 0

    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end

    return width
end

---@param line IterRenderLine
---@param column IterLayoutColumn
---@param first integer
---@param width integer
---@return string
local function title_text(line, column, first, width)
    local title =
        string.format(' %s (%d)', column.title, column.count or #column.items)
    local note = column.note and (' · ' .. column.note) or ''
    local cut = vim.fn.strdisplaywidth(title .. note) > width
    local text = fit(title .. note, width)
    local last = first + #text

    highlight_in(line, 'IterDrawerTitle', first, last, 0, #title)

    if note ~= '' then
        local stop = cut and #text or #title + #note

        highlight_in(line, 'IterDrawerHint', first, last, #title, stop)
    end

    return text
end

--- Whether `column` lets the selection rest on `item`.
---@param column IterLayoutColumn
---@param item any
---@return boolean
local function selectable(column, item)
    return column.selectable == nil or column.selectable(item)
end

--- Columns side by side at `width` and wider, stacked below it.
---@param width integer
---@param breakpoint integer
---@return IterLayoutMode
function M.mode(width, breakpoint)
    return width >= breakpoint and 'columns' or 'stacked'
end

--- The display width of each column side by side in `width`, separators
--- left out: shares by weight, rounded down, the last column taking the
--- rest.
---@param width integer
---@param weights number[]
---@return integer[]
function M.widths(width, weights)
    local free = width - (#weights - 1) * vim.fn.strdisplaywidth(M.SEPARATOR)
    local total = 0

    for _, weight in ipairs(weights) do
        total = total + weight
    end

    local widths, used = {}, 0

    for i, weight in ipairs(weights) do
        if i == #weights then
            widths[i] = free - used
        else
            widths[i] = math.floor(free * weight / total)
            used = used + widths[i]
        end
    end

    return widths
end

---@class IterLayoutEntry one line of a column: a title, an item, or blank without `column`
---@field column? IterLayoutColumn
---@field item? any

--- The sections of `slot`: a stack's own, else the column alone.
---@param slot IterLayoutSlot
---@return IterLayoutColumn[]
local function sections(slot)
    if slot.sections ~= nil then
        return slot.sections
    end

    ---@cast slot IterLayoutColumn
    return { slot }
end

--- The lines of `list` top to bottom: per column a title line and its
--- items, with a blank line before each title after the first.
---@param list IterLayoutColumn[]
---@return IterLayoutEntry[]
local function entries(list)
    local result = {}

    for i, column in ipairs(list) do
        if i > 1 then
            table.insert(result, {})
        end

        table.insert(result, { column = column })

        for _, item in ipairs(column.items) do
            table.insert(result, { column = column, item = item })
        end
    end

    return result
end

--- Write `entry` as a cell `width` cells wide starting at byte column
--- `first` of `line`, its item into `row` and `cells` when selectable.
---@param line IterRenderLine
---@param entry IterLayoutEntry?
---@param first integer
---@param width integer
---@param row table<string, any>
---@param cells table<string, IterLayoutCell>
---@return string
local function entry_text(line, entry, first, width, row, cells)
    local column = entry and entry.column

    if column == nil then
        return string.rep(' ', width)
    end

    local item = entry.item

    if item == nil then
        return title_text(line, column, first, width)
    end

    local text = column.cell(line, item, first, width)

    if selectable(column, item) then
        row[column.id] = item
        cells[column.id] = { first = first, last = first + #text }
    end

    return text
end

--- The slots side by side in `widths`, separated by `SEPARATOR`, at least
--- `height` lines; with `trailing` a separator also ends each line.
---@param slots IterLayoutSlot[]
---@param widths integer[]
---@param height integer
---@param trailing boolean
---@return IterLayout
local function lay(slots, widths, height, trailing)
    local result = { lines = {}, rows = {}, cells = {} }
    local lists = {}

    for i, slot in ipairs(slots) do
        lists[i] = entries(sections(slot))
        height = math.max(height, #lists[i])
    end

    for index = 1, height do
        local line = render.line('')
        local row, cells, parts = {}, {}, {}
        local first = 0

        for i in ipairs(slots) do
            local text =
                entry_text(line, lists[i][index], first, widths[i], row, cells)

            table.insert(parts, text)
            first = first + #text

            if i < #slots or trailing then
                table.insert(parts, M.SEPARATOR)
                render.add_highlight(
                    line,
                    'WinSeparator',
                    first,
                    first + #M.SEPARATOR
                )
                first = first + #M.SEPARATOR
            end
        end

        line.text = table.concat(parts)
        table.insert(result.lines, line)
        table.insert(result.rows, row)
        table.insert(result.cells, cells)
    end

    return result
end

---@param slots IterLayoutSlot[]
---@return number[]
local function weights(slots)
    return vim.tbl_map(function(slot)
        return slot.weight or 1
    end, slots)
end

--- The slots side by side, separated by `SEPARATOR`: a column has its
--- title on the first line and one item per line below; a stack has its
--- sections one below the other, as `stacked` lays them out, the first
--- title on the first line.
---@param slots IterLayoutSlot[]
---@param width integer
---@return IterLayout
function M.columns(slots, width)
    return lay(slots, M.widths(width, weights(slots)), 0, false)
end

---@class IterLayoutSplit the last slot apart from the others
---@field left IterLayout the other slots, each line ending in a separator
---@field right IterLayout the last slot, as many lines as `left`
---@field col integer display column the last slot starts at

--- The slots as `columns` lays them out in `width`, the last one in a
--- layout of its own, for a window of its own beside the others.
---@param slots IterLayoutSlot[]
---@param width integer
---@return IterLayoutSplit
function M.split(slots, width)
    local widths = M.widths(width, weights(slots))
    local last = #slots
    local height = 0
    local col = (last - 1) * vim.fn.strdisplaywidth(M.SEPARATOR)

    for i, slot in ipairs(slots) do
        height = math.max(height, #entries(sections(slot)))

        if i < last then
            col = col + widths[i]
        end
    end

    return {
        left = lay(vim.list_slice(slots, 1, last - 1), widths, height, true),
        right = lay({ slots[last] }, { widths[last] }, height, false),
        col = col,
    }
end

--- Every section of the slots one below the other, each the full `width`:
--- a title line, its items, and a blank line before the next title.
---@param slots IterLayoutSlot[]
---@param width integer
---@return IterLayout
function M.stacked(slots, width)
    local result = { lines = {}, rows = {}, cells = {} }
    local list = {}

    for _, slot in ipairs(slots) do
        vim.list_extend(list, sections(slot))
    end

    for _, entry in ipairs(entries(list)) do
        local line = render.line('')
        local row, cells = {}, {}

        line.text = entry.column
                and entry_text(line, entry, 0, width, row, cells)
            or ''
        table.insert(result.lines, line)
        table.insert(result.rows, row)
        table.insert(result.cells, cells)
    end

    return result
end

--- One hint line in place of the columns, such as when nothing changed.
---@param text string
---@return IterLayout
function M.message(text)
    local line = render.line(' ' .. text)
    render.add_highlight(line, 'IterDrawerHint', 0, #line.text)

    return { lines = { line }, rows = { {} }, cells = { {} } }
end

local ARROW = ' → '

--- The path of a file row in `width` cells: a rename or copy reads
--- `old → new`. Too wide, the old path is cut from the left first; when not
--- even `…` and one cell of it fit, it goes with the arrow, and the new path
--- is cut from the left.
---@param item IterChange
---@param width integer
---@return string text
---@return integer? arrow byte column of the arrow in `text`
local function path_text(item, width)
    local old = item.orig_path

    if old == nil then
        return changes.truncate(item.path, width)
    end

    local room = width - vim.fn.strdisplaywidth(ARROW .. item.path)

    if room < 2 then
        return changes.truncate(item.path, width)
    end

    local head = changes.truncate(old, room)

    return head .. ARROW .. item.path, #head
end

--- The cell of a file row: code letter and path, the path cut from the
--- left to fit, a rename or copy as `old → new`. With `decor`, a mark slot
--- follows the code letter, blank without a mark, and a count above 0 ends
--- the cell.
---@param line IterRenderLine
---@param item IterChange
---@param first integer byte column the cell starts at
---@param width integer
---@param decor? IterLayoutDecor
---@return string
function M.file_cell(line, item, first, width, decor)
    local indent = ' '
    local prefix = indent .. item.code .. ' '
    local mark = decor and decor.mark

    if decor ~= nil then
        prefix = prefix .. (mark and mark[1] or ' ') .. ' '
    end

    local count = decor and decor.count or 0
    local suffix = count > 0 and string.format(' [%d] ', count) or ''
    local path, arrow = path_text(
        item,
        width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(suffix)
    )
    local text = prefix .. path

    render.add_highlight(line, code_group(item), first + #indent)

    if arrow ~= nil then
        local start = first + #prefix + arrow

        render.add_highlight(line, 'IterDrawerHint', start, start + #ARROW)
    end

    if mark then
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

---@class IterLayoutAnnotation an annotation row
---@field annotation IterAnnotation
---@field outdated boolean
---@field label string location, from `annotation_label`

-- Fewest cells of the reviewed progress bar.
M.PROGRESS_MIN_CELLS = 8

--- The location an annotation row shows: `review` for the whole review,
--- the file's name for a file annotation, else `name:line` or
--- `name:first–last`, with ` old` for deleted lines. `start` is the line the
--- annotation's text starts on now; without it the stored line shows.
---@param annotation IterAnnotation
---@param start? integer
---@return string
function M.annotation_label(annotation, start)
    local a = annotation.anchor

    if annotation.scope == 'review' then
        return 'review'
    end

    local name = vim.fs.basename(a.path or '')

    if annotation.scope == 'file' or a.start_line == nil then
        return name
    end

    local first = start or a.start_line
    local last = first + (a.end_line or a.start_line) - a.start_line
    local loc = first == last and tostring(first) or (first .. '–' .. last)

    return name .. ':' .. loc .. (a.side == 'old' and ' old' or '')
end

--- The cell of an annotation row: the label padded to `label_width`, then
--- the first line of the body, cut with `…` to fit. An outdated row is
--- dimmed.
---@param line IterRenderLine
---@param item IterLayoutAnnotation
---@param first integer byte column the cell starts at
---@param width integer
---@param label_width integer
---@return string
function M.annotation_cell(line, item, first, width, label_width)
    local label = fit(item.label, label_width)
    local body = vim.split(item.annotation.body, '\n', { plain = true })[1]
    local text = fit(' ' .. label .. ' ' .. body:gsub('\t', ' '), width)
    local last = first + #text

    if item.outdated then
        highlight_in(line, 'IterDiffAnnotationOutdated', first, last, 0, #text)
    else
        local shown = #(label:gsub(' +$', ''))

        highlight_in(line, 'IterDrawerKey', first, last, 1, 1 + shown)
    end

    return text
end

--- The cell of the reviewed progress: `reviewed`, a bar whose filled share is
--- the reviewed share, `<reviewed> of <total>`, and `· ↻ <changed>` when files
--- changed since they were reviewed. The bar takes the width the rest leaves,
--- down to `PROGRESS_MIN_CELLS`; below that, the word `reviewed` goes first.
---@param line IterRenderLine
---@param progress IterLayoutProgress
---@param first integer byte column the cell starts at
---@param width integer
---@return string
function M.progress_cell(line, progress, first, width)
    local word = ' reviewed '
    local counts = string.format(' %d of %d', progress.reviewed, progress.total)
    local changed = progress.changed > 0
            and string.format(' · ↻ %d', progress.changed)
        or ''

    local function room()
        return width - vim.fn.strdisplaywidth(word .. counts .. changed) - 1
    end

    -- A narrow cell keeps the numbers rather than the word.
    if room() < M.PROGRESS_MIN_CELLS then
        word = ' '
    end

    local cells = math.max(room(), M.PROGRESS_MIN_CELLS)
    local filled = 0

    if progress.total > 0 then
        filled = math.floor(progress.reviewed * cells / progress.total + 0.5)

        if progress.reviewed > 0 then
            filled = math.max(filled, 1)
        end

        if progress.reviewed < progress.total then
            filled = math.min(filled, cells - 1)
        end
    end

    local parts = {
        { word, 'IterDrawerHint' },
        { string.rep('▰', filled), 'IterReviewed' },
        { string.rep('▱', cells - filled), 'IterDrawerHint' },
        { counts, 'IterDrawerHint' },
        { changed, 'IterReviewedChanged' },
    }

    local text = fit(
        table.concat(vim.tbl_map(function(part)
            return part[1]
        end, parts)),
        width
    )
    local last = first + #text
    local at = 0

    for _, part in ipairs(parts) do
        highlight_in(line, part[2], first, last, at, at + #part[1])
        at = at + #part[1]
    end

    return text
end

--- The age of something `seconds` old in its largest whole unit: `now`
--- under a minute, then minutes `5m`, hours `2h`, days `3d`, weeks `5w` and
--- years `1y`. A negative age, from a clock behind the committer's, is `now`.
---@param seconds integer
---@return string
function M.age(seconds)
    local units = {
        { 365 * 86400, 'y' },
        { 7 * 86400, 'w' },
        { 86400, 'd' },
        { 3600, 'h' },
        { 60, 'm' },
    }

    for _, unit in ipairs(units) do
        if seconds >= unit[1] then
            return math.floor(seconds / unit[1]) .. unit[2]
        end
    end

    return 'now'
end

--- One row of a recent commit: with an upstream a `↑` slot, then the short
--- sha, the subject cut with `…` to fit and the age at the right edge.
--- A commit on the upstream is dimmed.
---@param commit GitCommit
---@param markers boolean whether the row has the `↑` slot
---@param age string
---@param width integer
---@return IterRenderLine
local function commit_line(commit, markers, age, width)
    local line = render.line('')
    local marker = markers and (commit.unpushed and '↑ ' or '  ') or ''
    local prefix = ' ' .. marker .. commit.sha .. '  '
    local suffix = ' ' .. age .. ' '
    local room = width
        - vim.fn.strdisplaywidth(prefix)
        - vim.fn.strdisplaywidth(suffix)
    local subject = fit(commit.subject, math.max(room, 0))
    local dim = markers and not commit.unpushed

    line.text = prefix .. subject .. suffix

    local sha_at = 1 + #marker
    local sha_group = commit.unpushed and 'IterUnpushed' or 'IterDrawerHint'

    if commit.unpushed then
        render.add_highlight(line, 'IterUnpushed', 1, 1 + #'↑')
    end

    render.add_highlight(line, sha_group, sha_at, sha_at + #commit.sha)

    if dim then
        render.add_highlight(
            line,
            'IterDrawerHint',
            #prefix,
            #prefix + #subject
        )
    end

    render.add_highlight(line, 'IterDrawerHint', #prefix + #subject, #line.text)

    return line
end

--- The Recent commits section, `width` cells wide: a title with
--- `· ↑n unpushed` and `· ↓m behind` when not 0, then a row per commit. Its
--- rows hold no items. Empty without commits.
---@param recent GitRecent?
---@param width integer
---@param now integer seconds since the epoch the ages count to
---@return IterLayout
function M.commits(recent, width, now)
    local result = { lines = {}, rows = {}, cells = {} }

    if recent == nil or #recent.commits == 0 then
        return result
    end

    local parts = { { ' Recent commits', 'IterDrawerTitle' } }

    if recent.ahead > 0 then
        table.insert(parts, { ' · ', 'IterDrawerHint' })
        table.insert(
            parts,
            { '↑' .. recent.ahead .. ' unpushed', 'IterUnpushed' }
        )
    end

    if recent.behind > 0 then
        table.insert(parts, { ' · ', 'IterDrawerHint' })
        table.insert(
            parts,
            { '↓' .. recent.behind .. ' behind', 'IterBehind' }
        )
    end

    local title = render.line('')
    local at = 0

    for _, part in ipairs(parts) do
        title.text = title.text .. part[1]
        render.add_highlight(title, part[2], at, at + #part[1])
        at = at + #part[1]
    end

    local lines = { title }

    for _, commit in ipairs(recent.commits) do
        table.insert(
            lines,
            commit_line(
                commit,
                recent.upstream ~= nil,
                M.age(now - commit.time),
                width
            )
        )
    end

    for _, line in ipairs(lines) do
        table.insert(result.lines, line)
        table.insert(result.rows, {})
        table.insert(result.cells, {})
    end

    return result
end

--- Key hints `<lhs> <label>` for `actions`, in order, those without a bound
--- key left out, as many as fit in `width`; the last one stays.
---@param bound IterKeymapEntry[] bound keys by action
---@param actions [string, string][] action and label
---@param width integer
---@return [string, string][]
function M.hints(bound, actions, width)
    local lhs = {}

    for _, entry in ipairs(bound) do
        lhs[entry.action] = entry.lhs[1]
    end

    local items = {}

    for _, action in ipairs(actions) do
        if lhs[action[1]] ~= nil then
            table.insert(items, { lhs[action[1]], action[2] })
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

return M
