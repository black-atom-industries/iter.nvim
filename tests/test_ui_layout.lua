local layout = require('iter.ui.layout')
local render = require('iter.ui.render')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

---@param path string
---@param side? string
---@param code? string
---@return IterChange
local function change(path, side, code)
    return { path = path, side = side or 'unstaged', code = code or 'M' }
end

--- A column of plain cells: the item's name padded to the width.
---@param id string
---@param title string
---@param items any[]
---@return IterLayoutColumn
local function column(id, title, items)
    return {
        id = id,
        title = title,
        items = items,
        cell = function(_, item, _, width)
            return item .. string.rep(' ', width - #item)
        end,
    }
end

---@param line IterRenderLine
---@param group string
---@return [integer, integer][]
local function spans(line, group)
    local result = {}

    for _, span in ipairs(line.highlights) do
        if span.group == group then
            table.insert(result, { span.start_col, span.end_col })
        end
    end

    return result
end

T['mode()'] = function()
    eq(layout.mode(80, 80), 'columns')
    eq(layout.mode(120, 80), 'columns')
    eq(layout.mode(79, 80), 'stacked')
end

T['widths()'] = new_set()

T['widths()']['two equal columns split around the separator'] = function()
    eq(layout.widths(80, 2), { 39, 40 })
    eq(layout.widths(81, 2), { 40, 40 })
end

T['widths()']['N columns, the last takes the rest'] = function()
    eq(layout.widths(100, 3), { 32, 32, 34 })
    eq(layout.widths(40, 1), { 40 })
end

T['columns()'] = new_set()

T['columns()']['lays titles and items side by side'] = function()
    local result = layout.columns({
        column('left', 'Left', { 'a', 'b' }),
        column('right', 'Right', { 'c' }),
    }, 21)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.lines),
        {
            ' Left (2) │ Right (1)',
            'a         │c         ',
            'b         │          ',
        }
    )
    eq(result.rows, { {}, { left = 'a', right = 'c' }, { left = 'b' } })
end

T['columns()']['cells and the separator sit at byte columns'] = function()
    local result = layout.columns({
        column('left', 'Left', { 'a' }),
        column('right', 'Right', { 'c' }),
    }, 21)

    eq(result.cells[1], {})
    eq(result.cells[2], {
        left = { first = 0, last = 10 },
        right = { first = 13, last = 23 },
    })
    eq(spans(result.lines[2], 'WinSeparator'), { { 10, 13 } })
    eq(spans(result.lines[1], 'IterDrawerTitle'), { { 0, 9 }, { 13, 23 } })
end

T['columns()']['takes any number of columns'] = function()
    local result = layout.columns({
        column('a', 'A', { 'x' }),
        column('b', 'B', {}),
        column('c', 'C', { 'y', 'z' }),
    }, 20)

    eq(#result.lines, 3)
    eq(result.rows[2], { a = 'x', c = 'y' })
    eq(result.rows[3], { c = 'z' })
    eq(#spans(result.lines[2], 'WinSeparator'), 2)
    eq(vim.fn.strdisplaywidth(result.lines[2].text), 20)
end

T['stacked()'] = new_set()

T['stacked()']['columns one below the other'] = function()
    local result = layout.stacked({
        column('left', 'Left', { 'a' }),
        column('right', 'Right', { 'c', 'd' }),
    }, 12)

    eq(
        vim.tbl_map(function(line)
            return line.text
        end, result.lines),
        {
            ' Left (1)   ',
            'a           ',
            '',
            ' Right (2)  ',
            'c           ',
            'd           ',
        }
    )
    eq(
        result.rows,
        { {}, { left = 'a' }, {}, {}, { right = 'c' }, { right = 'd' } }
    )
    eq(result.cells[5], { right = { first = 0, last = 12 } })
end

T['message()'] = function()
    local result = layout.message('Working tree clean')

    eq(result.lines[1].text, ' Working tree clean')
    eq(spans(result.lines[1], 'IterDrawerHint'), { { 0, 19 } })
    eq(result.rows, { {} })
    eq(result.cells, { {} })
end

T['age()'] = function()
    eq(layout.age(-5), 'now')
    eq(layout.age(59), 'now')
    eq(layout.age(60), '1m')
    eq(layout.age(3599), '59m')
    eq(layout.age(2 * 3600), '2h')
    eq(layout.age(86399), '23h')
    eq(layout.age(3 * 86400), '3d')
    eq(layout.age(7 * 86400), '1w')
    eq(layout.age(5 * 7 * 86400 + 86400), '5w')
    eq(layout.age(364 * 86400), '52w')
    eq(layout.age(800 * 86400), '2y')
end

---@param author string
---@param body string
---@return GitCommit
local function picker_commit(author, body)
    return {
        sha = 'a1b2c3d',
        full_sha = string.rep('a', 40),
        subject = 'fix the thing',
        body = body,
        author = author,
        time = 1767225600,
        unpushed = false,
    }
end

T['commit_short()'] = function()
    local commit = picker_commit('Nik', '')

    eq(layout.commit_short(commit, 40), {
        { commit.sha, 'IterCommitSha' },
        { ' ' .. commit.subject },
    })

    local cut = layout.commit_short(commit, #commit.sha + 6)

    eq(cut[2][1], ' ' .. commit.subject:sub(1, 4) .. '…')
    eq(vim.fn.strdisplaywidth(cut[1][1] .. cut[2][1]), #commit.sha + 6)
    eq(layout.commit_short(commit, #commit.sha)[2][1], ' ')
end

T['line_count()'] = function()
    local function count(added, deleted)
        return layout.line_count({
            path = 'a.txt',
            added = added,
            deleted = deleted,
        })
    end

    eq(count(11, 0), { '+11', 'IterStage' })
    eq(count(0, 4), { '−4', 'IterUnstage' })
    eq(count(60, 11), { '±71', 'IterDrawerHint' })
    eq(count(0, 0), { '+0', 'IterStage' })
    eq(count(nil, nil), { 'bin', 'IterDrawerHint' })
end

T['commit_summary()'] = new_set()

T['commit_summary()']['messages, then the files with their counts'] = function()
    local lines = layout.commit_summary({
        {
            sha = 'a1b2c3d',
            time = 1767225600,
            author = 'Nik',
            message = { 'fix the thing', '', 'why it broke' },
        },
    }, {
        { path = 'a.lua', added = 12, deleted = 3 },
        { path = 'new.lua', orig_path = 'old.lua', added = 0, deleted = 0 },
        { path = 'logo.png' },
    })
    local date = os.date('%Y-%m-%d %H:%M', 1767225600)

    eq(render.text_lines(lines), {
        ' a1b2c3d  ' .. date .. '  Nik',
        '',
        ' fix the thing',
        '',
        ' why it broke',
        '',
        ' 3 files  +12 −3',
        ' +12 −3  a.lua',
        '  +0 −0  old.lua → new.lua',
        '   bin   logo.png',
    })

    local groups = vim.tbl_map(function(h)
        return h.group
    end, lines[1].highlights)

    eq(groups, { 'IterCommitSha', 'IterCommitDate', 'IterCommitAuthor' })
    eq(lines[3].highlights[1].group, 'IterDrawerTitle')
end

T['base_summary()'] = new_set()

---@param subject string
---@param sha string
---@return GitMessage
local function message(subject, sha)
    return {
        sha = sha,
        time = 1767225600,
        author = 'Nik',
        message = { subject },
    }
end

T['base_summary()']['a branch: commits since it, working changes, stats'] = function()
    local lines = layout.base_summary({
        kind = 'branch',
        label = 'main',
        sha = 'b24bd9c1234',
        head = 'feat',
        commits = {
            message('feat(tree): a tree', 'a1b2c3d'),
            message('fix(tree): sort the directories first', 'e4f5a6b'),
        },
        more = 3,
        working = 2,
        untracked = 1,
        stats = {
            { path = 'a.lua', added = 12, deleted = 3 },
            { path = 'b.lua', added = 1, deleted = 0 },
        },
    }, 40)

    eq(render.text_lines(lines), {
        ' since main (b24bd9c)  5 commits · 3 files',
        ' Committed on feat since it left main',
        '',
        ' a1b2c3d feat(tree): a tree',
        ' e4f5a6b fix(tree): sort the directorie…',
        ' … 3 more',
        ' + working changes in 2 files',
        '',
        ' +12 −3  a.lua',
        '  +1 −0  b.lua',
        ' + 1 untracked',
    })
    eq(lines[1].highlights[1].group, 'IterDrawerTitle')
end

T['base_summary()']['without working changes: the count at the right edge, the pull request line'] = function()
    local lines = layout.base_summary({
        kind = 'branch',
        label = 'main',
        sha = 'b24bd9c',
        commits = { message('one', 'a1b2c3d') },
        more = 0,
        working = 0,
        untracked = 0,
        stats = { { path = 'a.lua', added = 1, deleted = 1 } },
    }, 50)

    eq(
        lines[1].text,
        ' since main (b24bd9c)' .. string.rep(' ', 12) .. '1 commit · 1 file'
    )
    eq(lines[2].text, ' Committed since it left main')
    eq(lines[#lines].text, ' What a pull request into main shows.')
end

T['base_summary()']['a commit: its message, then it and every one after it'] = function()
    local date = os.date('%Y-%m-%d %H:%M', 1767225600)
    local lines = layout.base_summary({
        kind = 'commit',
        label = 'e4f5a6b',
        commit = {
            sha = 'e4f5a6b',
            time = 1767225600,
            author = 'Nik',
            message = { 'fix it', '', 'why' },
        },
        commits = { message('later', 'a1b2c3d'), message('fix it', 'e4f5a6b') },
        more = 0,
        working = 0,
        untracked = 0,
        stats = { { path = 'a.lua', added = 2, deleted = 1 } },
    }, 30)

    eq(render.text_lines(lines), {
        ' from e4f5a6b  2 commits · 1 file',
        '',
        ' e4f5a6b  ' .. date .. '  Nik',
        '',
        ' fix it',
        '',
        ' why',
        '',
        ' The review includes this commit and every one after it:',
        ' a1b2c3d later',
        ' e4f5a6b fix it',
        '',
        ' +2 −1  a.lua',
    })
end

T['base_summary()']['working changes: the files against HEAD and the untracked'] = function()
    local lines = layout.base_summary({
        kind = 'working',
        label = 'Working changes',
        commits = {},
        more = 0,
        working = 3,
        untracked = 2,
        stats = { { path = 'a.lua', added = 2, deleted = 1 } },
    }, 25)

    eq(render.text_lines(lines), {
        ' Working changes  3 files',
        '',
        ' +2 −1  a.lua',
        ' + 2 untracked',
    })
end

T['commits()'] = new_set()

local NOW = 1767225600

---@param recent GitRecent
---@param width integer
---@return string[]
local function commit_texts(recent, width)
    return vim.tbl_map(function(line)
        return line.text
    end, layout.commits(recent, width, NOW).lines)
end

---@param upstream? string
---@param ahead integer
---@param behind integer
---@return GitRecent
local function recent(upstream, ahead, behind)
    return {
        key = '',
        upstream = upstream,
        ahead = ahead,
        behind = behind,
        commits = {
            {
                sha = '3f2a9c1',
                subject = 'refactor(drawer): split it',
                time = NOW - 2 * 3600,
                unpushed = ahead > 0,
            },
            {
                sha = '0aa4465',
                subject = 'fix: keep',
                time = NOW - 86400,
                unpushed = false,
            },
        },
    }
end

T['commits()']['title, markers, subjects and right-aligned ages'] = function()
    eq(commit_texts(recent('origin/main', 1, 2), 40), {
        ' Recent commits · ↑1 unpushed · ↓2 behind',
        ' ↑ 3f2a9c1  refactor(drawer): split… 2h ',
        '   0aa4465  fix: keep                1d ',
    })

    local behind = layout.commits(recent('origin/main', 1, 2), 40, NOW)
    eq(spans(behind.lines[1], 'IterBehind'), { { 36, 47 } })

    local result = layout.commits(recent('origin/main', 1, 0), 40, NOW)
    eq(result.rows, {
        {},
        { commit = result.rows[2].commit },
        { commit = result.rows[3].commit },
    })
    eq(result.rows[2].commit.sha, '3f2a9c1')
    eq(result.rows[3].commit.sha, '0aa4465')
    eq(result.cells, { {}, {}, {} })
    eq(spans(result.lines[2], 'IterUnpushed'), { { 1, 4 }, { 5, 12 } })
    eq(spans(result.lines[3], 'IterDrawerHint'), {
        { 3, 10 },
        { 12, 36 },
        { 36, 40 },
    })
end

T['commits()']['without an upstream no markers and no counts'] = function()
    eq(commit_texts(recent(nil, 0, 0), 30), {
        ' Recent commits',
        ' 3f2a9c1  refactor(drawer… 2h ',
        ' 0aa4465  fix: keep        1d ',
    })
end

T['commits()']['empty without commits'] = function()
    local none = recent(nil, 0, 0)
    none.commits = {}

    eq(layout.commits(none, 40, NOW).lines, {})
    eq(layout.commits(nil, 40, NOW).lines, {})
end

T['status_head()'] = new_set()

---@param chunks [string, string][]
---@return string
local function head_text(chunks)
    return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
    end, chunks))
end

T['status_head()']['branch, arrows, upstream and the summary at the right'] = function()
    local chunks = layout.status_head(
        'main',
        recent('origin/main', 1, 2),
        52,
        '2 changes · 1 staged',
        '2 changes'
    )

    eq(
        head_text(chunks),
        'HEAD main  ↑1 ↓2  origin/main  2 changes · 1 staged '
    )
    eq(chunks[2], { 'main', 'IterHead' })
    eq(chunks[3], { '  ↑1', 'IterUnpushed' })
    eq(chunks[4], { ' ↓2', 'IterBehind' })
end

T['status_head()']['sheds the summary, the total, the upstream, then the arrows'] = function()
    local up = recent('origin/main', 1, 2)
    local function at(width)
        return head_text(
            layout.status_head('main', up, width, '2 changes · 1 staged', '2')
        )
    end

    eq(at(36), 'HEAD main  ↑1 ↓2  origin/main     2 ')
    eq(at(30), 'HEAD main  ↑1 ↓2  origin/main')
    eq(at(20), 'HEAD main  ↑1 ↓2')
    eq(at(12), 'HEAD main')
end

T['status_head()']['without a summary, an upstream or a branch'] = function()
    eq(
        head_text(layout.status_head('main', recent('origin/main', 0, 0), 40)),
        'HEAD main  origin/main'
    )
    eq(
        head_text(layout.status_head('main', recent(nil, 0, 0), 40)),
        'HEAD main'
    )
    eq(head_text(layout.status_head('HEAD', nil, 40)), 'HEAD (detached)')
end

T['file_cell()'] = new_set()

T['file_cell()']['code letter and path, padded to the width'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.file_cell(line, change('a.txt'), 4, 12)

    eq(text, ' M a.txt    ')
    eq(spans(line, 'IterUnstage'), { { 5, 6 } })
end

T['file_cell()']['cuts the path from the left'] = function()
    local line = { text = '', highlights = {} }

    eq(
        layout.file_cell(line, change('dir/long.txt', 'staged'), 0, 10),
        ' M …ng.txt'
    )
    eq(spans(line, 'IterStage'), { { 1, 2 } })
end

T['file_cell()']['colors untracked and conflicted codes'] = function()
    local line = { text = '', highlights = {} }

    layout.file_cell(line, change('u', 'unstaged', '?'), 0, 8)
    layout.file_cell(line, change('c', 'unstaged', 'U'), 0, 8)

    eq(spans(line, 'IterUntracked'), { { 1, 2 } })
    eq(spans(line, 'IterConflict'), { { 1, 2 } })
end

---@param width integer
---@param line? IterRenderLine
---@return string
local function rename_cell(width, line)
    local item = change('diff/parser.lua', 'staged', 'R')
    item.orig_path = 'ui/diff/parser.lua'

    return layout.file_cell(
        line or { text = '', highlights = {} },
        item,
        0,
        width
    )
end

T['file_cell()']['a rename reads old → new with a dimmed arrow'] = function()
    local line = { text = '', highlights = {} }

    eq(rename_cell(40, line), ' R ui/diff/parser.lua → diff/parser.lua ')
    eq(spans(line, 'IterDrawerHint'), { { 21, 21 + #' → ' } })
end

T['file_cell()']['a rename cuts the old path first, then drops it'] = function()
    eq(rename_cell(30), ' R …rser.lua → diff/parser.lua')
    eq(rename_cell(23), ' R …a → diff/parser.lua')
    eq(rename_cell(22), ' R diff/parser.lua    ')
    eq(rename_cell(20), ' R diff/parser.lua  ')
    eq(rename_cell(12), ' R …rser.lua')
end

---@param scope string
---@param a table
---@param body? string
---@return IterAnnotation
local function annotation(scope, a, body)
    return { id = 'x', scope = scope, anchor = a, body = body or 'body' }
end

T['annotation_cell()'] = new_set()

T['annotation_cell()']['label padded, then the first line of the body'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.annotation_cell(line, {
        annotation = annotation('file', { path = 'a.lua' }, 'Why\tthis\nmore'),
        outdated = false,
        label = 'a.lua',
    }, 4, 20, 8)

    eq(text, ' a.lua    Why this  ')
    eq(spans(line, 'IterDrawerKey'), { { 5, 10 } })
end

T['annotation_cell()']['cuts the body and a long label with …'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.annotation_cell(line, {
        annotation = annotation('review', {}, 'A long remark here'),
        outdated = false,
        label = 'a_long_name.lua:12',
    }, 0, 16, 6)

    eq(text, ' a_lon… A long …')
    eq(vim.fn.strdisplaywidth(text), 16)
end

T['annotation_cell()']['dims an outdated row'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.annotation_cell(line, {
        annotation = annotation('review', {}, 'gone'),
        outdated = true,
        label = 'a:1',
    }, 0, 12, 3)

    eq(spans(line, 'IterDiffAnnotationOutdated'), { { 0, #text } })
    eq(spans(line, 'IterDrawerKey'), {})
end

T['progress_cell()'] = new_set()

T['progress_cell()']['bar, counts and the changed files'] = function()
    local line = { text = '', highlights = {} }
    local text = layout.progress_cell(
        line,
        { reviewed = 3, changed = 1, total = 8 },
        0,
        32
    )

    eq(text, ' reviewed ▰▰▰▱▱▱▱▱ 3 of 8 · ↻ 1 ')
    eq(spans(line, 'IterReviewed'), { { 10, 19 } })
    eq(
        spans(line, 'IterReviewedChanged'),
        { { #' reviewed ▰▰▰▱▱▱▱▱ 3 of 8', #text - 1 } }
    )
end

T['progress_cell()']['fills by share, full only when all are reviewed'] = function()
    local function bar(reviewed, total)
        local text = layout.progress_cell(
            { text = '', highlights = {} },
            { reviewed = reviewed, changed = 0, total = total },
            0,
            40
        )

        return vim.trim(text):match('[▰▱]+')
    end

    eq(
        bar(0, 0),
        '▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱'
    )
    eq(
        bar(0, 5),
        '▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱'
    )
    eq(
        bar(1, 20),
        '▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱'
    )
    eq(
        bar(19, 20),
        '▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▱'
    )
    eq(
        bar(4, 4),
        '▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰'
    )
end

T['progress_cell()']['drops the word when narrow'] = function()
    local text = layout.progress_cell(
        { text = '', highlights = {} },
        { reviewed = 1, changed = 1, total = 4 },
        0,
        24
    )

    eq(text, ' ▰▰▱▱▱▱▱▱▱ 1 of 4 · ↻ 1 ')
end

T['bottom_hints()'] = function()
    local lines = { render.line('a') }

    layout.bottom_hints(lines, { { { 'q', 'K' }, { ' close' } } }, 4)
    eq(
        vim.tbl_map(function(l)
            return l.text
        end, lines),
        { 'a', '', '', ' q close' }
    )

    local full = { render.line('a'), render.line('b'), render.line('c') }

    layout.bottom_hints(full, { { { 'x' } } }, 3)
    eq(
        vim.tbl_map(function(l)
            return l.text
        end, full),
        { 'a', 'b', 'c', '', ' x' }
    )
end

T['hints()'] = new_set()

local ENTRIES = {
    { action = 'stage', lhs = { 's' } },
    { action = 'open', lhs = { '<CR>' } },
    { action = 'help', lhs = { 'g?' } },
}
local ACTIONS = {
    { 'stage', 'stage' },
    { 'discard', 'discard' },
    { 'open', 'open' },
    { 'help', 'help' },
}

---@param chunks [string, string][]
---@return string
local function joined(chunks)
    return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
    end, chunks))
end

T['hints()']['lists the bound actions in order'] = function()
    local chunks = layout.hints(ENTRIES, ACTIONS, 80)

    eq(joined(chunks), 's stage  <CR> open  g? help')
    eq(chunks[1], { 's', 'IterDrawerKey' })
    eq(chunks[2], { ' stage  ', 'IterDrawerHint' })
end

T['hints()']['drops hints before the last until they fit'] = function()
    eq(joined(layout.hints(ENTRIES, ACTIONS, 20)), 's stage  g? help')
    eq(joined(layout.hints(ENTRIES, ACTIONS, 3)), 'g? help')
end

return T
