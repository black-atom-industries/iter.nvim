local document = require('iter.diff.document')
local parser = require('iter.diff.parser')

local M = {}

--- `raw` as `vim.system` text mode returns it: one carriage return before
--- each line end dropped.
---@param raw string[]
---@return string[]
function M.text(raw)
    return vim.tbl_map(function(line)
        return (line:gsub('\r$', ''))
    end, raw)
end

--- The `--- a/<path>` line naming the path of a `+++ b/<path>` line.
---@param plus string
---@return string
local function minus_of(plus)
    local name = plus:sub(5)

    if vim.startswith(name, '"b/') then
        name = '"a/' .. name:sub(4)
    elseif vim.startswith(name, 'b/') then
        name = 'a/' .. name:sub(3)
    end

    return '--- ' .. name
end

--- The `+++ b/<path>` line naming the path of a `--- a/<path>` line.
---@param minus string
---@return string
local function plus_of(minus)
    local name = minus:sub(5)

    if vim.startswith(name, '"a/') then
        name = '"b/' .. name:sub(4)
    elseif vim.startswith(name, 'a/') then
        name = 'b/' .. name:sub(3)
    end

    return '+++ ' .. name
end

---@class IterPatchHeader
---@field first integer raw row of its `diff ` line
---@field lines string[]
---@field minus? string
---@field plus? string
---@field created boolean
---@field deleted boolean

--- The header of the file section holding raw row `row`: its lines up to
--- the first hunk, mode change lines left out, as `git add -p` does, so a
--- patch never carries a chmod. A renamed or copied file names its new path
--- on both sides, so applying the patch never moves the file.
---@param raw string[]
---@param row integer
---@return IterPatchHeader
local function file_header(raw, row)
    local first = row

    while first > 1 and not vim.startswith(raw[first], 'diff ') do
        first = first - 1
    end

    ---@type IterPatchHeader
    local header =
        { first = first, lines = {}, created = false, deleted = false }
    local renamed = false

    for index = first, #raw do
        local line = raw[index]

        if vim.startswith(line, '@@') then
            break
        end

        if
            vim.startswith(line, 'rename from ')
            or vim.startswith(line, 'copy from ')
        then
            renamed = true
        elseif vim.startswith(line, 'new file mode ') then
            header.created = true
        elseif vim.startswith(line, 'deleted file mode ') then
            header.deleted = true
        elseif vim.startswith(line, '--- ') then
            header.minus = line
        elseif vim.startswith(line, '+++ ') then
            header.plus = line
        end

        if
            not vim.startswith(line, 'old mode ')
            and not vim.startswith(line, 'new mode ')
        then
            table.insert(header.lines, line)
        end
    end

    if renamed and header.plus ~= nil then
        header.lines = { minus_of(header.plus), header.plus }
    end

    return header
end

--- The patch of hunk `index` of `raw`, git's diff text with `a/` and `b/`
--- prefixes: the header of its file section, then the hunk up to the next
--- one. Nil when there is no such hunk.
---@param raw string[]
---@param index integer
---@return string[]?
function M.hunk(raw, index)
    local hunk = parser.parse_hunks(raw)[index]

    if hunk == nil then
        return nil
    end

    return vim.list_extend(
        file_header(raw, hunk.raw_header_row).lines,
        vim.list_slice(raw, hunk.raw_header_row, hunk.raw_end_row)
    )
end

---@class IterLineSelection
---@field old table<integer, true> old line numbers of the selected del rows
---@field new table<integer, true> new line numbers of the selected add rows

---@class IterPatchLine
---@field sign '-'|'+'|' '
---@field text string
---@field eof? true followed by a no-newline marker

---@class IterPatchRow: IterDiffRow
---@field eof? true followed by a no-newline marker

--- The rows of `hunk` in `raw`, each with the no-newline marker after it.
---@param raw string[]
---@param hunk IterDiffHunk
---@return IterPatchRow[]
local function hunk_rows(raw, hunk)
    local rows = {}
    local old, new = hunk.old_start, hunk.new_start
    local old_left, new_left = hunk.old_count, hunk.new_count
    local index = hunk.raw_header_row + 1

    while
        index <= #raw
        and (old_left > 0 or new_left > 0 or vim.startswith(raw[index], '\\'))
    do
        local line = raw[index]
        local marker, text = line:sub(1, 1), line:sub(2)

        if marker == '-' then
            table.insert(rows, { kind = 'del', text = text, old = old })
            old, old_left = old + 1, old_left - 1
        elseif marker == '+' then
            table.insert(rows, { kind = 'add', text = text, new = new })
            new, new_left = new + 1, new_left - 1
        elseif marker == ' ' or line == '' then
            table.insert(rows, { kind = 'context', text = text })
            old, old_left = old + 1, old_left - 1
            new, new_left = new + 1, new_left - 1
        elseif marker == '\\' then
            if #rows > 0 then
                rows[#rows].eof = true
            end
        else
            break
        end

        index = index + 1
    end

    return rows
end

--- The body of `hunk` with only the selected changes, in pair order. The
--- side the patch applies to stays whole: staging turns an unselected del
--- row into context and drops an unselected add row; unstaging, which
--- applies the patch in reverse, turns an unselected add row into context
--- and drops an unselected del row. The rows of a change group go in the
--- order of the split layout, a deleted line next to the added line it
--- pairs with, so a staged or unstaged line takes its partner's place.
---@param raw string[]
---@param hunk IterDiffHunk
---@param selection IterLineSelection
---@param kind 'stage'|'unstage'
---@return IterPatchLine[]
---@return boolean picked whether a selected change is in it
local function select_body(raw, hunk, selection, kind)
    local rows = hunk_rows(raw, hunk)
    local body = {}
    local picked = false

    for _, line in ipairs(document.split_lines(rows)) do
        local indexes = line.old ~= line.new and { line.old, line.new }
            or { line.old }

        for i = 1, 2 do
            local row = rows[indexes[i]]

            if row ~= nil then
                local sign

                if row.kind == 'del' then
                    if selection.old[row.old] then
                        sign, picked = '-', true
                    elseif kind == 'stage' then
                        sign = ' '
                    end
                elseif row.kind == 'add' then
                    if selection.new[row.new] then
                        sign, picked = '+', true
                    elseif kind == 'unstage' then
                        sign = ' '
                    end
                else
                    sign = ' '
                end

                if sign ~= nil then
                    table.insert(
                        body,
                        { sign = sign, text = row.text, eof = row.eof }
                    )
                end
            end
        end
    end

    return body, picked
end

--- `body` as patch lines. A line without a newline that a kept line
--- follows on its side gains one: a context line becomes the old line
--- deleted and added again with a newline, so the old side still matches;
--- a deleted line, which only unstaging leaves before context, just drops
--- its marker, as the old side is the result there.
---@param body IterPatchLine[]
---@return string[]
local function body_lines(body)
    local lines = {}
    local marker = '\\ No newline at end of file'

    for index, line in ipairs(body) do
        local old_follows = false

        for later = index + 1, #body do
            old_follows = old_follows or body[later].sign ~= '+'
        end

        if line.eof and line.sign == '-' and old_follows then
            table.insert(lines, '-' .. line.text)
        elseif line.eof and line.sign == ' ' and index < #body then
            vim.list_extend(
                lines,
                { '-' .. line.text, marker, '+' .. line.text }
            )
        else
            table.insert(lines, line.sign .. line.text)

            if line.eof then
                table.insert(lines, marker)
            end
        end
    end

    return lines
end

---@param lines string[]
---@return integer old
---@return integer new
local function counts(lines)
    local old, new = 0, 0

    for _, line in ipairs(lines) do
        local marker = line:sub(1, 1)

        if marker ~= '+' and marker ~= '\\' then
            old = old + 1
        end

        if marker ~= '-' and marker ~= '\\' then
            new = new + 1
        end
    end

    return old, new
end

--- The start of a side in a hunk header from the first line it shows; a
--- zero count names the line before.
---@param first integer
---@param count integer
---@return integer
local function start_of(first, count)
    return count > 0 and first or first - 1
end

--- The patch of the selected del and add rows of `raw` for `kind`, every
--- hunk header recounted: staging applies it to the index, unstaging
--- applies it to the index in reverse. A created or deleted file that keeps
--- lines on the other side is patched as a modification. Nil when no
--- selected row is in `raw`.
---@param raw string[]
---@param selection IterLineSelection
---@param kind 'stage'|'unstage'
---@return string[]?
function M.lines(raw, selection, kind)
    local out = {}
    local header
    local delta = 0

    for _, hunk in ipairs(parser.parse_hunks(raw)) do
        local body, picked = select_body(raw, hunk, selection, kind)

        if picked then
            local lines = body_lines(body)
            local old_count, new_count = counts(lines)
            local section = file_header(raw, hunk.raw_header_row)

            if header == nil or header.first ~= section.first then
                header = section
                local partial = header.created and old_count > 0
                    or header.deleted and new_count > 0

                if partial and header.created and header.plus ~= nil then
                    header.lines = { minus_of(header.plus), header.plus }
                elseif partial and header.minus ~= nil then
                    header.lines = { header.minus, plus_of(header.minus) }
                end

                vim.list_extend(out, header.lines)
                delta = 0
            end

            local old_start, new_start

            if kind == 'stage' then
                local first = hunk.old_count > 0 and hunk.old_start
                    or hunk.old_start + 1
                old_start = start_of(first, old_count)
                new_start = start_of(first + delta, new_count)
            else
                local first = hunk.new_count > 0 and hunk.new_start
                    or hunk.new_start + 1
                new_start = start_of(first, new_count)
                old_start = start_of(first - delta, old_count)
            end

            delta = delta + new_count - old_count

            table.insert(
                out,
                string.format(
                    '@@ -%d,%d +%d,%d @@%s',
                    old_start,
                    old_count,
                    new_start,
                    new_count,
                    raw[hunk.raw_header_row]:match('^@@ .- @@(.*)$') or ''
                )
            )
            vim.list_extend(out, lines)
        end
    end

    return #out > 0 and out or nil
end

return M
