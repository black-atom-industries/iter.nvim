local helpers = dofile('tests/helpers.lua')
local git = require('iter.git')
local patch = require('iter.diff.patch')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local repo

--- Three hunks of one modified file, as git prints them.
local THREE = {
    'diff --git a/f.txt b/f.txt',
    'index 1111111..2222222 100644',
    '--- a/f.txt',
    '+++ b/f.txt',
    '@@ -1,4 +1,4 @@',
    '-l1',
    '+l1 changed',
    ' l2',
    ' l3',
    ' l4',
    '@@ -10,7 +10,7 @@ l9',
    ' l10',
    ' l11',
    ' l12',
    '-l13',
    '+l13 changed',
    ' l14',
    ' l15',
    ' l16',
    '@@ -27,4 +27,4 @@ l26',
    ' l27',
    ' l28',
    ' l29',
    '-l30',
    '\\ No newline at end of file',
    '+l30 changed',
    '\\ No newline at end of file',
}

local HEADER = vim.list_slice(THREE, 1, 4)

---@param ... string[]
---@return string[]
local function concat(...)
    local out = {}

    for _, list in ipairs({ ... }) do
        vim.list_extend(out, list)
    end

    return out
end

---@param from integer
---@param to integer
---@return string[]
local function numbered(from, to)
    local lines = {}

    for i = from, to do
        table.insert(lines, 'l' .. i)
    end

    return lines
end

--- Write `content` byte for byte.
---@param path string
---@param content string
local function write_bytes(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local file = assert(io.open(path, 'wb'))
    file:write(content)
    file:close()
end

---@param path string relative to the repo
---@param content string
local function write(path, content)
    write_bytes(vim.fs.joinpath(repo, path), content)
end

---@param args string[]
---@return string
local function run(args)
    return vim.trim(helpers.git(repo, args))
end

--- Blob id git would give `content`, with no filters.
---@param content string
---@return string
local function hash_of(content)
    local path = vim.fn.tempname()
    write_bytes(path, content)
    local hash = run({ 'hash-object', '--no-filters', path })
    vim.fn.delete(path)

    return hash
end

---@param path string
---@return string
local function index_hash(path)
    return run({ 'rev-parse', ':' .. path })
end

--- The byte-exact diff of `change` and the patch of its hunk `index`.
---@param change IterDiffChange
---@param index integer
---@return string[]
local function hunk_patch(change, index)
    local raw, err = git.file_diff_bytes(repo, change)
    eq(err, nil)

    return assert(patch.hunk(assert(raw), index))
end

---@param kind 'stage'|'unstage'
---@param lines string[]
local function apply(kind, lines)
    local ok, err = git.apply_patch(repo, lines, kind, { check = true })
    eq({ ok, err }, { true, '' })
    ok, err = git.apply_patch(repo, lines, kind)
    eq({ ok, err }, { true, '' })
end

---@param lines string[]
---@param eol? string
---@param last_eol? boolean
---@return string
local function join(lines, eol, last_eol)
    eol = eol or '\n'
    local text = table.concat(lines, eol)

    if last_eol ~= false then
        text = text .. eol
    end

    return text
end

local T = new_set()

T['hunk'] = new_set()

T['hunk']['the first hunk keeps the file header'] = function()
    eq(patch.hunk(THREE, 1), concat(HEADER, vim.list_slice(THREE, 5, 10)))
end

T['hunk']['the middle hunk ends before the next one'] = function()
    eq(patch.hunk(THREE, 2), concat(HEADER, vim.list_slice(THREE, 11, 19)))
end

T['hunk']['the last hunk keeps its no-newline markers'] = function()
    eq(patch.hunk(THREE, 3), concat(HEADER, vim.list_slice(THREE, 20, 27)))
end

T['hunk']['a missing hunk gives nil'] = function()
    eq(patch.hunk(THREE, 4), nil)
    eq(patch.hunk(HEADER, 1), nil)
end

T['hunk']['a new file keeps its mode lines'] = function()
    local raw = {
        'diff --git a/n.txt b/n.txt',
        'new file mode 100644',
        'index 0000000..3333333',
        '--- /dev/null',
        '+++ b/n.txt',
        '@@ -0,0 +1,2 @@',
        '+one',
        '+two',
    }
    eq(patch.hunk(raw, 1), raw)
end

T['hunk']['a deleted file keeps its mode lines'] = function()
    local raw = {
        'diff --git a/d.txt b/d.txt',
        'deleted file mode 100644',
        'index 3333333..0000000',
        '--- a/d.txt',
        '+++ /dev/null',
        '@@ -1 +0,0 @@',
        '-gone',
    }
    eq(patch.hunk(raw, 1), raw)
end

T['hunk']['mode change lines are left out'] = function()
    local raw = concat(
        { HEADER[1], 'old mode 100644', 'new mode 100755' },
        vim.list_slice(THREE, 2)
    )
    eq(patch.hunk(raw, 1), concat(HEADER, vim.list_slice(THREE, 5, 10)))
end

T['hunk']['a renamed file names the new path on both sides'] = function()
    local raw = {
        'diff --git a/old.txt b/new.txt',
        'similarity index 91%',
        'rename from old.txt',
        'rename to new.txt',
        'index 1111111..2222222 100644',
        '--- a/old.txt',
        '+++ b/new.txt',
        '@@ -1,2 +1,2 @@',
        '-a',
        '+b',
        ' c',
    }
    eq(patch.hunk(raw, 1), {
        '--- a/new.txt',
        '+++ b/new.txt',
        '@@ -1,2 +1,2 @@',
        '-a',
        '+b',
        ' c',
    })

    raw[7] = '+++ "b/n\\303\\274.txt"'
    eq(patch.hunk(raw, 1)[1], '--- "a/n\\303\\274.txt"')
end

T['hunk']['a hunk of a second file takes that file header'] = function()
    local raw = {
        'diff --git a/old.txt b/old.txt',
        'deleted file mode 100644',
        '--- a/old.txt',
        '+++ /dev/null',
        '@@ -1 +0,0 @@',
        '-x',
        'diff --git a/new.txt b/new.txt',
        'new file mode 100644',
        '--- /dev/null',
        '+++ b/new.txt',
        '@@ -0,0 +1 @@',
        '+y',
    }
    eq(patch.hunk(raw, 1), vim.list_slice(raw, 1, 6))
    eq(patch.hunk(raw, 2), vim.list_slice(raw, 7, 12))
end

T['hunk']['carriage returns stay in the patch'] = function()
    local raw = vim.deepcopy(THREE)
    raw[6], raw[7] = '-l1\r', '+l1 changed\r'
    eq(patch.hunk(raw, 1)[3 + #HEADER], '+l1 changed\r')
end

T['text'] = new_set()

T['text']['drops one carriage return per line like vim.system text mode'] = function()
    local bytes = 'a\r\nb\r\r\nc\n\n'
    local text = vim.system({ 'printf', '%s', bytes }, { text = true })
        :wait().stdout

    eq(patch.text({ 'a\r', 'b\r\r', 'c', '' }), { 'a', 'b\r', 'c', '' })
    eq(
        table.concat(patch.text(vim.split(bytes, '\n', { plain = true })), '\n'),
        text
    )
end

T['apply'] = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({})
        end,
        post_case = function()
            helpers.cleanup(repo)
        end,
    },
})

---@param path string
---@param content string
local function commit(path, content)
    write(path, content)
    run({ 'add', '--', path })
    run({ 'commit', '--quiet', '-m', 'add ' .. path })
end

local UNSTAGED_F = { path = 'f.txt', side = 'unstaged', code = 'M' }

--- `f.txt` with l1..l30 committed and l1, l13, l30 changed in the worktree.
---@param eol string
---@param last_eol boolean
---@return string[] worktree lines
local function three_hunks(eol, last_eol)
    commit('f.txt', join(numbered(1, 30), eol, last_eol))

    local lines = numbered(1, 30)
    lines[1], lines[13], lines[30] = 'l1 x', 'l13 x', 'l30 x'
    write('f.txt', join(lines, eol, last_eol))

    return lines
end

T['apply']['stages the first, middle and last hunk of a CRLF file'] = function()
    local lines = three_hunks('\r\n', true)
    local expected = numbered(1, 30)

    for _, step in ipairs({ { 13, 2 }, { 30, 2 }, { 1, 1 } }) do
        local line, index = step[1], step[2]
        apply('stage', hunk_patch(UNSTAGED_F, index))
        expected[line] = lines[line]
        eq(index_hash('f.txt'), hash_of(join(expected, '\r\n')))
    end

    eq(run({ 'diff', '--stat' }), '')
end

T['apply']['stages the last hunk of a file without a trailing newline'] = function()
    local lines = three_hunks('\n', false)
    local file_patch = hunk_patch(UNSTAGED_F, 3)

    eq(file_patch[#file_patch], '\\ No newline at end of file')
    apply('stage', file_patch)

    local expected = numbered(1, 30)
    expected[30] = lines[30]
    eq(index_hash('f.txt'), hash_of(join(expected, '\n', false)))
end

T['apply']['unstages one hunk out of three'] = function()
    local lines = three_hunks('\n', true)
    run({ 'add', 'f.txt' })

    apply(
        'unstage',
        hunk_patch({ path = 'f.txt', side = 'staged', code = 'M' }, 2)
    )

    local expected = vim.deepcopy(lines)
    expected[13] = 'l13'
    eq(index_hash('f.txt'), hash_of(join(expected)))
    eq(vim.fn.readfile(vim.fs.joinpath(repo, 'f.txt')), lines)
end

T['apply']['an untracked file lands in the index as git add puts it'] = function()
    run({ 'config', 'core.autocrlf', 'true' })
    write('n.txt', 'one\r\ntwo\r\n')
    apply(
        'stage',
        hunk_patch({ path = 'n.txt', side = 'unstaged', code = '?' }, 1)
    )

    eq(index_hash('n.txt'), run({ 'hash-object', '--path=n.txt', 'n.txt' }))
end

T['apply']['a hunk of a file with a mode change leaves the mode alone'] = function()
    local lines = three_hunks('\n', true)
    local path = vim.fs.joinpath(repo, 'f.txt')
    vim.uv.fs_chmod(path, tonumber('755', 8))

    local first = hunk_patch(UNSTAGED_F, 1)
    eq(
        vim.tbl_filter(function(line)
            return line:find('mode', 1, true) ~= nil
        end, first),
        {}
    )
    apply('stage', first)
    eq(run({ 'ls-files', '--stage', 'f.txt' }):sub(1, 6), '100644')

    run({ 'add', 'f.txt' })
    apply(
        'unstage',
        hunk_patch({ path = 'f.txt', side = 'staged', code = 'M' }, 2)
    )

    eq(run({ 'ls-files', '--stage', 'f.txt' }):sub(1, 6), '100755')
    local expected = vim.deepcopy(lines)
    expected[13] = 'l13'
    eq(index_hash('f.txt'), hash_of(join(expected)))
end

T['apply']['stages an intent-to-add file'] = function()
    write('n.txt', 'one\ntwo\n')
    run({ 'add', '--intent-to-add', 'n.txt' })

    apply(
        'stage',
        hunk_patch({ path = 'n.txt', side = 'unstaged', code = 'A' }, 1)
    )

    eq(index_hash('n.txt'), hash_of('one\ntwo\n'))
    eq(run({ 'status', '--porcelain' }), 'A  n.txt')
end

T['apply']['the rendered diff text of a large CRLF file has no CR left'] = function()
    local lines = {}

    for i = 1, 20000 do
        lines[i] = 'line ' .. i
    end

    write('big.txt', join(lines, '\r\n'))
    local change = { path = 'big.txt', side = 'unstaged', code = '?' }
    local source = assert(git.file_diff(repo, change))

    local with_cr = vim.tbl_filter(function(line)
        return line:find('\r', 1, true) ~= nil
    end, source.raw)

    eq(with_cr, {})
    eq(#source.raw, 20006)
    eq(
        vim.deep_equal(
            source.raw,
            patch.text(assert(git.file_diff_bytes(repo, change)))
        ),
        true
    )
end

T['apply']['stages an untracked CRLF file'] = function()
    write('n.txt', 'one\r\ntwo\r\n')
    apply(
        'stage',
        hunk_patch({ path = 'n.txt', side = 'unstaged', code = '?' }, 1)
    )

    eq(index_hash('n.txt'), hash_of('one\r\ntwo\r\n'))
end

T['apply']['stages a deleted file and unstages it again'] = function()
    commit('d.txt', 'gone\n')
    vim.fn.delete(vim.fs.joinpath(repo, 'd.txt'))

    apply(
        'stage',
        hunk_patch({ path = 'd.txt', side = 'unstaged', code = 'D' }, 1)
    )
    eq(run({ 'status', '--porcelain' }), 'D  d.txt')

    apply(
        'unstage',
        hunk_patch({ path = 'd.txt', side = 'staged', code = 'D' }, 1)
    )
    eq(run({ 'status', '--porcelain' }), 'D d.txt')
end

T['apply']['unstages a staged new file'] = function()
    write('n.txt', 'new\n')
    run({ 'add', 'n.txt' })

    apply(
        'unstage',
        hunk_patch({ path = 'n.txt', side = 'staged', code = 'A' }, 1)
    )
    eq(run({ 'status', '--porcelain' }), '?? n.txt')
end

T['apply']['unstaging a hunk of a renamed file keeps the rename'] = function()
    commit('old.txt', join(numbered(1, 30)))
    run({ 'mv', 'old.txt', 'new.txt' })
    local lines = numbered(1, 30)
    lines[3], lines[25] = 'l3 x', 'l25 x'
    write('new.txt', join(lines))
    run({ 'add', 'new.txt' })

    apply(
        'unstage',
        hunk_patch({
            path = 'new.txt',
            orig_path = 'old.txt',
            side = 'staged',
            code = 'R',
        }, 1)
    )

    eq(run({ 'status', '--porcelain' }), 'RM old.txt -> new.txt')
    lines[3] = 'l3'
    eq(index_hash('new.txt'), hash_of(join(lines)))
end

T['apply']['user config cannot change the patch or what it stages'] = function()
    run({ 'config', 'diff.noprefix', 'true' })
    run({ 'config', 'apply.whitespace', 'fix' })
    commit('w.txt', 'a\nb\n')
    write('w.txt', 'a  \nb\n')

    local file_patch =
        hunk_patch({ path = 'w.txt', side = 'unstaged', code = 'M' }, 1)
    eq(file_patch[3], '--- a/w.txt')
    apply('stage', file_patch)

    eq(index_hash('w.txt'), hash_of('a  \nb\n'))
end

T['apply']['a failed check changes nothing'] = function()
    three_hunks('\n', true)
    local file_patch = hunk_patch(UNSTAGED_F, 2)
    commit('f.txt', 'other\n')
    local before = index_hash('f.txt')

    local ok, err = git.apply_patch(repo, file_patch, 'stage', { check = true })
    eq(ok, false)
    eq(err ~= '', true)
    eq(index_hash('f.txt'), before)
end

T['apply']['an empty patch is refused'] = function()
    eq(git.apply_patch(repo, {}, 'stage'), false)
end

T['lines'] = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({})
        end,
        post_case = function()
            helpers.cleanup(repo)
        end,
    },
})

--- A selection of del rows by old line and add rows by new line.
---@param old integer[]
---@param new integer[]
---@return IterLineSelection
local function pick(old, new)
    local selection = { old = {}, new = {} }

    for _, line in ipairs(old) do
        selection.old[line] = true
    end

    for _, line in ipairs(new) do
        selection.new[line] = true
    end

    return selection
end

---@param change IterDiffChange
---@param selection IterLineSelection
---@param kind 'stage'|'unstage'
---@return string[]?
local function lines_patch(change, selection, kind)
    local raw, err = git.file_diff_bytes(repo, change)
    eq(err, nil)

    return patch.lines(assert(raw), selection, kind)
end

local STAGED_F = { path = 'f.txt', side = 'staged', code = 'M' }

---@param patch_lines string[]
---@return string[]
local function hunk_headers(patch_lines)
    return vim.tbl_filter(function(line)
        return vim.startswith(line, '@@')
    end, patch_lines)
end

T['lines']['stages one of three added lines'] = function()
    commit('f.txt', join(numbered(1, 10)))
    local lines = numbered(1, 10)
    table.insert(lines, 6, 'x3')
    table.insert(lines, 6, 'x2')
    table.insert(lines, 6, 'x1')
    write('f.txt', join(lines))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({}, { 7 }), 'stage')))

    local expected = numbered(1, 10)
    table.insert(expected, 6, 'x2')
    eq(run({ 'show', ':f.txt' }), table.concat(expected, '\n'))
    eq(run({ 'diff', '--cached', '--numstat' }), '1\t0\tf.txt')
end

T['lines']['stages one of three deleted lines'] = function()
    commit('f.txt', join(numbered(1, 10)))
    local lines = numbered(1, 10)
    table.remove(lines, 3)
    table.remove(lines, 3)
    table.remove(lines, 3)
    write('f.txt', join(lines))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 4 }, {}), 'stage')))

    local expected = numbered(1, 10)
    table.remove(expected, 4)
    eq(index_hash('f.txt'), hash_of(join(expected)))
end

T['lines']['stages a deleted and an added line of one change'] = function()
    commit('f.txt', join(numbered(1, 10)))
    local lines = numbered(1, 10)
    lines[3] = 'a'
    table.insert(lines, 4, 'b')
    write('f.txt', join(lines))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 3 }, { 4 }), 'stage')))

    local expected = numbered(1, 10)
    expected[3] = 'b'
    eq(index_hash('f.txt'), hash_of(join(expected)))
end

T['lines']['stages rows of two hunks and recounts both headers'] = function()
    three_hunks('\n', true)

    local file_patch =
        assert(lines_patch(UNSTAGED_F, pick({ 13 }, { 30 }), 'stage'))
    eq(hunk_headers(file_patch), {
        '@@ -10,7 +10,6 @@ l9',
        '@@ -27,4 +26,5 @@ l26',
    })
    apply('stage', file_patch)

    local expected = numbered(1, 30)
    table.remove(expected, 13)
    table.insert(expected, 'l30 x')
    eq(index_hash('f.txt'), hash_of(join(expected)))
end

T['lines']['a selection of context rows gives nil'] = function()
    three_hunks('\n', true)

    eq(lines_patch(UNSTAGED_F, pick({ 12 }, { 14 }), 'stage'), nil)
    eq(lines_patch(UNSTAGED_F, pick({}, {}), 'unstage'), nil)
end

T['lines']['stages an added last line after an old one without a newline'] = function()
    local lines = three_hunks('\n', false)

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({}, { 30 }), 'stage')))

    local expected = numbered(1, 30)
    table.insert(expected, lines[30])
    eq(index_hash('f.txt'), hash_of(join(expected, '\n', false)))
end

T['lines']['stages the deletion of a last line without a newline'] = function()
    three_hunks('\n', false)

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 30 }, {}), 'stage')))

    eq(index_hash('f.txt'), hash_of(join(numbered(1, 29))))
end

T['lines']['unstages an added last line without a newline'] = function()
    local lines = three_hunks('\n', false)
    run({ 'add', 'f.txt' })

    apply('unstage', assert(lines_patch(STAGED_F, pick({}, { 30 }), 'unstage')))

    eq(index_hash('f.txt'), hash_of(join(vim.list_slice(lines, 1, 29))))
end

T['lines']['unstages the deletion of a last line without a newline'] = function()
    local lines = three_hunks('\n', false)
    run({ 'add', 'f.txt' })

    apply('unstage', assert(lines_patch(STAGED_F, pick({ 30 }, {}), 'unstage')))

    local expected = vim.deepcopy(lines)
    table.insert(expected, 30, 'l30')
    eq(index_hash('f.txt'), hash_of(join(expected, '\n', false)))
end

T['lines']['stages rows of a CRLF file byte for byte'] = function()
    local lines = three_hunks('\r\n', true)

    apply(
        'stage',
        assert(lines_patch(UNSTAGED_F, pick({ 1 }, { 13, 30 }), 'stage'))
    )

    local expected = numbered(2, 30)
    table.insert(expected, 13, lines[13])
    table.insert(expected, lines[30])
    eq(index_hash('f.txt'), hash_of(join(expected, '\r\n')))
end

T['lines']['unstages one of three added lines'] = function()
    commit('f.txt', join(numbered(1, 10)))
    local lines = numbered(1, 10)
    table.insert(lines, 6, 'x3')
    table.insert(lines, 6, 'x2')
    table.insert(lines, 6, 'x1')
    write('f.txt', join(lines))
    run({ 'add', 'f.txt' })

    apply('unstage', assert(lines_patch(STAGED_F, pick({}, { 7 }), 'unstage')))

    local expected = vim.deepcopy(lines)
    table.remove(expected, 7)
    eq(index_hash('f.txt'), hash_of(join(expected)))
    eq(vim.fn.readfile(vim.fs.joinpath(repo, 'f.txt')), lines)
end

T['lines']['unstages one of three deleted lines'] = function()
    commit('f.txt', join(numbered(1, 10)))
    local lines = numbered(1, 10)
    table.remove(lines, 3)
    table.remove(lines, 3)
    table.remove(lines, 3)
    write('f.txt', join(lines))
    run({ 'add', 'f.txt' })

    apply('unstage', assert(lines_patch(STAGED_F, pick({ 4 }, {}), 'unstage')))

    eq(
        index_hash('f.txt'),
        hash_of(join({ 'l1', 'l2', 'l4', 'l6', 'l7', 'l8', 'l9', 'l10' }))
    )
end

T['lines']['unstages rows of two hunks and recounts both headers'] = function()
    local lines = three_hunks('\n', true)
    run({ 'add', 'f.txt' })

    local file_patch =
        assert(lines_patch(STAGED_F, pick({ 13 }, { 30 }), 'unstage'))
    eq(hunk_headers(file_patch), {
        '@@ -10,8 +10,7 @@ l9',
        '@@ -28,3 +27,4 @@ l26',
    })
    apply('unstage', file_patch)

    local expected = vim.list_slice(lines, 1, 29)
    table.insert(expected, 13, 'l13')
    eq(index_hash('f.txt'), hash_of(join(expected)))
end

T['lines']['stages part of an untracked file'] = function()
    write('n.txt', 'a\nb\nc\n')

    apply(
        'stage',
        assert(
            lines_patch(
                { path = 'n.txt', side = 'unstaged', code = '?' },
                pick({}, { 1, 3 }),
                'stage'
            )
        )
    )

    eq(index_hash('n.txt'), hash_of('a\nc\n'))
    eq(run({ 'status', '--porcelain', 'n.txt' }), 'AM n.txt')
end

T['lines']['unstages part of a staged new file and keeps it added'] = function()
    write('n.txt', 'a\nb\nc\n')
    run({ 'add', 'n.txt' })

    apply(
        'unstage',
        assert(
            lines_patch(
                { path = 'n.txt', side = 'staged', code = 'A' },
                pick({}, { 2 }),
                'unstage'
            )
        )
    )

    eq(index_hash('n.txt'), hash_of('a\nc\n'))
    eq(run({ 'status', '--porcelain', 'n.txt' }), 'AM n.txt')
end

T['lines']['stages part of a deleted file and keeps it in the index'] = function()
    commit('d.txt', 'a\nb\nc\n')
    vim.fn.delete(vim.fs.joinpath(repo, 'd.txt'))

    apply(
        'stage',
        assert(
            lines_patch(
                { path = 'd.txt', side = 'unstaged', code = 'D' },
                pick({ 2 }, {}),
                'stage'
            )
        )
    )

    eq(index_hash('d.txt'), hash_of('a\nc\n'))
    eq(run({ 'status', '--porcelain', 'd.txt' }), 'MD d.txt')
end

T['lines pairs'] = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({})
        end,
        post_case = function()
            helpers.cleanup(repo)
        end,
    },
})

--- Commit l1..l8, then write `new` as the worktree file; staged too with
--- `stage_all`.
---@param new string[]
---@param stage_all? boolean
local function change_group(new, stage_all)
    commit('f.txt', join(numbered(1, 8)))
    write('f.txt', join(new))

    if stage_all then
        run({ 'add', 'f.txt' })
    end
end

---@return string[]
local function index_lines()
    return vim.split(run({ 'show', ':f.txt' }), '\n')
end

--- l1..l8 with the lines at `at` replaced by `lines`.
---@param at integer first line replaced
---@param count integer lines replaced
---@param lines string[]
---@return string[]
local function replaced(at, count, lines)
    local out = numbered(1, 8)

    for _ = 1, count do
        table.remove(out, at)
    end

    for i = #lines, 1, -1 do
        table.insert(out, at, lines[i])
    end

    return out
end

T['lines pairs']['stages the first of two pairs in place'] = function()
    change_group(replaced(3, 2, { 'l3 changed', 'l4 changed' }))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 3 }, { 3 }), 'stage')))

    eq(index_lines(), replaced(3, 1, { 'l3 changed' }))
end

T['lines pairs']['stages the second of two pairs in place'] = function()
    change_group(replaced(3, 2, { 'l3 changed', 'l4 changed' }))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 4 }, { 4 }), 'stage')))

    eq(index_lines(), replaced(4, 1, { 'l4 changed' }))
end

T['lines pairs']['unstages one of two pairs in place'] = function()
    change_group(replaced(3, 2, { 'l3 changed', 'l4 changed' }), true)

    apply(
        'unstage',
        assert(lines_patch(STAGED_F, pick({ 4 }, { 4 }), 'unstage'))
    )

    eq(index_lines(), replaced(3, 1, { 'l3 changed' }))
end

T['lines pairs']['stages the pair of three deleted lines and one added'] = function()
    change_group(replaced(3, 3, { 'l4 changed' }))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 4 }, { 3 }), 'stage')))

    eq(index_lines(), replaced(4, 1, { 'l4 changed' }))
end

T['lines pairs']['stages the pair of one deleted line and three added'] = function()
    change_group(replaced(3, 1, { 'x', 'l3 changed', 'y' }))

    apply('stage', assert(lines_patch(UNSTAGED_F, pick({ 3 }, { 4 }), 'stage')))

    eq(index_lines(), replaced(3, 1, { 'l3 changed' }))
end

T['lines pairs']['unstages the pair of three deleted lines and one added'] = function()
    change_group(replaced(3, 3, { 'l4 changed' }), true)

    apply(
        'unstage',
        assert(lines_patch(STAGED_F, pick({ 4 }, { 3 }), 'unstage'))
    )

    eq(index_lines(), { 'l1', 'l2', 'l4', 'l6', 'l7', 'l8' })
end

T['lines pairs']['unstages the pair of one deleted line and three added'] = function()
    change_group(replaced(3, 1, { 'x', 'l3 changed', 'y' }), true)

    apply(
        'unstage',
        assert(lines_patch(STAGED_F, pick({ 3 }, { 4 }), 'unstage'))
    )

    eq(index_lines(), replaced(3, 1, { 'x', 'l3', 'y' }))
end

return T
