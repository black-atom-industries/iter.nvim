local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local LONG = string.rep('word ', 12)
local STATUSCOLUMN = "%!v:lua.require'iter'.statuscolumn()"

---@param start_line integer
---@param end_line integer
---@param lines string[]
local function annotate(start_line, end_line, lines)
    child.lua([[require('iter.store').put_annotation(vim.fn.getcwd(), ...)]], {
        {
            scope = 'line',
            body = 'note',
            outdated = false,
            anchor = {
                path = 'm.txt',
                side = 'new',
                start_line = start_line,
                end_line = end_line,
                lines = lines,
            },
        },
    })
end

--- The first `width` cells of each screen row.
---@param width integer
---@return string[]
local function gutter(width)
    return vim.tbl_map(function(row)
        return table.concat(vim.list_slice(row, 1, width))
    end, child.get_screenshot().text)
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({
                ['m.txt'] = { 'one', LONG, 'three', LONG, 'five' },
            })
            helpers.start_child(child, repo, { lines = 14, columns = 30 })
            annotate(2, 2, { LONG })
            child.lua([[require('iter').setup()]])
            child.o.number = true
            child.o.statuscolumn = STATUSCOLUMN
            child.cmd('edit m.txt')
            child.cmd('redraw!')
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['draws the bar on every row of an annotated wrapped line only'] = function()
    eq(gutter(6), {
        '    1 ',
        '▍   2 ',
        '▍     ',
        '▍     ',
        '▍     ',
        '    3 ',
        '    4 ',
        '      ',
        '      ',
        '    5 ',
        '~     ',
        '~     ',
        '~     ',
        '      ',
    })
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'statuscolumn-wrapped')
end

T['continues the bar down the note row'] = function()
    eq(gutter(6)[5], '▍     ')
end

T['follows the numbering options'] = function()
    child.o.relativenumber = true
    child.cmd('redraw!')

    eq(gutter(6)[2], '▍   1 ')
    eq(gutter(6)[3], '▍     ')
end

T['moves with the lines above when text is inserted'] = function()
    child.api.nvim_buf_set_lines(0, 0, 0, false, { 'new' })
    child.cmd('redraw!')

    local rows = gutter(6)
    eq(rows[2], '    2 ')
    eq(rows[3], '▍   3 ')
    eq(rows[4], '▍     ')
end

T['draws the bars of a range on all its wrapped rows'] = function()
    annotate(4, 5, { LONG, 'five' })
    child.cmd('edit!')
    child.cmd('redraw!')

    local rows = gutter(6)
    eq(rows[8], '▍     ')
    eq(rows[9], '▍     ')
end

T['draws no bar without a sign column'] = function()
    child.o.signcolumn = 'no'
    child.cmd('redraw!')

    eq(gutter(4)[3], '    ')
end

--- Screen rows of the unannotated lines, with iter's column and with the
--- default one.
---@param options table<string, any>
---@return string[] iter
---@return string[] default
local function compare(options)
    for name, value in pairs(options) do
        child.o[name] = value
    end

    child.o.statuscolumn = STATUSCOLUMN
    child.cmd('redraw!')
    local mine = vim.list_slice(gutter(10), 6, 10)
    child.o.statuscolumn = ''
    child.cmd('redraw!')

    return mine, vim.list_slice(gutter(10), 6, 10)
end

local OPTION_SETS = {
    ['no numbers'] = { number = false },
    ['relativenumber'] = { number = false, relativenumber = true },
    ['number and relativenumber'] = { relativenumber = true },
    ['signcolumn no'] = { signcolumn = 'no' },
    ['signcolumn yes:2'] = { signcolumn = 'yes:2' },
    ['signcolumn auto'] = { signcolumn = 'auto' },
    ['foldcolumn'] = { foldcolumn = '2' },
}

for name, options in pairs(OPTION_SETS) do
    T['renders the default column with ' .. name] = function()
        local mine, default = compare(options)

        eq(mine, default)
    end
end

T['iter windows render without the column'] = function()
    child.lua([[
        vim.fn.writefile({ 'one', 'two' }, 'n.txt')
        vim.fn.writefile({ 'one', 'two', 'x' }, 'm.txt')
    ]])
    child.cmd('Iter annotate')
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        [[require('iter').current_review ~= nil and require('iter').current_review.view:is_shown()]]
    )

    local offending = child.lua_get([[(function()
        local result = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.api.nvim_buf_get_name(buf):find('^iter://') then
                if vim.wo[win].statuscolumn:find('annotations', 1, true)
                    or vim.wo[win].statuscolumn:find("require'iter'.statuscolumn", 1, true) then
                    table.insert(result, vim.api.nvim_buf_get_name(buf))
                end
            end
        end
        return result
    end)()]])

    eq(offending, {})
end

T['draws the note bar in the sign column under the sign'] = function()
    child.o.number = false
    child.cmd('vsplit')
    child.cmd('redraw!')

    helpers.expect_screenshot(child, 'statuscolumn-note-bar')
end

return T
