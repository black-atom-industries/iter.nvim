--- A diff document: the file diffs a view shows, as sections in order, and
--- the lines they take in a buffer. Each line maps to a section and a model
--- row of its file, so callers never count offsets themselves.
---
--- The unified layout gives every model row one line. The split layout
--- shows the old version left and the new one right on lines of their own:
--- a deleted line and the added line it pairs with (`model.pairs`) share a
--- line, a deleted or added line without a pair faces a filler row, and
--- every other row shows on both sides. Both put one blank line between two
--- files.

local model = require('iter.diff.model')

local M = {}

---@alias IterDocLayout 'unified'|'split'

---@class IterDocEntry
---@field file IterFileDiff
---@field new_follows? boolean a staged file's index is its worktree version

---@class IterDocSection: IterDocEntry
---@field key string `side \0 path` of the file
---@field first integer line of the file's header row
---@field last integer line of the file's last row
---@field lnums table<integer, integer> line of each model row

---@class IterDocLine
---@field section integer
---@field row? integer model row of the section's file, nil on a separator; in the split layout the new side's, else the old side's
---@field old? integer split layout: model row on the old side, nil on a filler
---@field new? integer split layout: model row on the new side, nil on a filler

---@class IterDocSeparator
---@field kind 'blank'|'filler'
---@field text string

---@alias IterDocRow IterDiffRow|IterDocSeparator

---@class IterDocument
---@field layout IterDocLayout
---@field sections IterDocSection[]
---@field lines IterDocLine[] one per buffer line
---@field rows IterDocRow[] one per buffer line; the new side in the split layout
---@field old_rows? IterDocRow[] split layout: the old side, one per buffer line

--- The key of a file diff or a change: its side and path.
---@param file { side: IterSide, path: string }
---@return string
function M.key(file)
    return file.side .. '\0' .. file.path
end

--- The lines of `rows` in the split layout: the model row on each side,
--- nil where that side shows a filler row.
---@param rows IterDiffRow[]
---@return { old?: integer, new?: integer }[]
function M.split_lines(rows)
    local partner = {}

    for _, pair in ipairs(model.pairs(rows)) do
        partner[pair.del], partner[pair.add] = pair.add, pair.del
    end

    local lines = {}
    local index = 1

    while index <= #rows do
        local kind = rows[index].kind

        if kind ~= 'del' and kind ~= 'add' then
            table.insert(lines, { old = index, new = index })
            index = index + 1
        else
            -- One change group: its del rows, then its add rows.
            local dels, adds = {}, {}

            while rows[index] ~= nil and rows[index].kind == 'del' do
                table.insert(dels, index)
                index = index + 1
            end

            while rows[index] ~= nil and rows[index].kind == 'add' do
                table.insert(adds, index)
                index = index + 1
            end

            local d, a = 1, 1

            while d <= #dels or a <= #adds do
                local del, add = dels[d], adds[a]

                if del ~= nil and partner[del] == add then
                    table.insert(lines, { old = del, new = add })
                    d, a = d + 1, a + 1
                elseif del ~= nil and partner[del] == nil then
                    table.insert(lines, { old = del })
                    d = d + 1
                else
                    table.insert(lines, { new = add })
                    a = a + 1
                end
            end
        end
    end

    return lines
end

local FILLER = { kind = 'filler', text = '' }

--- The document of `entries` in `layout`, unified by default.
---@param entries IterDocEntry[]
---@param layout? IterDocLayout
---@return IterDocument
function M.build(entries, layout)
    local split = layout == 'split'
    ---@type IterDocument
    local doc = {
        layout = split and 'split' or 'unified',
        sections = {},
        lines = {},
        rows = {},
        old_rows = split and {} or nil,
    }

    for index, entry in ipairs(entries) do
        if index > 1 then
            local blank = { kind = 'blank', text = '' }

            table.insert(doc.rows, blank)
            table.insert(doc.lines, { section = index - 1 })

            if split then
                table.insert(doc.old_rows, blank)
            end
        end

        local rows = entry.file.rows
        local first = #doc.rows + 1
        local lnums = {}

        if split then
            for _, line in ipairs(M.split_lines(rows)) do
                local lnum = #doc.rows + 1

                table.insert(doc.old_rows, rows[line.old] or FILLER)
                table.insert(doc.rows, rows[line.new] or FILLER)
                table.insert(doc.lines, {
                    section = index,
                    row = line.new or line.old,
                    old = line.old,
                    new = line.new,
                })

                for _, row in pairs(line) do
                    lnums[row] = lnum
                end
            end
        else
            for row, model_row in ipairs(rows) do
                table.insert(doc.rows, model_row)
                table.insert(doc.lines, { section = index, row = row })
                lnums[row] = #doc.rows
            end
        end

        table.insert(doc.sections, {
            file = entry.file,
            new_follows = entry.new_follows,
            key = M.key(entry.file),
            first = first,
            last = #doc.rows,
            lnums = lnums,
        })
    end

    return doc
end

--- The section and model row at `lnum`. A separator belongs to the file
--- above it and has no row. In the split layout `side` picks the row of
--- that side, the other side's on a filler; without `side` the new side's
--- comes first.
---@param doc IterDocument
---@param lnum integer
---@param side? 'old'|'new'
---@return IterDocSection? section
---@return integer? row
---@return integer? index of the section
function M.at(doc, lnum, side)
    local line = doc.lines[lnum]

    if line == nil then
        return nil, nil, nil
    end

    local row = side ~= nil and line[side] or line.row

    return doc.sections[line.section], row, line.section
end

--- The line of model row `row` of section `index`.
---@param doc IterDocument
---@param index integer
---@param row integer
---@return integer?
function M.line_of(doc, index, row)
    local section = doc.sections[index]

    return section and section.lnums[row]
end

--- The model rows on lines `first` to `last`, which lie in one section, in
--- row order: in the split layout those of `side`, of both sides without.
---@param doc IterDocument
---@param first integer
---@param last integer
---@param side? 'old'|'new'
---@return integer[]
function M.rows_in(doc, first, last, side)
    local seen, result = {}, {}

    for lnum = first, last do
        local line = doc.lines[lnum]

        if line ~= nil then
            local rows = doc.layout ~= 'split' and { line.row }
                or side ~= nil and { line[side] }
                or { line.old, line.new }

            for _, row in pairs(rows) do
                if not seen[row] then
                    seen[row] = true
                    table.insert(result, row)
                end
            end
        end
    end

    table.sort(result)

    return result
end

--- The index of the section with `key`.
---@param doc IterDocument
---@param key string
---@return integer?
function M.find(doc, key)
    for index, section in ipairs(doc.sections) do
        if section.key == key then
            return index
        end
    end

    return nil
end

--- Indexes of the sections that have a line between `first` and `last`.
---@param doc IterDocument
---@param first integer
---@param last integer
---@return integer[]
function M.sections_in(doc, first, last)
    local result = {}

    for index, section in ipairs(doc.sections) do
        if section.first > last then
            break
        end

        -- A separator line belongs to the section above it.
        local stop = doc.sections[index + 1] ~= nil and section.last + 1
            or section.last

        if stop >= first then
            table.insert(result, index)
        end
    end

    return result
end

return M
