--- A diff document: the file diffs a view shows, as sections in order, and
--- the lines they take in a buffer. Each line maps to a section and a model
--- row of its file, so callers never count offsets themselves.
---
--- The unified layout gives every model row one line and puts one blank
--- line between two files.

local M = {}

---@class IterDocEntry
---@field file IterFileDiff
---@field new_follows? boolean a staged file's index is its worktree version

---@class IterDocSection: IterDocEntry
---@field key string `side \0 path` of the file
---@field first integer line of the file's header row
---@field last integer line of the file's last row

---@class IterDocLine
---@field section integer
---@field row? integer model row of the section's file, nil on a separator

---@class IterDocSeparator
---@field kind 'blank'
---@field text string

---@class IterDocument
---@field sections IterDocSection[]
---@field lines IterDocLine[] one per buffer line
---@field rows (IterDiffRow|IterDocSeparator)[] one per buffer line

--- The key of a file diff or a change: its side and path.
---@param file { side: IterSide, path: string }
---@return string
function M.key(file)
    return file.side .. '\0' .. file.path
end

--- The document of `entries` in the unified layout.
---@param entries IterDocEntry[]
---@return IterDocument
function M.build(entries)
    ---@type IterDocument
    local doc = { sections = {}, lines = {}, rows = {} }

    for index, entry in ipairs(entries) do
        if index > 1 then
            table.insert(doc.rows, { kind = 'blank', text = '' })
            table.insert(doc.lines, { section = index - 1 })
        end

        local rows = entry.file.rows
        local first = #doc.rows + 1

        for row, model_row in ipairs(rows) do
            table.insert(doc.rows, model_row)
            table.insert(doc.lines, { section = index, row = row })
        end

        table.insert(doc.sections, {
            file = entry.file,
            new_follows = entry.new_follows,
            key = M.key(entry.file),
            first = first,
            last = first + #rows - 1,
        })
    end

    return doc
end

--- The section and model row at `lnum`. A separator belongs to the file
--- above it and has no row.
---@param doc IterDocument
---@param lnum integer
---@return IterDocSection? section
---@return integer? row
---@return integer? index of the section
function M.at(doc, lnum)
    local line = doc.lines[lnum]

    if line == nil then
        return nil, nil, nil
    end

    return doc.sections[line.section], line.row, line.section
end

--- The line of model row `row` of section `index`.
---@param doc IterDocument
---@param index integer
---@param row integer
---@return integer?
function M.line_of(doc, index, row)
    local section = doc.sections[index]

    if section == nil or row < 1 or row > section.last - section.first + 1 then
        return nil
    end

    return section.first + row - 1
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
