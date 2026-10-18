local parser = require('iter.ui.diff.parser')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality

local T = new_set()

T['parse_hunk_header()'] = new_set()

T['parse_hunk_header()']['parses standard header with counts'] = function()
    eq({ parser.parse_hunk_header('@@ -10,5 +12,7 @@') }, { 10, 5, 12, 7 })
end

T['parse_hunk_header()']['defaults omitted counts to 1'] = function()
    eq({ parser.parse_hunk_header('@@ -5 +7 @@') }, { 5, 1, 7, 1 })
end

T['parse_hunk_header()']['parses zero-count deletion'] = function()
    eq({ parser.parse_hunk_header('@@ -8,3 +8,0 @@') }, { 8, 3, 8, 0 })
end

T['parse_hunk_header()']['parses zero-count insertion'] = function()
    eq({ parser.parse_hunk_header('@@ -4,0 +4,3 @@') }, { 4, 0, 4, 3 })
end

T['parse_hunk_header()']['returns nil for a malformed header'] = function()
    local old_start, old_count, new_start, new_count =
        parser.parse_hunk_header('not a hunk header')

    eq(old_start, nil)
    eq(old_count, nil)
    eq(new_start, nil)
    eq(new_count, nil)
end

T['parse_hunk_header()']['ignores the section heading'] = function()
    eq(
        { parser.parse_hunk_header('@@ -1,4 +1,4 @@ function foo()') },
        { 1, 4, 1, 4 }
    )
end

T['parse_lines()'] = new_set()

T['parse_lines()']['classifies context, added and removed lines'] = function()
    local parsed = parser.parse_lines({
        ' context line',
        '+added line',
        '-removed line',
        ' another context',
    })

    eq(#parsed, 4)
    eq(parsed[1].kind, 'context')
    eq(parsed[1].text, ' context line')
    eq(parsed[1].raw_row, 1)
    eq(parsed[2].kind, 'added')
    eq(parsed[2].text, '+added line')
    eq(parsed[3].kind, 'removed')
    eq(parsed[3].text, '-removed line')
    eq(parsed[4].kind, 'context')
end

T['parse_lines()']['classifies hunk headers'] = function()
    local parsed = parser.parse_lines({ '@@ -1,3 +1,4 @@' })

    eq(#parsed, 1)
    eq(parsed[1].kind, 'hunk')
    eq(parsed[1].old_number, 1)
    eq(parsed[1].new_number, 1)
end

T['parse_lines()']['classifies diff headers'] = function()
    local parsed = parser.parse_lines({
        'diff --git a/file.txt b/file.txt',
        'index abc123..def456 100644',
        '--- a/file.txt',
        '+++ b/file.txt',
        'rename from old.txt',
        'rename to new.txt',
    })

    eq(#parsed, 6)
    for _, line in ipairs(parsed) do
        eq(line.kind, 'header')
    end
end

T['parse_lines()']['skips empty lines and no-newline markers'] = function()
    local parsed = parser.parse_lines({
        '',
        '\\ No newline at end of file',
        ' context',
    })

    eq(#parsed, 1)
    eq(parsed[1].kind, 'context')
    eq(parsed[1].text, ' context')
end

T['parse_lines()']['tracks line numbers across a hunk'] = function()
    local parsed = parser.parse_lines({
        '@@ -10,3 +12,4 @@',
        ' unchanged',
        '-removed',
        '+added one',
        '+added two',
        ' more context',
    })

    local numbers = vim.tbl_map(function(line)
        return { line.kind, line.old_number, line.new_number }
    end, parsed)

    eq(numbers, {
        { 'hunk', 10, 12 },
        { 'context', 10, 12 },
        { 'removed', 11, nil },
        { 'added', nil, 13 },
        { 'added', nil, 14 },
        { 'context', 12, 15 },
    })
end

T['parse_hunks()'] = new_set()

T['parse_hunks()']['extracts a single hunk'] = function()
    local hunks = parser.parse_hunks({
        '@@ -1,3 +1,4 @@',
        ' line one',
        '+line two',
        ' line three',
    })

    eq(#hunks, 1)
    eq(hunks[1].index, 1)
    eq(hunks[1].raw_header_row, 1)
    eq(hunks[1].raw_start_row, 1)
    eq(hunks[1].raw_end_row, 4)
    eq(hunks[1].old_start, 1)
    eq(hunks[1].old_count, 3)
    eq(hunks[1].new_start, 1)
    eq(hunks[1].new_count, 4)
end

T['parse_hunks()']['separates hunks at hunk and diff headers'] = function()
    local hunks = parser.parse_hunks({
        '@@ -1,3 +1,3 @@',
        ' unchanged',
        '@@ -10,2 +10,3 @@',
        ' context',
        '+added',
        'diff --git a/other.txt b/other.txt',
        '@@ -20,1 +20,1 @@',
        ' final',
    })

    local rows = vim.tbl_map(function(hunk)
        return { hunk.index, hunk.raw_start_row, hunk.raw_end_row }
    end, hunks)

    eq(rows, { { 1, 1, 2 }, { 2, 3, 5 }, { 3, 7, 8 } })
end

T['parse_hunks()']['returns empty for a diff without hunks'] = function()
    local hunks = parser.parse_hunks({
        'diff --git a/file.txt b/file.txt',
        'index abc..def',
        '--- a/file.txt',
        '+++ b/file.txt',
    })

    eq(hunks, {})
end

T['parse_hunks()']['computes old_end and new_end'] = function()
    local hunks = parser.parse_hunks({ '@@ -10,5 +12,3 @@', ' context' })

    eq(hunks[1].old_end, 14)
    eq(hunks[1].new_end, 14)
end

return T
