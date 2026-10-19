local helpers = dofile('tests/helpers.lua')
local git = require('iter.git')
local model = require('iter.diff.model')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local repo

---@param path string
---@param lines string[]
local function write(path, lines)
    helpers.write_file(vim.fs.joinpath(repo, path), lines)
end

---@param from integer
---@param to integer
---@return string[]
local function numbered(from, to)
    local lines = {}

    for i = from, to do
        table.insert(lines, 'line ' .. i)
    end

    return lines
end

---@param change { path: string, orig_path?: string, side: IterSide, code: string }
---@return IterFileDiff
local function load(change)
    local source, err = git.file_diff(repo, change)
    eq(err, nil)

    return model.build(change, assert(source))
end

--- Compact rows: `{ kind, text, old, new }`, plus the gap for gap rows.
---@param file IterFileDiff
---@return table[]
local function compact(file)
    return vim.tbl_map(function(row)
        local out = { row.kind, row.text, row.old, row.new }

        if row.gap ~= nil then
            out[5] = { row.gap.old, row.gap.new, row.gap.count }
        end

        return out
    end, file.rows)
end

---@param file IterFileDiff
---@param kind string
---@return integer[]
local function indexes_of(file, kind)
    local found = {}

    for index, row in ipairs(file.rows) do
        if row.kind == kind then
            table.insert(found, index)
        end
    end

    return found
end

local T = new_set({
    hooks = {
        post_case = function()
            helpers.cleanup(repo)
        end,
    },
})

T['build()'] = new_set()

T['build()']['modified file keeps comment-like lines as code'] = function()
    local original = numbered(1, 20)
    original[10] = '-- comment'
    repo = helpers.create_repo({ ['a.lua'] = original })

    local changed = vim.deepcopy(original)
    changed[10] = '++ added'
    write('a.lua', changed)

    local file = load({ path = 'a.lua', side = 'unstaged', code = 'M' })

    eq(compact(file), {
        { 'header', 'a.lua' },
        { 'gap', '', nil, nil, { 1, 1, 6 } },
        { 'hunk', '@@ -7,7 +7,7 @@ line 6' },
        { 'context', 'line 7', 7, 7 },
        { 'context', 'line 8', 8, 8 },
        { 'context', 'line 9', 9, 9 },
        { 'del', '-- comment', 10, nil },
        { 'add', '++ added', nil, 10 },
        { 'context', 'line 11', 11, 11 },
        { 'context', 'line 12', 12, 12 },
        { 'context', 'line 13', 13, 13 },
        { 'gap', '', nil, nil, { 14, 14, 7 } },
    })
    eq(file.rows[3].hunk, 1)
    eq(file.rows[7].hunk, 1)
    eq(#file.hunks, 1)
    eq(file.stat, { add = 1, del = 1 })
    eq(file.binary, false)
    eq(file.old_lines, original)
    eq(file.new_lines, changed)
end

T['build()']['staged new file has an empty old side'] = function()
    repo = helpers.create_repo({ ['keep.txt'] = { 'keep' } })
    write('new.txt', { 'a', 'b' })
    helpers.git(repo, { 'add', 'new.txt' })

    local file = load({ path = 'new.txt', side = 'staged', code = 'A' })

    eq(compact(file), {
        { 'header', 'new.txt' },
        { 'hunk', '@@ -0,0 +1,2 @@' },
        { 'add', 'a', nil, 1 },
        { 'add', 'b', nil, 2 },
    })
    eq(file.old_lines, {})
    eq(file.new_lines, { 'a', 'b' })
end

T['build()']['deleted file has an empty new side'] = function()
    repo = helpers.create_repo({ ['gone.txt'] = { 'x', 'y' } })
    vim.fn.delete(vim.fs.joinpath(repo, 'gone.txt'))

    local file = load({ path = 'gone.txt', side = 'unstaged', code = 'D' })

    eq(compact(file), {
        { 'header', 'gone.txt' },
        { 'hunk', '@@ -1,2 +0,0 @@' },
        { 'del', 'x', 1, nil },
        { 'del', 'y', 2, nil },
    })
    eq(file.old_lines, { 'x', 'y' })
    eq(file.new_lines, {})
    eq(file.stat, { add = 0, del = 2 })
end

T['build()']['untracked file is all additions'] = function()
    repo = helpers.create_repo({ ['keep.txt'] = { 'keep' } })
    write('u.txt', { 'q' })

    local file = load({ path = 'u.txt', side = 'unstaged', code = '?' })

    eq(compact(file), {
        { 'header', 'u.txt' },
        { 'hunk', '@@ -0,0 +1 @@' },
        { 'add', 'q', nil, 1 },
    })
    eq(file.old_lines, {})
    eq(file.new_lines, { 'q' })
end

T['build()']['staged rename reads the old side from the old path'] = function()
    local original = numbered(1, 10)
    repo = helpers.create_repo({ ['old.txt'] = original })
    helpers.git(repo, { 'mv', 'old.txt', 'new.txt' })

    local changed = vim.deepcopy(original)
    changed[10] = 'line ten'
    write('new.txt', changed)
    helpers.git(repo, { 'add', 'new.txt' })

    local file = load({
        path = 'new.txt',
        orig_path = 'old.txt',
        side = 'staged',
        code = 'R',
    })

    eq(compact(file), {
        { 'header', 'old.txt → new.txt' },
        { 'gap', '', nil, nil, { 1, 1, 6 } },
        { 'hunk', '@@ -7,4 +7,4 @@ line 6' },
        { 'context', 'line 7', 7, 7 },
        { 'context', 'line 8', 8, 8 },
        { 'context', 'line 9', 9, 9 },
        { 'del', 'line 10', 10, nil },
        { 'add', 'line ten', nil, 10 },
    })
    eq(file.old_lines, original)
    eq(file.new_lines, changed)
end

T['build()']['pure rename hides the whole file in one gap'] = function()
    repo = helpers.create_repo({ ['old.txt'] = { 'a', 'b', 'c' } })
    helpers.git(repo, { 'mv', 'old.txt', 'new.txt' })

    local file = load({
        path = 'new.txt',
        orig_path = 'old.txt',
        side = 'staged',
        code = 'R',
    })

    eq(compact(file), {
        { 'header', 'old.txt → new.txt' },
        { 'gap', '', nil, nil, { 1, 1, 3 } },
    })
    eq(#file.hunks, 0)
end

T['build()']['a mode change is kept, with or without content changes'] = function()
    repo = helpers.create_repo({ ['run.sh'] = { 'echo' }, ['f.txt'] = { 'a' } })
    vim.uv.fs_chmod(vim.fs.joinpath(repo, 'run.sh'), tonumber('755', 8))
    vim.uv.fs_chmod(vim.fs.joinpath(repo, 'f.txt'), tonumber('755', 8))
    write('f.txt', { 'b' })

    local only = load({ path = 'run.sh', side = 'unstaged', code = 'M' })
    eq(only.mode, { old = '100644', new = '100755' })
    eq(only.stat, { add = 0, del = 0 })
    eq(#only.hunks, 0)

    local both = load({ path = 'f.txt', side = 'unstaged', code = 'M' })
    eq(both.mode, { old = '100644', new = '100755' })
    eq(#both.hunks, 1)

    write('f.txt', { 'a' })
    vim.uv.fs_chmod(vim.fs.joinpath(repo, 'f.txt'), tonumber('644', 8))
    write('run.sh', { 'echo', 'more' })
    vim.uv.fs_chmod(vim.fs.joinpath(repo, 'run.sh'), tonumber('644', 8))
    eq(load({ path = 'run.sh', side = 'unstaged', code = 'M' }).mode, nil)
end

T['build()']['binary file has a header and no blobs'] = function()
    repo = helpers.create_repo({ ['keep.txt'] = { 'keep' } })

    local handle = assert(io.open(vim.fs.joinpath(repo, 'bin.dat'), 'wb'))
    handle:write('\0\1\2binary\0')
    handle:close()

    local file = load({ path = 'bin.dat', side = 'unstaged', code = '?' })

    eq(file.binary, true)
    eq(compact(file), { { 'header', 'bin.dat' } })
    eq(file.old_lines, nil)
    eq(file.new_lines, nil)
    eq(file.stat, { add = 0, del = 0 })
end

T['build()']['blobs that differ from the diff give hunk-only rows'] = function()
    repo = helpers.create_repo({ ['f.txt'] = numbered(1, 20) })
    helpers.git(repo, { 'config', 'filter.upper.clean', 'tr a-z A-Z' })
    write('.gitattributes', { 'f.txt filter=upper' })

    local changed = numbered(1, 20)
    changed[10] = 'line ten'
    write('f.txt', changed)

    local file = load({ path = 'f.txt', side = 'unstaged', code = 'M' })

    eq(file.old_lines, nil)
    eq(file.new_lines, nil)
    eq(indexes_of(file, 'gap'), {})
    eq(file.rows[1].kind, 'header')
    eq(file.rows[2].kind, 'hunk')
    eq(file.rows[3].text, 'line 1')
    eq(file.rows[3].old, 1)
end

T['build()']['doctored blobs give hunk-only rows'] = function()
    local raw = {
        'diff --git a/f.txt b/f.txt',
        '--- a/f.txt',
        '+++ b/f.txt',
        '@@ -2,3 +2,3 @@',
        ' b',
        '-c',
        '+C',
        ' d',
    }
    local change = { path = 'f.txt', side = 'unstaged', code = 'M' }

    local good = model.build(change, {
        raw = raw,
        old_lines = { 'a', 'b', 'c', 'd', 'e' },
        new_lines = { 'a', 'b', 'C', 'd', 'e' },
        binary = false,
    })
    eq(indexes_of(good, 'gap'), { 2, 8 })

    local bad = model.build(change, {
        raw = raw,
        old_lines = { 'a', 'b', 'c', 'd', 'e' },
        new_lines = { 'a', 'b', 'X', 'd', 'e' },
        binary = false,
    })
    eq(compact(bad), {
        { 'header', 'f.txt' },
        { 'hunk', '@@ -2,3 +2,3 @@' },
        { 'context', 'b', 2, 2 },
        { 'del', 'c', 3, nil },
        { 'add', 'C', nil, 3 },
        { 'context', 'd', 4, 4 },
    })
    eq(bad.old_lines, nil)
    eq(bad.new_lines, nil)
end

T['build()']['two hunks get a gap between them'] = function()
    repo = helpers.create_repo({ ['f.txt'] = numbered(1, 40) })
    local changed = numbered(1, 40)
    changed[5] = 'five'
    changed[30] = 'thirty'
    write('f.txt', changed)

    local file = load({ path = 'f.txt', side = 'unstaged', code = 'M' })
    local gaps = indexes_of(file, 'gap')

    eq(#file.hunks, 2)
    eq(
        vim.tbl_map(function(index)
            local gap = file.rows[index].gap
            return { gap.old, gap.new, gap.count }
        end, gaps),
        { { 1, 1, 1 }, { 9, 9, 18 }, { 34, 34, 7 } }
    )
end

---@param path string
---@param content string
local function write_raw(path, content)
    local handle = assert(io.open(vim.fs.joinpath(repo, path), 'wb'))
    handle:write(content)
    handle:close()
end

---@param file IterFileDiff
---@return integer[][]
local function gaps_of(file)
    return vim.tbl_map(function(index)
        local gap = file.rows[index].gap
        return { gap.old, gap.new, gap.count }
    end, indexes_of(file, 'gap'))
end

T['build()']['CRLF file keeps its gaps and plain text'] = function()
    repo = helpers.create_repo({ ['keep.txt'] = { 'keep' } })
    write_raw('crlf.txt', table.concat(numbered(1, 20), '\r\n') .. '\r\n')
    helpers.git(repo, { 'add', 'crlf.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'crlf' })

    local changed = numbered(1, 20)
    changed[10] = 'line ten'
    write_raw('crlf.txt', table.concat(changed, '\r\n') .. '\r\n')

    local file = load({ path = 'crlf.txt', side = 'unstaged', code = 'M' })

    eq(gaps_of(file), { { 1, 1, 6 }, { 14, 14, 7 } })
    eq(file.rows[7], {
        kind = 'del',
        text = 'line 10',
        old = 10,
        hunk = 1,
    })
    eq(file.rows[8].text, 'line ten')
end

T['build()']['no newline at the end of the old side'] = function()
    repo = helpers.create_repo({ ['keep.txt'] = { 'keep' } })
    write_raw('f.txt', 'a\nb')
    helpers.git(repo, { 'add', 'f.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'f' })
    write_raw('f.txt', 'a\nb\nc\n')

    local file = load({ path = 'f.txt', side = 'unstaged', code = 'M' })

    eq(compact(file), {
        { 'header', 'f.txt' },
        { 'hunk', '@@ -1,2 +1,3 @@' },
        { 'context', 'a', 1, 1 },
        { 'del', 'b', 2, nil },
        { 'add', 'b', nil, 2 },
        { 'add', 'c', nil, 3 },
    })
    eq(file.old_lines, { 'a', 'b' })
    eq(file.new_lines, { 'a', 'b', 'c' })
end

T['build()']['no newline at the end of the new side'] = function()
    repo = helpers.create_repo({ ['f.txt'] = { 'a', 'b' } })
    write_raw('f.txt', 'a\nb\nc')

    local file = load({ path = 'f.txt', side = 'unstaged', code = 'M' })

    eq(compact(file), {
        { 'header', 'f.txt' },
        { 'hunk', '@@ -1,2 +1,3 @@' },
        { 'context', 'a', 1, 1 },
        { 'context', 'b', 2, 2 },
        { 'add', 'c', nil, 3 },
    })
    eq(file.new_lines, { 'a', 'b', 'c' })
end

T['build()']['empty untracked file has a header only'] = function()
    repo = helpers.create_repo({ ['keep.txt'] = { 'keep' } })
    write_raw('empty.txt', '')

    local file = load({ path = 'empty.txt', side = 'unstaged', code = '?' })

    eq(compact(file), { { 'header', 'empty.txt' } })
    eq(file.new_lines, {})
end

T['build()']['emptied file deletes every line'] = function()
    repo = helpers.create_repo({ ['f.txt'] = { 'x', 'y' } })
    write_raw('f.txt', '')

    local file = load({ path = 'f.txt', side = 'unstaged', code = 'M' })

    eq(compact(file), {
        { 'header', 'f.txt' },
        { 'hunk', '@@ -1,2 +0,0 @@' },
        { 'del', 'x', 1, nil },
        { 'del', 'y', 2, nil },
    })
    eq(file.new_lines, {})
end

T['build()']['rename with edits shifts the new numbers'] = function()
    local original = numbered(1, 30)
    repo = helpers.create_repo({ ['old.txt'] = original })
    helpers.git(repo, { 'mv', 'old.txt', 'new.txt' })

    local changed = vim.deepcopy(original)
    changed[20] = 'line twenty'
    table.insert(changed, 6, 'inserted b')
    table.insert(changed, 6, 'inserted a')
    write('new.txt', changed)
    helpers.git(repo, { 'add', 'new.txt' })

    local file = load({
        path = 'new.txt',
        orig_path = 'old.txt',
        side = 'staged',
        code = 'R',
    })

    eq(file.rows[1].text, 'old.txt → new.txt')
    eq(#file.hunks, 2)
    eq(gaps_of(file), { { 1, 1, 2 }, { 9, 11, 8 }, { 24, 26, 7 } })

    local changes = vim.tbl_map(
        function(row)
            return { row.kind, row.text, row.old, row.new }
        end,
        vim.tbl_filter(function(row)
            return row.kind == 'add' or row.kind == 'del'
        end, file.rows)
    )
    eq(changes, {
        { 'add', 'inserted a', nil, 6 },
        { 'add', 'inserted b', nil, 7 },
        { 'del', 'line 20', 20, nil },
        { 'add', 'line twenty', nil, 22 },
    })
    eq(file.stat, { add = 3, del = 1 })
end

T['expand()'] = new_set()

---@param count integer lines in the file
---@param changed_line integer
---@return IterFileDiff
local function single_change(count, changed_line)
    repo = helpers.create_repo({ ['f.txt'] = numbered(1, count) })
    local changed = numbered(1, count)
    changed[changed_line] = 'changed'
    write('f.txt', changed)

    return load({ path = 'f.txt', side = 'unstaged', code = 'M' })
end

T['expand()']['reveals a trailing gap in batches from the top'] = function()
    -- Change on line 1: hunk covers 1..4, trailing gap 5..54 (50 lines).
    local file = single_change(54, 1)
    local index = indexes_of(file, 'gap')[1]
    eq(file.rows[index].gap, { old = 5, new = 5, count = 50 })

    eq(model.expand(file, index, 20), 20)
    eq(file.rows[index].kind, 'context')
    eq(file.rows[index].text, 'line 5')
    eq({ file.rows[index].old, file.rows[index].new }, { 5, 5 })
    eq(file.rows[index + 19].text, 'line 24')

    local gap_index = index + 20
    eq(file.rows[gap_index].gap, { old = 25, new = 25, count = 30 })

    eq(model.expand(file, gap_index, 20), 20)
    eq(file.rows[gap_index + 20].gap, { old = 45, new = 45, count = 10 })

    -- Few lines remain: the rest comes in one go and the gap row goes.
    eq(model.expand(file, gap_index + 20, 20), 10)
    eq(indexes_of(file, 'gap'), {})
    eq(file.rows[#file.rows].text, 'line 54')
    eq(file.rows[#file.rows].new, 54)
end

T['expand()']['reveals a leading gap from the bottom'] = function()
    -- Change on line 30: leading gap 1..26.
    local file = single_change(30, 30)
    local index = indexes_of(file, 'gap')[1]
    eq(file.rows[index].gap, { old = 1, new = 1, count = 26 })

    eq(model.expand(file, index, 20), 20)
    eq(file.rows[index].gap, { old = 1, new = 1, count = 6 })
    eq(file.rows[index + 1].text, 'line 7')
    eq(file.rows[index + 20].text, 'line 26')
    eq(file.rows[index + 21].kind, 'hunk')

    eq(model.expand(file, index, 20), 6)
    eq(file.rows[index].text, 'line 1')
    eq(indexes_of(file, 'gap'), {})
end

T['expand()']['returns 0 on rows that are not gaps'] = function()
    local file = single_change(30, 30)
    local before = #file.rows

    eq(model.expand(file, 1, 20), 0)
    eq(#file.rows, before)
end

T['old_line_to_new_line()'] = new_set()

T['old_line_to_new_line()']['translates through hunk deltas'] = function()
    local file = model.build(
        { path = 'file.txt', side = 'staged', code = 'M' },
        {
            raw = {
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
            },
            binary = false,
        }
    )

    -- Hunk 1 adds one line, hunk 2 adds one more.
    eq(model.old_line_to_new_line(file, 1), 1)
    -- A deleted line maps to the nearest surviving line after it.
    eq(model.old_line_to_new_line(file, 2), 2)
    eq(model.old_line_to_new_line(file, 5), 6)
    eq(model.old_line_to_new_line(file, 11), 12)
    eq(model.old_line_to_new_line(file, 12), 14)
end

T['new_line()'] = new_set()

T['new_line()']['maps every row kind to a new line'] = function()
    local file = model.build(
        { path = 'file.txt', side = 'unstaged', code = 'M' },
        {
            raw = {
                'diff --git a/file.txt b/file.txt',
                '--- a/file.txt',
                '+++ b/file.txt',
                '@@ -1,3 +1,3 @@',
                ' ctx1',
                '-rm1',
                '+add1',
                ' ctx2',
                '@@ -10,2 +10,3 @@',
                ' ctx3',
                '+add2',
                ' ctx4',
            },
            binary = false,
        }
    )
    local lines = {}

    for lnum, row in ipairs(file.rows) do
        table.insert(lines, { row.kind, model.new_line(file, lnum) })
    end

    eq(lines, {
        { 'header', 1 },
        { 'hunk', 1 },
        { 'context', 1 },
        { 'del', 2 },
        { 'add', 2 },
        { 'context', 3 },
        { 'hunk', 10 },
        { 'context', 10 },
        { 'add', 11 },
        { 'context', 12 },
    })
end

T['new_line()']['a gap maps to its first hidden line'] = function()
    -- Change on line 1: hunk covers 1..4, trailing gap from line 5.
    local file = single_change(54, 1)

    eq(model.new_line(file, indexes_of(file, 'gap')[1]), 5)
end

T['pairs()'] = new_set()

--- Rows of one hunk: the del texts, then the add texts.
---@param dels string[]
---@param adds string[]
---@return IterDiffRow[]
local function change(dels, adds)
    local rows = { { kind = 'hunk', text = '@@', hunk = 1 } }

    for i, text in ipairs(dels) do
        table.insert(rows, { kind = 'del', text = text, old = i, hunk = 1 })
    end

    for i, text in ipairs(adds) do
        table.insert(rows, { kind = 'add', text = text, new = i, hunk = 1 })
    end

    return rows
end

T['pairs()']['pairs similar lines of a change group'] = function()
    local rows = change(
        { 'print("start")', 'local b = 2' },
        { 'local b = 3', 'return b' }
    )

    eq(model.pairs(rows), { { del = 3, add = 4, similar = true } })
end

T['pairs()']['pairs within each group, never across context'] = function()
    local rows = {
        { kind = 'del', text = 'one', old = 1 },
        { kind = 'add', text = 'one!', new = 1 },
        { kind = 'context', text = 'two', old = 2, new = 2 },
        { kind = 'del', text = 'three', old = 3 },
        { kind = 'add', text = 'three!', new = 3 },
        { kind = 'add', text = 'four', new = 4 },
    }

    eq(model.pairs(rows), {
        { del = 1, add = 2, similar = true },
        { del = 4, add = 5, similar = true },
    })
end

T['pairs()']['a group of only deleted or added lines has no pairs'] = function()
    eq(model.pairs(change({ 'a', 'b' }, {})), {})
    eq(model.pairs(change({}, { 'a', 'b' })), {})
end

T['pairs()']['pairs a group above 60 lines one by one'] = function()
    local dels, adds = {}, {}

    for i = 1, 31 do
        table.insert(dels, 'value ' .. i)
    end

    for i = 1, 33 do
        table.insert(adds, 'other ' .. i)
    end

    local pairs = model.pairs(change(dels, adds))

    eq(#pairs, 31)
    eq(pairs[1], { del = 2, add = 33, similar = false })
    eq(pairs[31], { del = 32, add = 63, similar = false })
end

return T
