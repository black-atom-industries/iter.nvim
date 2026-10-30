local words = require('iter.diff.words')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

--- The text each range covers.
---@param text string
---@param ranges integer[][]?
---@return string[]?
local function covered(text, ranges)
    if ranges == nil then
        return nil
    end

    return vim.tbl_map(function(range)
        return text:sub(range[1] + 1, range[2])
    end, ranges)
end

--- Rows of one change group: `dels` deleted lines followed by `adds`.
---@param dels string[]
---@param adds string[]
---@return IterDiffRow[]
local function group(dels, adds)
    local rows = { { kind = 'hunk', text = '@@ -1 +1 @@', hunk = 1 } }

    for i, text in ipairs(dels) do
        table.insert(rows, { kind = 'del', text = text, old = i, hunk = 1 })
    end

    for i, text in ipairs(adds) do
        table.insert(rows, { kind = 'add', text = text, new = i, hunk = 1 })
    end

    return rows
end

local T = new_set()

T['ranges()'] = new_set()

T['ranges()']['marks the changed ASCII word on both sides'] = function()
    local old, new = 'local count = 10', 'local total = 10'
    local del, add = words.ranges(old, new)

    eq(del, { { 6, 11 } })
    eq(add, { { 6, 11 } })
    eq(covered(old, del), { 'count' })
    eq(covered(new, add), { 'total' })
end

T['ranges()']['marks an insertion on the new side only'] = function()
    local del, add = words.ranges('call(a, b)', 'call(a, b, c)')

    eq(del, {})
    eq(covered('call(a, b, c)', add), { ', c' })
end

T['ranges()']['keeps UTF-8 characters whole'] = function()
    local old, new = 'local grüße = "hallo"', 'local grüße = "tschüß"'
    local del, add = words.ranges(old, new)

    eq(covered(old, del), { 'hallo' })
    eq(covered(new, add), { 'tschüß' })

    local del2, add2 = words.ranges('x = "ä"', 'x = "ö"')
    eq(del2, { { 5, 7 } })
    eq(add2, { { 5, 7 } })
end

T['ranges()']['splits on punctuation'] = function()
    local old, new = 'foo.bar(baz)', 'foo.qux(baz)'
    local del, add = words.ranges(old, new)

    eq(covered(old, del), { 'bar' })
    eq(covered(new, add), { 'qux' })
end

T['ranges()']['merges changes separated only by whitespace'] = function()
    local old, new = 'if a and b then', 'if x or y then'
    local del, add = words.ranges(old, new)

    eq(covered(old, del), { 'a and b' })
    eq(covered(new, add), { 'x or y' })
end

T['ranges()']['marks nothing when only the indentation changed'] = function()
    local del, add = words.ranges('  <Select.Root>', '    <Select.Root>')

    eq(del, {})
    eq(add, {})
end

T['ranges()']['leaves a changed indentation out of a word change'] = function()
    local old, new = '  value={value}', '    value={preset}'
    local del, add = words.ranges(old, new)

    eq(covered(old, del), { 'value' })
    eq(covered(new, add), { 'preset' })
end

T['ranges()']['keeps changes apart across unchanged code'] = function()
    local old, new = 'f(a, b)', 'f(x, y)'
    local del, add = words.ranges(old, new)

    eq(covered(old, del), { 'a', 'b' })
    eq(covered(new, add), { 'x', 'y' })
end

T['ranges()']['skips mostly changed lines'] = function()
    eq({ words.ranges('return foo', 'local bar = baz()') }, {})
    eq({ words.ranges('', 'something') }, {})
end

T['ranges()']['skips lines above the length limit'] = function()
    local long = string.rep('a ', 251)

    eq({ words.ranges(long .. 'x', long .. 'y') }, {})
    eq(#words.ranges('a ' .. 'x', 'a ' .. 'y'), 1)
end

T['annotate()'] = new_set()

T['annotate()']['pairs similar lines and sets their words'] = function()
    local rows = group(
        { 'print("start")', 'local b = 2' },
        { 'local b = 3', 'return b' }
    )

    words.annotate(rows)

    -- linematch pairs 'local b = 2' with 'local b = 3'.
    eq(rows[2].pair, nil)
    eq(rows[3].pair, 4)
    eq(rows[4].pair, 3)
    eq(rows[5].pair, nil)
    eq(covered(rows[3].text, rows[3].words), { '2' })
    eq(covered(rows[4].text, rows[4].words), { '3' })
    eq(rows[2].words, nil)
end

T['annotate()']['pairs without words when the line mostly changed'] = function()
    local rows = group({ 'return foo' }, { 'local bar = baz()' })

    words.annotate(rows)

    eq(rows[2].pair, 3)
    eq(rows[3].pair, 2)
    eq(rows[2].words, nil)
    eq(rows[3].words, nil)
end

T['annotate()']['skips groups above 60 lines'] = function()
    local dels, adds = {}, {}

    for i = 1, 31 do
        table.insert(dels, 'value ' .. i)
        table.insert(adds, 'value ' .. i .. 'x')
    end

    local rows = group(dels, adds)
    words.annotate(rows)
    eq(rows[2].pair, nil)
    eq(rows[2].words, nil)

    table.remove(dels)
    table.remove(adds)
    rows = group(dels, adds)
    words.annotate(rows)
    eq(rows[2].pair, #dels + 2)
end

T['annotate()']['clears stale pairs and stops at context rows'] = function()
    local rows = {
        { kind = 'del', text = 'one', old = 1, pair = 9, words = { { 0, 1 } } },
        { kind = 'context', text = 'two', old = 2, new = 1 },
        { kind = 'add', text = 'one!', new = 2 },
    }

    words.annotate(rows)

    eq(rows[1].pair, nil)
    eq(rows[1].words, nil)
    eq(rows[3].pair, nil)
end

return T
