--- Render lines for iter's windows: the status drawer's titled columns, side
--- by side above the breakpoint and stacked below it, and the cells, hints,
--- commit rows and summaries the drawer, the review and the commits tab draw.
--- Pure: it builds render lines and touches no window or buffer.

local changes = require('iter.changes')
local render = require('iter.ui.render')

---@alias IterLayoutMode 'columns'|'stacked'

---@class IterLayoutColumn one list of the drawer
---@field id string key of the column's items in a row
---@field title string
---@field items any[]
---@field cell fun(line: IterRenderLine, item: any, first: integer, width: integer): string text of one item's cell, `width` cells wide, highlights added at byte column `first`

---@class IterLayoutCell byte columns of one cell on its line
---@field first integer
---@field last integer

---@class IterLayout
---@field lines IterRenderLine[]
---@field rows table<string, any>[] per line, the item of each column id on it
---@field cells table<string, IterLayoutCell>[] per line, the cell of each item

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

    if item.side == 'base' or item.side == 'commit' then
        return 'IterDiffHeaderRule'
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
    local title = string.format(' %s (%d)', column.title, #column.items)
    local text = fit(title, width)

    highlight_in(line, 'IterDrawerTitle', first, first + #text, 0, #title)

    return text
end

--- Columns side by side at `width` and wider, stacked below it.
---@param width integer
---@param breakpoint integer
---@return IterLayoutMode
function M.mode(width, breakpoint)
    return width >= breakpoint and 'columns' or 'stacked'
end

--- The display width of each of `count` columns side by side in `width`,
--- separators left out: equal shares, rounded down, the last column taking
--- the rest.
---@param width integer
---@param count integer
---@return integer[]
function M.widths(width, count)
    local free = width - (count - 1) * vim.fn.strdisplaywidth(M.SEPARATOR)
    local share = math.floor(free / count)
    local widths = {}

    for i = 1, count - 1 do
        widths[i] = share
    end

    widths[count] = free - share * (count - 1)

    return widths
end

---@class IterLayoutEntry one line of a column: a title, an item, or blank without `column`
---@field column? IterLayoutColumn
---@field item? any

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
--- `first` of `line`, its item into `row` and `cells`.
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

    row[column.id] = item
    cells[column.id] = { first = first, last = first + #text }

    return text
end

--- The columns side by side in `widths`, separated by `SEPARATOR`.
---@param slots IterLayoutColumn[]
---@param widths integer[]
---@return IterLayout
local function lay(slots, widths)
    local result = { lines = {}, rows = {}, cells = {} }
    local lists = {}
    local height = 0

    for i, slot in ipairs(slots) do
        lists[i] = entries({ slot })
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

            if i < #slots then
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

--- The columns side by side, separated by `SEPARATOR`, each with its title
--- on the first line and one item per line below.
---@param slots IterLayoutColumn[]
---@param width integer
---@return IterLayout
function M.columns(slots, width)
    return lay(slots, M.widths(width, #slots))
end

--- Every column one below the other, each the full `width`: a title line,
--- its items, and a blank line before the next title.
---@param slots IterLayoutColumn[]
---@param width integer
---@return IterLayout
function M.stacked(slots, width)
    local result = { lines = {}, rows = {}, cells = {} }

    for _, entry in ipairs(entries(slots)) do
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
--- left to fit, a rename or copy as `old → new`.
---@param line IterRenderLine
---@param item IterChange
---@param first integer byte column the cell starts at
---@param width integer
---@return string
function M.file_cell(line, item, first, width)
    local indent = ' '
    local prefix = indent .. item.code .. ' '
    local path, arrow = path_text(item, width - vim.fn.strdisplaywidth(prefix))
    local text = prefix .. path

    render.add_highlight(line, code_group(item), first + #indent)

    if arrow ~= nil then
        local start = first + #prefix + arrow

        render.add_highlight(line, 'IterDrawerHint', start, start + #ARROW)
    end

    return pad(text, width)
end

---@class IterLayoutAnnotation an annotation row
---@field annotation IterAnnotation
---@field outdated boolean
---@field label string location of the annotation

-- Fewest cells of the reviewed progress bar.
M.PROGRESS_MIN_CELLS = 8

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

--- A commit as a row of a list in the left window: the short sha and the
--- subject, cut with `…` to fit `width` cells.
---@param commit { sha: string, subject: string }
---@param width integer
---@return [string, string?][]
function M.commit_short(commit, width)
    local room = width - vim.fn.strdisplaywidth(commit.sha) - 1
    local subject = room > 0 and fit(commit.subject, room):gsub('%s+$', '')
        or ''

    return { { commit.sha, 'IterCommitSha' }, { ' ' .. subject } }
end

--- The lines a file of a commit changes, for its tree row: `+a` without
--- deletions, `−d` without additions, `±n` for the sum of both, `bin` for
--- a binary file.
---@param stat GitStat
---@return [string, string]
function M.line_count(stat)
    vim.validate('stat', stat, 'table')

    if stat.added == nil then
        return { 'bin', 'IterDrawerHint' }
    elseif stat.added > 0 and stat.deleted > 0 then
        return { '±' .. (stat.added + stat.deleted), 'IterDrawerHint' }
    elseif stat.deleted > 0 then
        return { '−' .. stat.deleted, 'IterUnstage' }
    end

    return { '+' .. stat.added, 'IterStage' }
end

--- A commit's short sha, date and time and author, a blank line, then its
--- whole message, the subject as a title, and a blank line after it.
---@param message GitMessage
---@return IterRenderLine[]
local function message_lines(message)
    local lines = {
        render.chunks_line({
            { ' ' },
            { message.sha, 'IterCommitSha' },
            { '  ' },
            {
                os.date('%Y-%m-%d %H:%M', message.time) --[[@as string]],
                'IterCommitDate',
            },
            { '  ' },
            { message.author, 'IterCommitAuthor' },
        }),
        render.line(''),
    }

    for index, text in ipairs(message.message) do
        local line = render.line(text == '' and '' or (' ' .. text))

        if index == 1 then
            render.add_highlight(line, 'IterDrawerTitle', 0, #line.text)
        end

        table.insert(lines, line)
    end

    table.insert(lines, render.line(''))

    return lines
end

--- A row per file of `stats` with the lines it adds and deletes, the
--- counts aligned, and the totals.
---@param stats GitStat[]
---@return IterRenderLine[] rows
---@return integer added
---@return integer deleted
local function stat_rows(stats)
    local added, deleted = 0, 0
    local counts = {}
    local count_width = 0
    local rows = {}

    for index, stat in ipairs(stats) do
        local count = stat.added == nil and { 'bin', '' }
            or { '+' .. stat.added, '−' .. stat.deleted }

        added = added + (stat.added or 0)
        deleted = deleted + (stat.deleted or 0)
        counts[index] = count
        count_width = math.max(
            count_width,
            vim.fn.strdisplaywidth(count[1] .. ' ' .. count[2])
        )
    end

    for index, stat in ipairs(stats) do
        local count = counts[index]
        local gap = count_width
            - vim.fn.strdisplaywidth(count[1] .. ' ' .. count[2])
        local path = stat.orig_path ~= nil
                and (stat.orig_path .. ARROW .. stat.path)
            or stat.path

        table.insert(
            rows,
            render.chunks_line({
                { ' ' .. string.rep(' ', gap) },
                { count[1], stat.added and 'IterStage' or 'IterDrawerHint' },
                { ' ' },
                { count[2], 'IterUnstage' },
                { '  ' .. path },
            })
        )
    end

    return rows, added, deleted
end

--- The summary of commits the commits tab shows beside its list: per commit,
--- newest first, its short sha, date and time and author, then its whole
--- message under it; after them a line with the number of files and the
--- lines added and deleted, then a row per file with its counts.
---@param messages GitMessage[]
---@param stats GitStat[]
---@return IterRenderLine[]
function M.commit_summary(messages, stats)
    local lines = {}

    for _, message in ipairs(messages) do
        vim.list_extend(lines, message_lines(message))
    end

    local rows, added, deleted = stat_rows(stats)

    table.insert(
        lines,
        render.chunks_line({
            {
                string.format(
                    ' %d %s',
                    #stats,
                    #stats == 1 and 'file' or 'files'
                ),
                'IterDrawerHint',
            },
            { '  ' },
            { '+' .. added, 'IterStage' },
            { ' ' },
            { '−' .. deleted, 'IterUnstage' },
        })
    )

    return vim.list_extend(lines, rows)
end

---@class IterBaseSummary what a base of the review brings in
---@field kind 'branch'|'commit'|'working'
---@field label string the branch, the commit's short sha, or `Working changes`
---@field sha? string the branch's merge base with HEAD
---@field head? string HEAD's branch, nil when detached
---@field commit? GitMessage the picked commit
---@field commits GitMessage[] the commits the review covers, newest first
---@field more integer the commits past `commits`
---@field working integer the paths with working changes, untracked ones included
---@field untracked integer
---@field stats GitStat[] the tracked files from the base to the worktree

---@param count integer
---@param noun string
---@return string
local function counted(count, noun)
    return string.format('%d %s%s', count, noun, count == 1 and '' or 's')
end

---@param text string
---@return IterRenderLine
local function hint_line(text)
    return render.chunks_line({ { ' ' .. text, 'IterDrawerHint' } })
end

--- What the review brings in against a base, for the window beside the base
--- list, `width` cells wide: the base and the count of commits and files at
--- the right edge, then for a branch the commits since HEAD left it, for a
--- commit its message and the commits from it on, then the working
--- changes, and the lines each tracked file adds and deletes. A branch
--- without working changes ends saying that a pull request shows the same.
---@param summary IterBaseSummary
---@param width integer
---@return IterRenderLine[]
function M.base_summary(summary, width)
    local title = summary.label
    local files = #summary.stats + summary.untracked
    local count = counted(files, 'file')

    if summary.kind == 'branch' then
        title = string.format(
            'since %s (%s)',
            summary.label,
            (summary.sha or ''):sub(1, 7)
        )
    elseif summary.kind == 'commit' then
        title = 'from ' .. summary.label
    else
        count = counted(summary.working, 'file')
    end

    if summary.kind ~= 'working' then
        count = counted(#summary.commits + summary.more, 'commit')
            .. ' · '
            .. count
    end

    local gap = math.max(
        2,
        width
            - vim.fn.strdisplaywidth(title)
            - vim.fn.strdisplaywidth(count)
            - 1
    )
    local lines = {
        render.chunks_line({
            { ' ' .. title, 'IterDrawerTitle' },
            { string.rep(' ', gap) },
            { count, 'IterDrawerHint' },
        }),
    }

    if summary.kind == 'branch' then
        table.insert(
            lines,
            hint_line(
                string.format(
                    'Committed %ssince it left %s',
                    summary.head and ('on ' .. summary.head .. ' ') or '',
                    summary.label
                )
            )
        )
    end

    table.insert(lines, render.line(''))

    if summary.kind == 'commit' and summary.commit ~= nil then
        vim.list_extend(lines, message_lines(summary.commit))
        table.insert(
            lines,
            hint_line('The review includes this commit and every one after it:')
        )
    end

    if summary.kind ~= 'working' then
        for _, message in ipairs(summary.commits) do
            local chunks = M.commit_short({
                sha = message.sha,
                subject = message.message[1] or '',
            }, width - 1)

            table.insert(chunks, 1, { ' ' })
            table.insert(lines, render.chunks_line(chunks))
        end

        if summary.more > 0 then
            table.insert(lines, hint_line('… ' .. summary.more .. ' more'))
        end

        if summary.working > 0 then
            table.insert(
                lines,
                hint_line(
                    '+ working changes in ' .. counted(summary.working, 'file')
                )
            )
        end

        table.insert(lines, render.line(''))
    end

    vim.list_extend(lines, (stat_rows(summary.stats)))

    if summary.untracked > 0 then
        table.insert(
            lines,
            hint_line('+ ' .. summary.untracked .. ' untracked')
        )
    end

    if summary.kind == 'branch' and summary.working == 0 then
        table.insert(lines, render.line(''))
        table.insert(
            lines,
            hint_line('What a pull request into ' .. summary.label .. ' shows.')
        )
    end

    return lines
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

--- Append `hints`, a chunk list per line, one cell in, so they end on line
--- `height` of the page; past it, a blank line keeps them apart from
--- `lines`.
---@param lines IterRenderLine[]
---@param hints [string, string?][][]
---@param height integer
function M.bottom_hints(lines, hints, height)
    local gap = height - #lines - #hints

    for _ = 1, gap < 0 and 1 or gap do
        table.insert(lines, render.line(''))
    end

    for _, chunks in ipairs(hints) do
        table.insert(
            lines,
            render.chunks_line(vim.list_extend({ { ' ' } }, chunks))
        )
    end
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
