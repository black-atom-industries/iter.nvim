local tree = require('iter.ui.tree')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@param path string
---@param side? IterSide
---@param extra? table
---@return IterChange
local function change(path, side, extra)
    return vim.tbl_extend(
        'force',
        { path = path, side = side or 'unstaged', code = 'M' },
        extra or {}
    )
end

--- Each row as its indent and name, `lua/iter/` or `  ui/` or `    a.lua`.
---@param rows IterTreeRow[]
---@return string[]
local function outline(rows)
    return vim.tbl_map(function(row)
        return string.rep('  ', row.depth) .. row.node.name
    end, rows)
end

---@param files IterTreeFile[]
---@return string[]
local function paths(files)
    return vim.tbl_map(function(file)
        return file.path
    end, files)
end

---@param lines IterRenderLine[]
---@return string[]
local function texts(lines)
    return vim.tbl_map(function(line)
        return line.text
    end, lines)
end

---@return IterTreeDecor
local function no_decor()
    return {}
end

local T = new_set()

T['build'] = new_set()

T['build']['puts directories first, each level by name'] = function()
    local root = tree.build({
        change('z.txt'),
        change('b/one.txt'),
        change('a.txt'),
        change('a/two.txt'),
        change('B.txt'),
    })

    eq(outline(tree.rows(root, {})), {
        'a/',
        '  two.txt',
        'b/',
        '  one.txt',
        'B.txt',
        'a.txt',
        'z.txt',
    })
end

T['build']['compacts a chain of directories that hold one directory'] = function()
    local root = tree.build({
        change('lua/iter/ui/tree.lua'),
        change('lua/iter/git.lua'),
        change('tests/test_tree.lua'),
    })
    local rows = tree.rows(root, {})

    eq(outline(rows), {
        'lua/iter/',
        '  ui/',
        '    tree.lua',
        '  git.lua',
        'tests/',
        '  test_tree.lua',
    })
    eq(rows[1].node.path, 'lua/iter/')
    eq(rows[2].node.path, 'lua/iter/ui/')
end

T['build']['keeps a directory that also holds files'] = function()
    local root = tree.build({
        change('lua/init.lua'),
        change('lua/iter/git.lua'),
    })

    eq(outline(tree.rows(root, {})), {
        'lua/',
        '  iter/',
        '    git.lua',
        '  init.lua',
    })
end

T['build']['makes a nested repository a leaf'] = function()
    local root = tree.build({
        change('vendor/sub/', 'unstaged', { code = '?', dir = true }),
        change('vendor/x.txt'),
    })
    local rows = tree.rows(root, {})

    eq(outline(rows), { 'vendor/', '  sub/', '  x.txt' })
    eq(rows[2].node.kind, 'file')
    eq(rows[2].node.path, 'vendor/sub/')
end

T['build']['keeps a file and a directory of the same name apart'] = function()
    local root = tree.build({
        change('foo', 'unstaged', { code = 'D' }),
        change('foo/bar.txt', 'unstaged', { code = '?' }),
    })

    eq(outline(tree.rows(root, {})), { 'foo/', '  bar.txt', 'foo' })
end

T['build']['puts a rename under its new path'] = function()
    local root = tree.build({
        change('new/b.lua', 'staged', { code = 'R', orig_path = 'old/a.lua' }),
    })
    local files = tree.files(root)

    eq(paths(files), { 'new/b.lua' })
    eq(files[1].code, 'R')
    eq(
        texts(tree.lines(tree.rows(root, {}), 34, {}, no_decor)),
        { '   ▾ new/', '     R b.lua ← old/a.lua' }
    )
end

T['build']['makes a path on both sides one partly staged file'] = function()
    local unstaged = change('a.lua', 'unstaged')
    local staged = change('a.lua', 'staged', { code = 'A' })
    local files = tree.files(tree.build({ unstaged, staged }))

    eq(#files, 1)
    eq(files[1].stage, 'partly')
    eq(files[1].items, { unstaged, staged })
    eq(files[1].items[1].side, 'unstaged')
    eq(files[1].code, 'M')
end

T['build']['tells staged from unstaged'] = function()
    local files = tree.files(tree.build({
        change('a.lua', 'staged'),
        change('b.lua', 'unstaged'),
    }))

    eq(files[1].stage, 'staged')
    eq(files[2].stage, 'unstaged')
end

T['build']['gives base and commit sides no stage'] = function()
    local files = tree.files(tree.build({
        change('a.lua', 'base'),
        change('b.lua', 'commit'),
    }))

    eq(files[1].stage, nil)
    eq(files[2].stage, nil)
end

T['files'] = new_set()

T['files']['walks depth first, collapsed directories included'] = function()
    local root = tree.build({
        change('README.md'),
        change('tests/test_tree.lua'),
        change('lua/iter/ui/tree.lua'),
        change('lua/iter/git.lua'),
    })

    eq(paths(tree.files(root)), {
        'lua/iter/ui/tree.lua',
        'lua/iter/git.lua',
        'tests/test_tree.lua',
        'README.md',
    })
end

T['rows'] = new_set()

T['rows']['hides what a collapsed directory holds'] = function()
    local root = tree.build({
        change('lua/iter/ui/tree.lua'),
        change('lua/iter/git.lua'),
        change('tests/test_tree.lua'),
    })

    eq(outline(tree.rows(root, { ['lua/iter/ui/'] = true })), {
        'lua/iter/',
        '  ui/',
        '  git.lua',
        'tests/',
        '  test_tree.lua',
    })
    eq(outline(tree.rows(root, { ['lua/iter/'] = true })), {
        'lua/iter/',
        'tests/',
        '  test_tree.lua',
    })
end

T['rows']['ignores a collapsed directory that no longer exists'] = function()
    local root = tree.build({ change('a/b.txt') })

    eq(outline(tree.rows(root, { ['gone/'] = true })), { 'a/', '  b.txt' })
end

T['rows']['keeps a collapse when the chain compacts'] = function()
    local collapsed = { ['lua/'] = true }
    local before = tree.build({
        change('lua/init.lua'),
        change('lua/iter/git.lua'),
    })

    eq(outline(tree.rows(before, collapsed)), { 'lua/' })

    local after = tree.build({ change('lua/iter/git.lua') })
    local rows = tree.rows(after, collapsed)

    eq(outline(rows), { 'lua/iter/' })
    eq(texts(tree.lines(rows, 20, collapsed, no_decor)), { '   ▸ lua/iter/' })
    eq(outline(tree.rows(after, { ['lua/iter/'] = true })), { 'lua/iter/' })
end

T['lines'] = new_set()

T['lines']['draws directories, files, icons and right chunks'] = function()
    local root = tree.build({
        change('lua/iter/drawer.lua'),
        change('lua/iter/drawer.lua', 'staged'),
        change('README.md', 'unstaged', { code = '?' }),
    })
    local lines = tree.lines(tree.rows(root, {}), 27, {}, function(file)
        if file.stage == 'partly' then
            return {
                icon = { '◐', 'IterUnstage' },
                right = { { '✎1', 'IterDrawerCount' }, { ' ✓', 'X' } },
            }
        end

        return { icon = { '○', 'IterDrawerHint' } }
    end)

    eq(texts(lines), {
        '   ▾ lua/iter/',
        '     ◐ M drawer.lua   ✎1 ✓',
        '   ○ ? README.md',
    })

    local dir_glyph = #'   '
    eq(lines[1].highlights, {
        {
            group = 'IterDrawerHint',
            start_col = dir_glyph,
            end_col = #lines[1].text,
        },
    })

    local icon = #'     '
    local letter = icon + #'◐ '
    local right = #'     ◐ M drawer.lua   '
    eq(lines[2].highlights, {
        { group = 'IterUnstage', start_col = icon, end_col = icon + #'◐' },
        {
            group = 'IterDiffHeaderRule',
            start_col = letter,
            end_col = letter + 1,
        },
        {
            group = 'IterDrawerCount',
            start_col = right,
            end_col = right + #'✎1',
        },
        { group = 'X', start_col = right + #'✎1', end_col = #lines[2].text },
    })
    eq(lines[3].highlights[2].group, 'IterUntracked')
end

T['lines']['shows a collapsed directory with ▸'] = function()
    local root = tree.build({ change('a/b.txt') })
    local collapsed = { ['a/'] = true }

    eq(
        texts(tree.lines(tree.rows(root, collapsed), 20, collapsed, no_decor)),
        { '   ▸ a/' }
    )
end

T['lines']['colours a conflict letter'] = function()
    local root = tree.build({ change('a.txt', 'unstaged', { code = 'U' }) })
    local lines = tree.lines(tree.rows(root, {}), 20, {}, no_decor)

    eq(lines[1].highlights[1].group, 'IterConflict')
end

T['lines']['sheds the rename before cutting the name'] = function()
    local root = tree.build({
        change('long_name.lua', 'staged', {
            code = 'R',
            orig_path = 'somewhere/else.lua',
        }),
    })
    local rows = tree.rows(root, {})

    eq(texts(tree.lines(rows, 20, {}, no_decor)), { '   R long_name.lua' })
    eq(texts(tree.lines(rows, 13, {}, no_decor)), { '   R …ame.lua' })
end

T['lines']['cuts the name before the right chunks'] = function()
    local root = tree.build({ change('a_very_long_file_name.lua') })
    local lines = tree.lines(tree.rows(root, {}), 21, {}, function()
        return { right = { { '✎12', 'IterDrawerCount' } } }
    end)

    eq(texts(lines), { '   M …e_name.lua ✎12' })
    eq(vim.fn.strdisplaywidth(lines[1].text), 20)
end

T['lines']['cuts multibyte names by cells'] = function()
    local root = tree.build({ change('docs/übersicht_änderungen.md') })
    local lines = tree.lines(tree.rows(root, {}), 17, {}, no_decor)

    eq(texts(lines), { '   ▾ docs/', '     M …rungen.md' })
end

T['lines']['keeps deep rows within a narrow width'] = function()
    local root = tree.build({
        change('a/1/b/2/c/3/d/deep_file.lua'),
        change('a/1/b/2/c/3/d/e/x.lua'),
        change('a/1/b/2/c/3/d/e/f/y.lua'),
        change('a/1/b/2/c/3/d/e/f/g/z.lua'),
        change('a/top.lua'),
    })

    for _, line in
        ipairs(tree.lines(tree.rows(root, {}), 10, {}, function()
            return { icon = { '●', 'IterStage' }, right = { { '✓', 'X' } } }
        end))
    do
        local width = vim.fn.strdisplaywidth(line.text)

        eq(width <= 10, true)

        for _, span in ipairs(line.highlights) do
            eq(span.end_col <= #line.text, true)
        end
    end
end

T['lines']['shows the rename of a partly staged file'] = function()
    local root = tree.build({
        change('new.lua', 'unstaged'),
        change('new.lua', 'staged', { code = 'R', orig_path = 'old.lua' }),
    })
    local lines = tree.lines(tree.rows(root, {}), 34, {}, no_decor)

    eq(texts(lines), { '   R new.lua ← old.lua' })
    eq(lines[1].highlights[1].group, 'IterDiffHeaderRule')
end

T['lines']['keeps the right chunks when a deep row has no room'] = function()
    local root = tree.build({
        change('a/1.txt'),
        change('a/b/2.txt'),
        change('a/b/c/3.txt'),
        change('a/b/c/d/4.txt'),
        change('a/b/c/d/deep_name.lua'),
    })
    local rows = tree.rows(root, {})

    eq(rows[6].node.path, 'a/b/c/d/deep_name.lua')
    eq(rows[6].depth, 4)

    local lines = tree.lines(rows, 10, {}, function()
        return { icon = { '●', 'IterStage' }, right = { { '✓', 'X' } } }
    end)

    eq(lines[6].text, '  ● M … ✓')
    eq(lines[6].highlights[#lines[6].highlights].group, 'X')
end

T['lines']['cuts a long directory name'] = function()
    local root = tree.build({ change('a_very_long_directory/x.txt') })

    eq(
        texts(tree.lines(tree.rows(root, {}), 13, {}, no_decor)),
        { '   ▾ …ectory/', '     M x.txt' }
    )
end

T['ancestors'] = new_set()

T['ancestors']['lists the directories that hold a path'] = function()
    eq(
        tree.ancestors('lua/iter/ui/tree.lua'),
        { 'lua/', 'lua/iter/', 'lua/iter/ui/' }
    )
    eq(tree.ancestors('README.md'), {})
    eq(tree.ancestors('vendor/sub/'), { 'vendor/' })
end

T['stage_icon()'] = function()
    eq(tree.stage_icon('staged'), { '●', 'IterStage' })
    eq(tree.stage_icon('partly'), { '◐', 'IterUnstage' })
    eq(tree.stage_icon('unstaged'), { '○', 'IterDrawerHint' })
    eq(tree.stage_icon(nil), nil)
end

return T
