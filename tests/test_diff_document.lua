local document = require('iter.diff.document')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

--- A file diff stub on `side` with a header and `count` context rows.
---@param path string
---@param side IterSide
---@param count integer
---@return IterFileDiff
local function file(path, side, count)
    local rows = { { kind = 'header', text = path } }

    for i = 1, count do
        table.insert(
            rows,
            { kind = 'context', text = path .. i, old = i, new = i }
        )
    end

    return {
        path = path,
        side = side,
        code = 'M',
        raw = {},
        hunks = {},
        rows = rows,
        binary = false,
        stat = { add = 0, del = 0 },
    }
end

--- `a.txt` (2 rows after its header), `b.txt` (1) and `a.txt` staged (3).
---@return IterDocument
local function three()
    return document.build({
        { file = file('a.txt', 'unstaged', 2) },
        { file = file('b.txt', 'unstaged', 1), new_follows = true },
        { file = file('a.txt', 'staged', 3) },
    })
end

local T = new_set()

T['build()'] = new_set()

T['build()']['one file takes one line per row and no separator'] = function()
    local doc = document.build({ { file = file('a.txt', 'unstaged', 2) } })

    eq(#doc.rows, 3)
    eq(doc.rows[1].kind, 'header')
    eq(doc.sections[1].first, 1)
    eq(doc.sections[1].last, 3)
    eq(doc.sections[1].key, 'unstaged\0a.txt')
end

T['build()']['puts one blank line between files'] = function()
    local doc = three()

    eq(
        vim.tbl_map(function(row)
            return row.text
        end, doc.rows),
        {
            'a.txt',
            'a.txt1',
            'a.txt2',
            '',
            'b.txt',
            'b.txt1',
            '',
            'a.txt',
            'a.txt1',
            'a.txt2',
            'a.txt3',
        }
    )
    eq(doc.rows[4].kind, 'blank')
    eq(
        vim.tbl_map(function(section)
            return { section.first, section.last }
        end, doc.sections),
        { { 1, 3 }, { 5, 6 }, { 8, 11 } }
    )
    eq(doc.sections[2].new_follows, true)
end

T['build()']['the rows are the model rows themselves'] = function()
    local a = file('a.txt', 'unstaged', 2)
    local doc = document.build({
        { file = a },
        { file = file('b.txt', 'unstaged', 1) },
    })

    eq(rawequal(doc.rows[2], a.rows[2]), true)
    eq(rawequal(doc.sections[1].file, a), true)
end

T['build()']['no entries give an empty document'] = function()
    local doc = document.build({})

    eq(doc.sections, {})
    eq(doc.rows, {})
    eq(doc.lines, {})
end

T['at()'] = new_set()

T['at()']['maps a line to its section and model row'] = function()
    local doc = three()
    local section, row, index = document.at(doc, 9)

    eq(section and section.key, 'staged\0a.txt')
    eq(row, 2)
    eq(index, 3)

    section, row, index = document.at(doc, 5)
    eq({ section and section.file.path, row, index }, { 'b.txt', 1, 2 })
end

T['at()']['a separator belongs to the file above it, without a row'] = function()
    local section, row, index = document.at(three(), 7)

    eq(section and section.file.path, 'b.txt')
    eq(row, nil)
    eq(index, 2)
end

T['at()']['a line outside the document maps to nothing'] = function()
    eq({ document.at(three(), 12) }, {})
    eq({ document.at(three(), 0) }, {})
end

T['line_of()'] = new_set()

T['line_of()']['is the inverse of at()'] = function()
    local doc = three()

    for lnum, line in ipairs(doc.lines) do
        if line.row ~= nil then
            eq(document.line_of(doc, line.section, line.row), lnum)
        end
    end
end

T['line_of()']['a row outside its section has no line'] = function()
    local doc = three()

    eq(document.line_of(doc, 2, 3), nil)
    eq(document.line_of(doc, 2, 0), nil)
    eq(document.line_of(doc, 4, 1), nil)
end

T['find()'] = new_set()

T['find()']['tells the sides of one path apart'] = function()
    local doc = three()

    eq(document.find(doc, 'unstaged\0a.txt'), 1)
    eq(document.find(doc, 'staged\0a.txt'), 3)
    eq(
        document.find(doc, document.key({ side = 'staged', path = 'b.txt' })),
        nil
    )
end

T['sections_in()'] = new_set()

T['sections_in()']['lists the sections a line range touches'] = function()
    local doc = three()

    eq(document.sections_in(doc, 1, 11), { 1, 2, 3 })
    eq(document.sections_in(doc, 2, 3), { 1 })
    eq(document.sections_in(doc, 4, 4), { 1 })
    eq(document.sections_in(doc, 6, 8), { 2, 3 })
    eq(document.sections_in(doc, 12, 20), {})
end

return T
