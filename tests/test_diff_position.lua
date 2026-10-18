local parser = require('iter.ui.diff.parser')
local position = require('iter.ui.diff.position')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality

-- New file, pure insertion.
local DIFF_INSERTION = {
    'diff --git a/a.txt b/a.txt',
    'new file mode 100644',
    'index 0000000..e69de29',
    '--- /dev/null',
    '+++ b/a.txt',
    '@@ -0,0 +1,3 @@',
    '+line one',
    '+line two',
    '+line three',
}

-- One hunk: context, removed, two added, context. Raw rows 6 to 10.
local DIFF_SINGLE_HUNK = {
    'diff --git a/file.txt b/file.txt',
    'index abc..def 100644',
    '--- a/file.txt',
    '+++ b/file.txt',
    '@@ -10,3 +10,4 @@ function foo()',
    ' unchanged 1',
    '-removed line',
    '+added line one',
    '+added line two',
    ' unchanged 2',
}

local DIFF_TWO_HUNKS = {
    'diff --git a/file.txt b/file.txt',
    '--- a/file.txt',
    '+++ b/file.txt',
    '@@ -1,3 +1,4 @@',
    ' ctx1',
    '-rm1',
    '+add1',
    ' ctx2',
    '@@ -10,2 +10,3 @@',
    ' ctx3',
    '+add2',
    ' ctx4',
}

local T = new_set()

T['hunk_by_index()'] = new_set()

T['hunk_by_index()']['finds hunks by index'] = function()
    local hunks = parser.parse_hunks(DIFF_TWO_HUNKS)

    local first = position.hunk_by_index(hunks, 1)
    eq({ first.index, first.old_start, first.old_count }, { 1, 1, 3 })

    local second = position.hunk_by_index(hunks, 2)
    eq({ second.index, second.old_start }, { 2, 10 })
end

T['hunk_by_index()']['returns nil for a missing index'] = function()
    local hunks = parser.parse_hunks(DIFF_TWO_HUNKS)

    eq(position.hunk_by_index(hunks, 99), nil)
    eq(position.hunk_by_index(hunks, nil), nil)
    eq(position.hunk_by_index(nil, 0), nil)
end

T['hunk_position_for_raw_row()'] = new_set()

---@param raw_row integer
---@return table?
local function raw_position(raw_row)
    local hunks = parser.parse_hunks(DIFF_SINGLE_HUNK)
    return position.hunk_position_for_raw_row(DIFF_SINGLE_HUNK, hunks, raw_row)
end

T['hunk_position_for_raw_row()']['maps a removed line left'] = function()
    eq(raw_position(7), { hunk_index = 1, side = 'left', offset = 1 })
end

T['hunk_position_for_raw_row()']['maps an added line right'] = function()
    eq(raw_position(8), { hunk_index = 1, side = 'right', offset = 1 })
end

T['hunk_position_for_raw_row()']['maps a context line right'] = function()
    local pos = raw_position(6)

    eq({ pos.hunk_index, pos.side }, { 1, 'right' })
end

T['hunk_position_for_raw_row()']['returns nil outside hunks'] = function()
    eq(raw_position(1), nil)
end

T['hunk_position_for_split_row()'] = new_set()

T['hunk_position_for_split_row()']['maps rows inside a hunk'] = function()
    local hunks = parser.parse_hunks(DIFF_SINGLE_HUNK)

    eq(
        position.hunk_position_for_split_row(hunks, 'left', 11),
        { hunk_index = 1, side = 'left', offset = 1 }
    )
    eq(
        position.hunk_position_for_split_row(hunks, 'right', 11),
        { hunk_index = 1, side = 'right', offset = 1 }
    )
end

T['hunk_position_for_split_row()']['returns nil outside hunks'] = function()
    local hunks = parser.parse_hunks(DIFF_SINGLE_HUNK)

    eq(position.hunk_position_for_split_row(hunks, 'left', 999), nil)
end

T['source_line_for_stacked_row()'] = new_set()

---@param raw_row integer?
---@return integer?
local function stacked_source(raw_row)
    local hunks = parser.parse_hunks(DIFF_SINGLE_HUNK)
    return position.source_line_for_stacked_row(
        DIFF_SINGLE_HUNK,
        hunks,
        raw_row
    )
end

T['source_line_for_stacked_row()']['uses new_number of added and context'] = function()
    eq(stacked_source(8), 11)
    eq(stacked_source(6), 10)
end

T['source_line_for_stacked_row()']['finds a surviving line for a removed one'] = function()
    local source = stacked_source(7)

    neq(source, nil)
    eq(source == 10 or source == 11, true)
end

T['source_line_for_stacked_row()']['returns nil for nil raw_row'] = function()
    eq(stacked_source(nil), nil)
end

T['source_line_for_split_row()'] = new_set()

T['source_line_for_split_row()']['maps rows to source lines'] = function()
    local hunks = parser.parse_hunks(DIFF_SINGLE_HUNK)
    local function source(side, row)
        return position.source_line_for_split_row(
            DIFF_SINGLE_HUNK,
            hunks,
            side,
            row
        )
    end

    -- Left row 10 is the first context line, which is new line 10.
    eq(source('left', 10), 10)
    -- Rows before the hunk map to themselves on either side.
    eq(source('right', 1), 1)
    eq(source('left', 1), 1)
end

T['old_line_to_new_line()'] = new_set()

T['old_line_to_new_line()']['translates through hunk deltas'] = function()
    local hunks = parser.parse_hunks(DIFF_TWO_HUNKS)
    local function translate(old_line)
        return position.old_line_to_new_line(DIFF_TWO_HUNKS, hunks, old_line)
    end

    -- Hunk 1 adds one line, hunk 2 adds one more.
    eq(translate(1), 1)
    neq(translate(2), nil)
    eq(translate(5), 6)
    eq(translate(12), 14)
end

T['stacked_row_for_hunk_position()'] = new_set()

---@param side 'left'|'right'
---@param offset integer
---@return integer?
local function stacked_row(side, offset)
    local hunks = parser.parse_hunks(DIFF_SINGLE_HUNK)
    -- Raw rows 5 to 9 are rendered at stacked rows 1 to 5.
    local raw_rows = { 5, 6, 7, 8, 9 }
    parser.assign_stacked_rows(hunks, raw_rows)

    return position.stacked_row_for_hunk_position(
        DIFF_SINGLE_HUNK,
        raw_rows,
        hunks[1],
        side,
        offset
    )
end

T['stacked_row_for_hunk_position()']['maps the left side'] = function()
    -- Old line 11 is '-removed line' at raw row 7, stacked row 3.
    eq(stacked_row('left', 1), 3)
end

T['stacked_row_for_hunk_position()']['maps the right side'] = function()
    -- New line 11 is '+added line one' at raw row 8, stacked row 4.
    eq(stacked_row('right', 1), 4)
end

T['split_row_for_hunk_position()'] = new_set()

T['split_row_for_hunk_position()']['converts both sides'] = function()
    local hunk = parser.parse_hunks(DIFF_SINGLE_HUNK)[1]

    eq({
        position.split_row_for_hunk_position(
            hunk,
            { hunk_index = 1, side = 'left', offset = 1 }
        ),
    }, { 'left', 11 })
    eq({
        position.split_row_for_hunk_position(
            hunk,
            { hunk_index = 1, side = 'right', offset = 1 }
        ),
    }, { 'right', 11 })
end

T['split_row_for_hunk_position()']['falls back to the other side for zero-count hunks'] = function()
    local hunk = parser.parse_hunks(DIFF_INSERTION)[1]

    eq({
        position.split_row_for_hunk_position(
            hunk,
            { hunk_index = 1, side = 'left', offset = 0 }
        ),
    }, { 'right', 1 })
end

return T
