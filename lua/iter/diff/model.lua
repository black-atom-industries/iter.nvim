local parser = require('iter.diff.parser')

---@alias IterSide 'unstaged'|'staged'|'base'

---@class IterDiffChange
---@field path string
---@field orig_path? string
---@field side IterSide
---@field base? string the base commit or tree a `base` change starts from
---@field code string porcelain letter for this side: M A D R C U ?

---@class IterDiffGap
---@field old integer first hidden old line
---@field new integer first hidden new line
---@field count integer

---@class IterDiffRow
---@field kind 'header'|'hunk'|'context'|'del'|'add'|'gap'
---@field text string plain code, no +/- prefix
---@field old? integer
---@field new? integer
---@field hunk? integer index into IterFileDiff.hunks
---@field pair? integer row of the paired del/add
---@field words? integer[][] byte ranges { start, end }
---@field gap? IterDiffGap

---@class IterFileDiff
---@field path string
---@field orig_path? string
---@field side IterSide
---@field base? string
---@field code string
---@field raw string[] git diff text, source for patches
---@field hunks IterDiffHunk[]
---@field rows IterDiffRow[]
---@field old_lines? string[] unstaged: index; staged: HEAD; base: the base
---@field new_lines? string[] unstaged and base: worktree; staged: index
---@field binary boolean
---@field stat { add: integer, del: integer }
---@field mode? { old: string, new: string } file mode change

local M = {}

---@class IterDiffBodyLine
---@field kind 'context'|'del'|'add'
---@field text string
---@field old? integer
---@field new? integer

--- The body lines of `hunk`, walked by the counts in its header so that code
--- starting with `--` or `++` is never taken for a file header.
---@param raw string[]
---@param hunk IterDiffHunk
---@return IterDiffBodyLine[]
local function hunk_body(raw, hunk)
    local body = {}
    local old, new = hunk.old_start, hunk.new_start
    local old_left, new_left = hunk.old_count, hunk.new_count
    local index = hunk.raw_header_row + 1

    while index <= #raw and (old_left > 0 or new_left > 0) do
        local line = raw[index]
        local marker = line:sub(1, 1)
        local text = line:sub(2)

        if marker == '-' then
            table.insert(body, { kind = 'del', text = text, old = old })
            old, old_left = old + 1, old_left - 1
        elseif marker == '+' then
            table.insert(body, { kind = 'add', text = text, new = new })
            new, new_left = new + 1, new_left - 1
        elseif marker == ' ' or line == '' then
            table.insert(
                body,
                { kind = 'context', text = text, old = old, new = new }
            )
            old, old_left = old + 1, old_left - 1
            new, new_left = new + 1, new_left - 1
        elseif marker ~= '\\' then
            break
        end

        index = index + 1
    end

    return body
end

--- First old and new line a hunk shows. A zero count means the hunk sits
--- after its start line.
---@param hunk IterDiffHunk
---@return integer old
---@return integer new
local function hunk_first(hunk)
    return hunk.old_count > 0 and hunk.old_start or hunk.old_start + 1,
        hunk.new_count > 0 and hunk.new_start or hunk.new_start + 1
end

--- Whether the full versions agree with the diff text: every body line sits
--- at its number, and the unchanged stretches between hunks have the same
--- length on both sides.
---@param hunks IterDiffHunk[]
---@param bodies IterDiffBodyLine[][]
---@param old_lines string[]
---@param new_lines string[]
---@return boolean
local function blobs_match(hunks, bodies, old_lines, new_lines)
    local next_old, next_new = 1, 1

    for index, hunk in ipairs(hunks) do
        local first_old, first_new = hunk_first(hunk)

        if first_old - next_old ~= first_new - next_new then
            return false
        end

        for _, line in ipairs(bodies[index]) do
            if line.old ~= nil and old_lines[line.old] ~= line.text then
                return false
            end

            if line.new ~= nil and new_lines[line.new] ~= line.text then
                return false
            end
        end

        next_old = first_old + hunk.old_count
        next_new = first_new + hunk.new_count
    end

    return #old_lines - next_old == #new_lines - next_new
end

---@param rows IterDiffRow[]
---@param old integer
---@param new integer
---@param count integer
local function push_gap(rows, old, new, count)
    if count > 0 then
        table.insert(rows, {
            kind = 'gap',
            text = '',
            gap = { old = old, new = new, count = count },
        })
    end
end

--- The mode change in the file header of `raw`, the lines before the first
--- hunk.
---@param raw string[]
---@return { old: string, new: string }?
local function mode_change(raw)
    local old, new

    for _, line in ipairs(raw) do
        if vim.startswith(line, '@@') then
            break
        end

        old = old or line:match('^old mode (%d+)$')
        new = new or line:match('^new mode (%d+)$')
    end

    return old and new and { old = old, new = new } or nil
end

---@param change IterDiffChange
---@return string
local function header_text(change)
    if change.orig_path ~= nil and change.orig_path ~= change.path then
        return change.orig_path .. ' → ' .. change.path
    end

    return change.path
end

--- Rows for one file. Gaps of hidden context sit before, between and after
--- the hunks, and only exist when both full versions match the diff text;
--- otherwise the file keeps hunk rows only and no versions.
---@param change IterDiffChange
---@param source IterFileSource
---@return IterFileDiff
function M.build(change, source)
    ---@type IterFileDiff
    local file = {
        path = change.path,
        orig_path = change.orig_path,
        side = change.side,
        base = change.base,
        code = change.code,
        raw = source.raw,
        hunks = {},
        rows = { { kind = 'header', text = header_text(change) } },
        binary = source.binary,
        stat = { add = 0, del = 0 },
        mode = mode_change(source.raw),
    }

    if source.binary then
        return file
    end

    file.hunks = parser.parse_hunks(source.raw)

    local bodies = vim.tbl_map(function(hunk)
        return hunk_body(source.raw, hunk)
    end, file.hunks)

    local old_lines, new_lines = source.old_lines, source.new_lines
    local with_gaps = old_lines ~= nil
        and new_lines ~= nil
        and blobs_match(file.hunks, bodies, old_lines, new_lines)

    if with_gaps then
        file.old_lines, file.new_lines = old_lines, new_lines
    end

    local next_old, next_new = 1, 1

    for index, hunk in ipairs(file.hunks) do
        local first_old, first_new = hunk_first(hunk)

        if with_gaps then
            push_gap(file.rows, next_old, next_new, first_new - next_new)
        end

        table.insert(file.rows, {
            kind = 'hunk',
            text = source.raw[hunk.raw_header_row],
            hunk = index,
        })

        for _, line in ipairs(bodies[index]) do
            table.insert(file.rows, {
                kind = line.kind,
                text = line.text,
                old = line.old,
                new = line.new,
                hunk = index,
            })

            if line.kind == 'add' then
                file.stat.add = file.stat.add + 1
            elseif line.kind == 'del' then
                file.stat.del = file.stat.del + 1
            end
        end

        next_old = first_old + hunk.old_count
        next_new = first_new + hunk.new_count
    end

    if with_gaps then
        push_gap(file.rows, next_old, next_new, #new_lines - next_new + 1)
    end

    return file
end

--- Reveal hidden context of the gap at `index` in `file.rows`: `step` lines
--- next to the code already shown (the bottom of a gap above the first hunk,
--- the top of any other), or all of them when no more than `step` remain.
---@param file IterFileDiff
---@param index integer
---@param step integer
---@return integer revealed lines, 0 when the row is not a gap
function M.expand(file, index, step)
    local row = file.rows[index]

    if row == nil or row.kind ~= 'gap' or file.new_lines == nil then
        return 0
    end

    local gap = row.gap
    local count = gap.count <= step and gap.count or step
    local from_bottom = file.rows[index + 1] ~= nil
        and file.rows[index - 1] ~= nil
        and file.rows[index - 1].kind == 'header'
    local offset = from_bottom and gap.count - count or 0

    local revealed = {}

    for i = 0, count - 1 do
        local new = gap.new + offset + i
        table.insert(revealed, {
            kind = 'context',
            text = file.new_lines[new],
            old = gap.old + offset + i,
            new = new,
        })
    end

    if count == gap.count then
        table.remove(file.rows, index)
    elseif from_bottom then
        gap.count = gap.count - count
        index = index + 1
    else
        gap.old, gap.new = gap.old + count, gap.new + count
        gap.count = gap.count - count
    end

    for i, revealed_row in ipairs(revealed) do
        table.insert(file.rows, index + i - 1, revealed_row)
    end

    return count
end

--- The new line number that old line `old_line` of `file` lands on. A deleted
--- line maps to the nearest line of its hunk that survives, the next one
--- first.
---@param file IterFileDiff
---@param old_line integer
---@return integer
function M.old_line_to_new_line(file, old_line)
    local delta = 0

    for index, hunk in ipairs(file.hunks) do
        local first_old = hunk_first(hunk)

        if old_line < first_old then
            return old_line + delta
        end

        if old_line < first_old + hunk.old_count then
            local rows = vim.tbl_filter(function(row)
                return row.hunk == index and row.kind ~= 'hunk'
            end, file.rows)

            for i, row in ipairs(rows) do
                if row.old == old_line then
                    for j = i, #rows do
                        if rows[j].new ~= nil then
                            return rows[j].new
                        end
                    end

                    for j = i - 1, 1, -1 do
                        if rows[j].new ~= nil then
                            return rows[j].new
                        end
                    end
                end
            end

            return hunk.new_start
        end

        delta = delta + hunk.new_count - hunk.old_count
    end

    return old_line + delta
end

-- Change groups with more del and add lines than this pair their lines one
-- by one instead of by similarity.
local MAX_MATCHED = 60

---@class IterRowPair
---@field del integer row index of the deleted line
---@field add integer row index of the added line
---@field similar boolean paired by similarity, not only by position

--- `lines` as one text for `vim.text.diff`, each line ended.
---@param lines string[]
---@return string
function M.as_text(lines)
    return #lines > 0 and table.concat(lines, '\n') .. '\n' or ''
end

--- Pairs of the del rows `dels` and the add rows `adds` of one change
--- group, in order.
---@param rows IterDiffRow[]
---@param dels integer[]
---@param adds integer[]
---@return IterRowPair[]
local function pair_group(rows, dels, adds)
    local result = {}

    if #dels + #adds > MAX_MATCHED then
        for i = 1, math.min(#dels, #adds) do
            table.insert(
                result,
                { del = dels[i], add = adds[i], similar = false }
            )
        end

        return result
    end

    local function texts(indexes)
        return vim.tbl_map(function(index)
            return rows[index].text
        end, indexes)
    end

    local hunks =
        vim.text.diff(M.as_text(texts(dels)), M.as_text(texts(adds)), {
            result_type = 'indices',
            linematch = MAX_MATCHED,
        }) --[[@as integer[][] ]]

    for _, hunk in ipairs(hunks) do
        for offset = 0, math.min(hunk[2], hunk[4]) - 1 do
            table.insert(result, {
                del = dels[hunk[1] + offset],
                add = adds[hunk[3] + offset],
                similar = true,
            })
        end
    end

    return result
end

--- The del and add rows of `rows` that face each other. A change group is
--- a run of del rows and the add rows right after it; its lines pair by
--- similarity (linematch), or one by one in a group of more than 60 lines.
--- Pairs come in row order.
---@param rows IterDiffRow[]
---@return IterRowPair[]
function M.pairs(rows)
    local result = {}
    local index = 1

    while index <= #rows do
        local dels, adds = {}, {}

        while rows[index] ~= nil and rows[index].kind == 'del' do
            table.insert(dels, index)
            index = index + 1
        end

        while rows[index] ~= nil and rows[index].kind == 'add' do
            table.insert(adds, index)
            index = index + 1
        end

        if #dels > 0 and #adds > 0 then
            vim.list_extend(result, pair_group(rows, dels, adds))
        elseif #dels == 0 and #adds == 0 then
            index = index + 1
        end
    end

    return result
end

--- Line of the new version of `file` that row `lnum` stands for: its new
--- number, for a deleted line the line that took its place, for a gap its
--- first hidden line, for a hunk row its first row, for the header line 1.
---@param file IterFileDiff
---@param lnum integer
---@return integer
function M.new_line(file, lnum)
    local row = file.rows[lnum]

    if row == nil or row.kind == 'header' then
        return 1
    elseif row.new ~= nil then
        return row.new
    elseif row.kind == 'del' then
        return M.old_line_to_new_line(file, row.old)
    elseif row.kind == 'gap' then
        return row.gap.new
    end

    return M.new_line(file, lnum + 1)
end

return M
