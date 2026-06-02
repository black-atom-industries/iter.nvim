---@diagnostic disable: undefined-field
local parser = require('flux.ui.diff.parser')
local position = require('flux.ui.diff.position')

-- Helper: build a small diff with known structure
-- File: a.txt (new file, pure added)
local SAMPLE_DIFF_INSERTION = {
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

-- File with a single hunk: 2 context, 1 removed, 1 added, 1 context
local SAMPLE_DIFF_SINGLE_HUNK = {
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

-- File with two hunks
local SAMPLE_DIFF_TWO_HUNKS = {
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

describe('flux.diff.position', function()
    describe('hunk_by_index', function()
        local hunks

        before_each(function()
            hunks = parser.parse_hunks(SAMPLE_DIFF_TWO_HUNKS)
        end)

        it('finds a hunk by its index', function()
            local hunk = position.hunk_by_index(hunks, 1)
            assert.is_not_nil(hunk)
            assert.are.equal(1, hunk.index)
            assert.are.equal(1, hunk.old_start)
            assert.are.equal(3, hunk.old_count)
        end)

        it('finds the second hunk', function()
            local hunk = position.hunk_by_index(hunks, 2)
            assert.is_not_nil(hunk)
            assert.are.equal(2, hunk.index)
            assert.are.equal(10, hunk.old_start)
        end)

        it('returns nil for missing index', function()
            assert.is_nil(position.hunk_by_index(hunks, 99))
            assert.is_nil(position.hunk_by_index(hunks, nil))
            assert.is_nil(position.hunk_by_index(nil, 0))
        end)
    end)

    describe('hunk_position_for_raw_row (stacked)', function()
        local lines, hunks

        before_each(function()
            lines = SAMPLE_DIFF_SINGLE_HUNK
            hunks = parser.parse_hunks(lines)
        end)

        it('maps a removed line to the left side', function()
            -- '-removed line' is raw_row 7
            local pos = position.hunk_position_for_raw_row(lines, hunks, 7)
            assert.is_not_nil(pos)
            assert.are.equal(1, pos.hunk_index)
            assert.are.equal('left', pos.side)
            -- old_start=10, removed line old_number=11, offset=1
            assert.are.equal(1, pos.offset)
        end)

        it('maps an added line to the right side', function()
            -- '+added line one' is raw_row 8
            local pos = position.hunk_position_for_raw_row(lines, hunks, 8)
            assert.is_not_nil(pos)
            assert.are.equal(1, pos.hunk_index)
            assert.are.equal('right', pos.side)
            -- new_start=10, added line new_number=11, offset=1
            assert.are.equal(1, pos.offset)
        end)

        it('maps a context line to the right side', function()
            -- ' unchanged 1' is raw_row 6
            local pos = position.hunk_position_for_raw_row(lines, hunks, 6)
            assert.is_not_nil(pos)
            assert.are.equal(1, pos.hunk_index)
            assert.are.equal('right', pos.side)
        end)

        it('returns nil for a line outside any hunk', function()
            -- diff --git header is raw_row 1
            local pos = position.hunk_position_for_raw_row(lines, hunks, 1)
            assert.is_nil(pos)
        end)
    end)

    describe('hunk_position_for_split_row', function()
        local hunks

        before_each(function()
            hunks = parser.parse_hunks(SAMPLE_DIFF_SINGLE_HUNK)
        end)

        it('maps a left-side row within a hunk', function()
            -- old_start=10, so row 11 on left side is the removed line
            local pos = position.hunk_position_for_split_row(hunks, 'left', 11)
            assert.is_not_nil(pos)
            assert.are.equal(1, pos.hunk_index)
            assert.are.equal('left', pos.side)
            assert.are.equal(1, pos.offset)
        end)

        it('maps a right-side row within a hunk', function()
            -- new_start=10, so row 11 on right side is 'added line one'
            local pos = position.hunk_position_for_split_row(hunks, 'right', 11)
            assert.is_not_nil(pos)
            assert.are.equal(1, pos.hunk_index)
            assert.are.equal('right', pos.side)
            assert.are.equal(1, pos.offset)
        end)

        it('returns nil for a row outside all hunks', function()
            local pos = position.hunk_position_for_split_row(hunks, 'left', 999)
            assert.is_nil(pos)
        end)
    end)

    describe('source_line_for_stacked_row', function()
        local lines, hunks

        before_each(function()
            lines = SAMPLE_DIFF_SINGLE_HUNK
            hunks = parser.parse_hunks(lines)
        end)

        it('returns new_number for an added line', function()
            -- '+added line one' is raw_row 8, new_number=11
            local source = position.source_line_for_stacked_row(lines, hunks, 8)
            assert.are.equal(11, source)
        end)

        it('returns new_number for a context line', function()
            -- ' unchanged 1' is raw_row 6, new_number=10
            local source = position.source_line_for_stacked_row(lines, hunks, 6)
            assert.are.equal(10, source)
        end)

        it('finds nearest surviving new_number for a removed line', function()
            -- '-removed line' is raw_row 7; it has no new_number,
            -- so it finds the nearest context/added line's new_number
            local source = position.source_line_for_stacked_row(lines, hunks, 7)
            assert.is_not_nil(source)
            -- Should be 11 (next added line) or 10 (prior context)
            assert.is_true(source == 10 or source == 11)
        end)

        it('returns nil for nil raw_row', function()
            assert.is_nil(
                position.source_line_for_stacked_row(lines, hunks, nil)
            )
        end)
    end)

    describe('source_line_for_split_row', function()
        local lines, hunks

        before_each(function()
            lines = SAMPLE_DIFF_SINGLE_HUNK
            hunks = parser.parse_hunks(lines)
        end)

        it('maps left side row to a source line', function()
            local source =
                position.source_line_for_split_row(lines, hunks, 'left', 10)
            -- old_start=10, old_count=3, row=10 is the first context line
            -- which maps to new_number=10 (the unchanged line)
            assert.are.equal(10, source)
        end)

        it('maps right side row to itself outside hunks', function()
            local source =
                position.source_line_for_split_row(lines, hunks, 'right', 1)
            -- Row 1 is before any hunk (new_start=10), so it maps to itself
            assert.are.equal(1, source)
        end)

        it('maps left side row to itself outside hunks', function()
            local source =
                position.source_line_for_split_row(lines, hunks, 'left', 1)
            assert.are.equal(1, source)
        end)
    end)

    describe('old_line_to_new_line', function()
        local lines, hunks

        before_each(function()
            lines = SAMPLE_DIFF_TWO_HUNKS
            hunks = parser.parse_hunks(lines)
        end)

        it('translates old line through hunk delta', function()
            -- Hunk 1: old_start=1, old_count=3, new_count=4 (delta=+1)
            -- Hunk 2: old_start=10, old_count=2, new_count=3 (delta=+2)
            -- Total delta before hunk 2: +1 (from hunk 1)

            -- old_line 1 (before hunk 1): returns 1
            assert.are.equal(1, position.old_line_to_new_line(lines, hunks, 1))

            -- old_line 2 (in hunk 1, removed line): maps via diff
            local translated2 = position.old_line_to_new_line(lines, hunks, 2)
            assert.is_not_nil(translated2)

            -- old_line 5 (between hunks): 5 + delta_from_hunk1(+1) = 6
            assert.are.equal(6, position.old_line_to_new_line(lines, hunks, 5))

            -- old_line 12 (after hunk 2): 12 + total_delta(+2) = 14
            assert.are.equal(
                14,
                position.old_line_to_new_line(lines, hunks, 12)
            )
        end)
    end)

    describe('stacked_row_for_hunk_position', function()
        local lines, hunks, raw_rows

        before_each(function()
            lines = SAMPLE_DIFF_SINGLE_HUNK
            hunks = parser.parse_hunks(lines)

            -- Simulate rendered stacked diff where raw rows appear at
            -- different stacked positions due to header filtering.
            raw_rows = { 5, 6, 7, 8, 9 }
            -- raw_row 5 = '@@ -10,3...' hunk header
            -- raw_row 6 = ' unchanged 1'
            -- raw_row 7 = '-removed line'
            -- raw_row 8 = '+added line one'
            -- raw_row 9 = '+added line two'

            parser.assign_stacked_rows(hunks, raw_rows)
        end)

        it('maps hunk position to stacked row for left side', function()
            -- offset=1 on left → old_start + 1 = 11 → 'removed line' at raw_row 7 → stacked 3
            local row = position.stacked_row_for_hunk_position(
                lines,
                raw_rows,
                hunks[1],
                'left',
                1
            )
            assert.are.equal(3, row)
        end)

        it('maps hunk position to stacked row for right side', function()
            -- offset=1 on right → new_start + 1 = 11 → raw_row 8 → stacked 4
            local row = position.stacked_row_for_hunk_position(
                lines,
                raw_rows,
                hunks[1],
                'right',
                1
            )
            assert.are.equal(4, row)
        end)
    end)

    describe('split_row_for_hunk_position', function()
        local lines
        local hunks

        before_each(function()
            lines = SAMPLE_DIFF_SINGLE_HUNK
            hunks = parser.parse_hunks(lines)
        end)

        it('converts left-side position to split row', function()
            local side, row = position.split_row_for_hunk_position(hunks[1], {
                hunk_index = 1,
                side = 'left',
                offset = 1,
            })
            assert.are.equal('left', side)
            -- old_start=10, offset=1 → row 11
            assert.are.equal(11, row)
        end)

        it('converts right-side position to split row', function()
            local side, row = position.split_row_for_hunk_position(hunks[1], {
                hunk_index = 1,
                side = 'right',
                offset = 1,
            })
            assert.are.equal('right', side)
            assert.are.equal(11, row)
        end)

        it('falls back to opposite side for zero-count hunks', function()
            -- Create a pure insertion hunk: old_count=0
            local insertion_hunks = parser.parse_hunks(SAMPLE_DIFF_INSERTION)
            local side, row =
                position.split_row_for_hunk_position(insertion_hunks[1], {
                    hunk_index = 1,
                    side = 'left',
                    offset = 0,
                })
            -- Falls back to right side since left count is 0
            assert.are.equal('right', side)
            assert.are.equal(1, row)
        end)
    end)
end)
