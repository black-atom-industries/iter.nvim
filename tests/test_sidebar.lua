local sidebar = require('iter.ui.sidebar')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@param scope string
---@param body string
---@param anchor table
---@param extra? table
---@return IterAnnotationItem
local function item(scope, body, anchor, extra)
    return vim.tbl_extend('force', {
        annotation = {
            id = body,
            scope = scope,
            body = body,
            anchor = anchor,
        },
        index = 1,
        outdated = false,
    }, extra or {})
end

---@return IterAnnotationGroup[]
local function groups()
    return {
        {
            path = 'a.md',
            items = {
                item('file', 'Whole file', { path = 'a.md', side = 'new' }),
                item('line', 'Second\nline of it', {
                    path = 'a.md',
                    side = 'new',
                    start_line = 4,
                    end_line = 4,
                }, { start = 6 }),
                item('range', 'Range', {
                    path = 'a.md',
                    side = 'new',
                    start_line = 8,
                    end_line = 10,
                }, { outdated = true }),
                item('line', 'Gone', {
                    path = 'a.md',
                    side = 'old',
                    start_line = 12,
                    end_line = 12,
                }),
            },
        },
        {
            items = {
                item('review', 'Overall', { side = 'new' }),
            },
        },
    }
end

---@param lines IterRenderLine[]
---@return string[]
local function texts(lines)
    return vim.tbl_map(function(line)
        return (line.text:gsub('%s+$', ''))
    end, lines)
end

local T = new_set()

T['lines()'] = new_set()

T['lines()']['gives the title, one header per group and one line per note'] = function()
    local lines = sidebar.lines(groups(), { width = 30 })

    eq(texts(lines), {
        'Annotations (5) · 1 outdated',
        '',
        'a.md                         4',
        '  file   Whole file',
        '  6      Second',
        '  8–10   Range',
        '  12 old Gone',
        '',
        'review                       1',
        '  note   Overall',
    })
end

T['lines()']['maps note and header lines to their rows'] = function()
    local given = groups()
    local _, rows = sidebar.lines(given, { width = 30 })

    eq(rows[1], nil)
    eq(rows[3].item, nil)
    eq(rows[3].group, given[1])
    eq(rows[3].path, 'a.md')
    eq(rows[5].item, given[1].items[2])
    eq(rows[9].path, nil)
    eq(rows[9].group, given[2])
    eq(rows[10].item, given[2].items[1])
end

T['lines()']['highlights the title, headers, counts and outdated notes'] = function()
    local lines = sidebar.lines(groups(), { width = 30 })

    eq(lines[1].highlights, {
        { group = 'IterDrawerTitle', start_col = 0, end_col = 15 },
        { group = 'IterDrawerHint', start_col = 15, end_col = 29 },
    })
    eq(lines[3].highlights, {
        { group = 'IterDrawerTitle', start_col = 0, end_col = 4 },
        { group = 'IterDrawerCount', start_col = 29, end_col = 30 },
    })
    eq(lines[4].highlights, {
        { group = 'IterDrawerKey', start_col = 2, end_col = 6 },
    })
    eq(lines[6].highlights, {
        {
            group = 'IterDiffAnnotationOutdated',
            start_col = 1,
            end_col = #lines[6].text,
        },
    })
end

T['lines()']['cuts a long note with an ellipsis'] = function()
    local lines = sidebar.lines({
        {
            path = 'a.md',
            items = { item('file', string.rep('word ', 10), { path = 'a.md' }) },
        },
    }, { width = 20 })

    eq(lines[4].text, '  file word word wo…')
end

T['lines()']['puts the hints on the last rows of the height'] = function()
    local lines = sidebar.lines(groups(), {
        width = 40,
        height = 14,
        hints = {
            { { '<CR>', 'jump' }, { 'y', 'yank' } },
            { { 'd', 'delete' } },
        },
    })

    eq(#lines, 14)
    eq(texts(lines)[13], '<CR> jump  y yank')
    eq(texts(lines)[14], 'd delete')
    eq(lines[13].highlights, {
        { group = 'IterDrawerKey', start_col = 0, end_col = 4 },
        { group = 'IterDrawerHint', start_col = 5, end_col = 9 },
        { group = 'IterDrawerKey', start_col = 11, end_col = 12 },
        { group = 'IterDrawerHint', start_col = 13, end_col = 17 },
    })
end

T['lines()']['keeps the hints below a list taller than the height'] = function()
    local lines = sidebar.lines(groups(), {
        width = 40,
        height = 5,
        hints = { { { 'q', 'close' } } },
    })

    eq(lines[#lines].text, 'q close')
    eq(lines[#lines - 1].text, '')
    eq(texts(lines)[#lines - 2], '  note   Overall')
end

T['lines()']['an empty list says so'] = function()
    local lines = sidebar.lines({}, { width = 30 })

    eq(texts(lines), { 'Annotations (0)', '', 'No annotations' })
end

return T
