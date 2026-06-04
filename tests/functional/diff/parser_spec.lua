---@diagnostic disable: undefined-field
local parser = require('iter.ui.diff.parser')

describe('iter.diff.parser', function()
    describe('parse_hunk_header', function()
        it('parses standard hunk header with counts', function()
            local old_start, old_count, new_start, new_count =
                parser.parse_hunk_header('@@ -10,5 +12,7 @@')

            assert.are.equal(10, old_start)
            assert.are.equal(5, old_count)
            assert.are.equal(12, new_start)
            assert.are.equal(7, new_count)
        end)

        it('parses hunk header with single-line counts omitted', function()
            local old_start, old_count, new_start, new_count =
                parser.parse_hunk_header('@@ -5 +7 @@')

            assert.are.equal(5, old_start)
            assert.are.equal(1, old_count)
            assert.are.equal(7, new_start)
            assert.are.equal(1, new_count)
        end)

        it('parses zero-count hunk (deletion)', function()
            local old_start, old_count, new_start, new_count =
                parser.parse_hunk_header('@@ -8,3 +8,0 @@')

            assert.are.equal(8, old_start)
            assert.are.equal(3, old_count)
            assert.are.equal(8, new_start)
            assert.are.equal(0, new_count)
        end)

        it('parses zero-count hunk (insertion)', function()
            local old_start, old_count, new_start, new_count =
                parser.parse_hunk_header('@@ -4,0 +4,3 @@')

            assert.are.equal(4, old_start)
            assert.are.equal(0, old_count)
            assert.are.equal(4, new_start)
            assert.are.equal(3, new_count)
        end)

        it('returns nil for malformed header', function()
            local old_start, old_count, new_start, new_count =
                parser.parse_hunk_header('not a hunk header')

            assert.is_nil(old_start)
            assert.is_nil(old_count)
            assert.is_nil(new_start)
            assert.is_nil(new_count)
        end)

        it('handles section heading in hunk header', function()
            local old_start, old_count, new_start, new_count =
                parser.parse_hunk_header('@@ -1,4 +1,4 @@ function foo()')

            assert.are.equal(1, old_start)
            assert.are.equal(4, old_count)
            assert.are.equal(1, new_start)
            assert.are.equal(4, new_count)
        end)
    end)

    describe('parse_lines', function()
        it('classifies context, added, and removed lines', function()
            local lines = {
                ' context line',
                '+added line',
                '-removed line',
                ' another context',
            }

            local parsed = parser.parse_lines(lines)

            assert.are.equal(4, #parsed)

            assert.are.equal('context', parsed[1].kind)
            assert.are.equal(' context line', parsed[1].text)
            assert.are.equal(1, parsed[1].raw_row)

            assert.are.equal('added', parsed[2].kind)
            assert.are.equal('+added line', parsed[2].text)

            assert.are.equal('removed', parsed[3].kind)
            assert.are.equal('-removed line', parsed[3].text)

            assert.are.equal('context', parsed[4].kind)
        end)

        it('classifies hunk headers', function()
            local lines = { '@@ -1,3 +1,4 @@' }
            local parsed = parser.parse_lines(lines)

            assert.are.equal(1, #parsed)
            assert.are.equal('hunk', parsed[1].kind)
            assert.are.equal(1, parsed[1].old_number)
            assert.are.equal(1, parsed[1].new_number)
        end)

        it('classifies diff headers', function()
            local lines = {
                'diff --git a/file.txt b/file.txt',
                'index abc123..def456 100644',
                '--- a/file.txt',
                '+++ b/file.txt',
                'rename from old.txt',
                'rename to new.txt',
            }

            local parsed = parser.parse_lines(lines)

            assert.are.equal(6, #parsed)
            for _, line in ipairs(parsed) do
                assert.are.equal('header', line.kind)
            end
        end)

        it('skips empty lines and no-newline markers', function()
            local lines = {
                '',
                '\\ No newline at end of file',
                ' context',
            }

            local parsed = parser.parse_lines(lines)

            assert.are.equal(1, #parsed)
            assert.are.equal('context', parsed[1].kind)
            assert.are.equal(' context', parsed[1].text)
        end)

        it('tracks line numbers correctly across a hunk', function()
            local lines = {
                '@@ -10,3 +12,4 @@',
                ' unchanged',
                '-removed',
                '+added one',
                '+added two',
                ' more context',
            }

            local parsed = parser.parse_lines(lines)

            -- Hunk header: old=10, new=12
            assert.are.equal('hunk', parsed[1].kind)
            assert.are.equal(10, parsed[1].old_number)
            assert.are.equal(12, parsed[1].new_number)

            -- Context: both old and new numbers present, then incremented
            assert.are.equal('context', parsed[2].kind)
            assert.are.equal(10, parsed[2].old_number)
            assert.are.equal(12, parsed[2].new_number)

            -- Removed: only old_number, new_number is nil
            assert.are.equal('removed', parsed[3].kind)
            assert.are.equal(11, parsed[3].old_number)
            assert.is_nil(parsed[3].new_number)

            -- Added: only new_number, old_number is nil
            assert.are.equal('added', parsed[4].kind)
            assert.is_nil(parsed[4].old_number)
            assert.are.equal(13, parsed[4].new_number)

            -- Added: new_number continues
            assert.are.equal('added', parsed[5].kind)
            assert.is_nil(parsed[5].old_number)
            assert.are.equal(14, parsed[5].new_number)

            -- Context after additions: old skipped, new incremented
            assert.are.equal('context', parsed[6].kind)
            assert.are.equal(12, parsed[6].old_number)
            assert.are.equal(15, parsed[6].new_number)
        end)
    end)

    describe('parse_hunks', function()
        it('extracts a single hunk from a diff', function()
            local lines = {
                '@@ -1,3 +1,4 @@',
                ' line one',
                '+line two',
                ' line three',
            }

            local hunks = parser.parse_hunks(lines)

            assert.are.equal(1, #hunks)
            assert.are.equal(1, hunks[1].index)
            assert.are.equal(1, hunks[1].raw_header_row)
            assert.are.equal(1, hunks[1].raw_start_row)
            assert.are.equal(4, hunks[1].raw_end_row)
            assert.are.equal(1, hunks[1].old_start)
            assert.are.equal(3, hunks[1].old_count)
            assert.are.equal(1, hunks[1].new_start)
            assert.are.equal(4, hunks[1].new_count)
        end)

        it('separates multiple hunks by diff headers', function()
            local lines = {
                '@@ -1,3 +1,3 @@',
                ' unchanged',
                '@@ -10,2 +10,3 @@',
                ' context',
                '+added',
                'diff --git a/other.txt b/other.txt',
                '@@ -20,1 +20,1 @@',
                ' final',
            }

            local hunks = parser.parse_hunks(lines)

            assert.are.equal(3, #hunks)

            assert.are.equal(1, hunks[1].index)
            assert.are.equal(1, hunks[1].raw_start_row)
            assert.are.equal(2, hunks[1].raw_end_row)

            assert.are.equal(2, hunks[2].index)
            assert.are.equal(3, hunks[2].raw_start_row)
            assert.are.equal(5, hunks[2].raw_end_row)

            assert.are.equal(3, hunks[3].index)
            assert.are.equal(7, hunks[3].raw_start_row)
            assert.are.equal(8, hunks[3].raw_end_row)
        end)

        it('returns empty for diff without hunks', function()
            local lines = {
                'diff --git a/file.txt b/file.txt',
                'index abc..def',
                '--- a/file.txt',
                '+++ b/file.txt',
            }

            local hunks = parser.parse_hunks(lines)
            assert.are.same({}, hunks)
        end)

        it('computes old_end and new_end correctly', function()
            local lines = {
                '@@ -10,5 +12,3 @@',
                ' context',
            }

            local hunks = parser.parse_hunks(lines)

            assert.are.equal(14, hunks[1].old_end)
            assert.are.equal(14, hunks[1].new_end)
        end)
    end)

    describe('line_at_raw_row', function()
        local test_lines = {
            '@@ -1,2 +1,2 @@',
            ' unchanged',
            '+added',
        }

        it('finds a line by its raw row', function()
            local line = parser.line_at_raw_row(test_lines, 2)
            assert.is_not_nil(line)
            assert.are.equal('context', line.kind)
            assert.are.equal(' unchanged', line.text)
        end)

        it('returns nil for nil inputs', function()
            assert.is_nil(parser.line_at_raw_row(nil, 1))
            assert.is_nil(parser.line_at_raw_row(test_lines, nil))
            assert.is_nil(parser.line_at_raw_row(nil, nil))
        end)

        it('returns nil for out-of-range row', function()
            assert.is_nil(parser.line_at_raw_row(test_lines, 999))
        end)
    end)

    describe('assign_stacked_rows', function()
        it('assigns stacked_row to hunks matching raw_rows', function()
            local lines = {
                'diff --git a/file.txt b/file.txt',
                '@@ -1,2 +1,2 @@',
                ' unchanged',
            }

            local hunks = parser.parse_hunks(lines)
            -- In a rendered stacked diff, the raw row 2 (the hunk header)
            -- might appear at stacked row 3 (after header lines).
            local raw_rows = { 1, 3, 2, 4 }
            -- raw_row 2 (hunk header) is at stacked row 3

            parser.assign_stacked_rows(hunks, raw_rows)

            assert.are.equal(3, hunks[1].stacked_row)
        end)

        it('handles nil raw_rows gracefully', function()
            local hunks = parser.parse_hunks({
                '@@ -1,2 +1,2 @@',
                ' context',
            })

            parser.assign_stacked_rows(hunks, nil)
            -- Should not error; stacked_row should remain nil
            assert.is_nil(hunks[1].stacked_row)
        end)

        it('clears previous stacked_row assignments', function()
            local hunks = parser.parse_hunks({
                '@@ -1,2 +1,2 @@',
                ' context',
            })

            hunks[1].stacked_row = 10
            -- raw_rows = { 5 } means raw row 1 is at stacked row 5,
            -- but the hunk header is at raw row 1, so it matches and
            -- gets stacked_row = 5 (not nil).
            -- Use an empty raw_rows to ensure no match.
            parser.assign_stacked_rows(hunks, {})
            assert.is_nil(hunks[1].stacked_row)
        end)
    end)
end)
