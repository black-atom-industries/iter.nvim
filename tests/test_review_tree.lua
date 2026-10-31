local render = require('iter.ui.render')
local review_tree = require('iter.ui.review_tree')
local tree = require('iter.ui.tree')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type IterReviewTree?
local page
---@type integer?
local origin

---@param path string
---@param side? IterSide
---@return IterChange
local function change(path, side)
    return { path = path, side = side or 'unstaged', code = 'M' }
end

--- A tree page of `items` with a one-line header and one hint line; each
--- selected node lands in `selected`.
---@param items IterChange[]
---@param selected? (IterTreeDir|IterTreeFile)[]
---@return IterReviewTree
local function new_page(items, selected)
    page = review_tree.new({
        keys = { help = { '?' } },
        handlers = { help = function() end },
        header = function()
            return { render.line(' Title') }
        end,
        decorate = function()
            return {}
        end,
        hints = function()
            return { { { 'help', 'help' } } }
        end,
        on_select = function(node)
            table.insert(selected or {}, node)
        end,
    })
    page.root = tree.build(items)

    return page
end

---@return string[]
local function lines()
    return vim.tbl_map(function(line)
        return (line:gsub('%s+$', ''))
    end, vim.api.nvim_buf_get_lines(assert(page).buf, 0, -1, false))
end

local T = new_set({
    hooks = {
        pre_case = function()
            origin = vim.api.nvim_get_current_buf()
        end,
        post_case = function()
            if origin ~= nil and vim.api.nvim_buf_is_valid(origin) then
                vim.api.nvim_win_set_buf(0, origin)
            end

            if page ~= nil then
                page:close()
                page = nil
            end
        end,
    },
})

T['render'] = new_set()

T['render']['the header, a blank line, the rows, then the hints on the last lines'] = function()
    local p = new_page({ change('a.txt'), change('lua/x.lua') })

    p:render(30, 9)

    eq(lines(), {
        ' Title',
        '',
        '  ▾ lua/',
        '    M x.lua',
        '  M a.txt',
        '',
        '',
        '',
        ' ? help',
    })
    eq(vim.tbl_count(p.items), 3)
    eq(p.items[3].node.path, 'lua/')
    eq(p.items[5].node.path, 'a.txt')
end

T['render']['hints follow the rows when the page fits exactly'] = function()
    local p = new_page({ change('a.txt') })

    p:render(30, 4)

    eq(lines(), { ' Title', '', '  M a.txt', ' ? help' })
end

T['render']['a blank line keeps the hints apart when the rows overflow'] = function()
    local p = new_page({ change('a.txt'), change('b.txt'), change('c.txt') })

    p:render(30, 4)

    eq(lines(), {
        ' Title',
        '',
        '  M a.txt',
        '  M b.txt',
        '  M c.txt',
        '',
        ' ? help',
    })
end

T['render']['an empty tree reads Working tree clean'] = function()
    local p = new_page({})

    p:render(30, 5)

    eq(lines()[3], ' Working tree clean')
    eq(vim.tbl_count(p.items), 0)
end

T['rows'] = new_set()

T['rows']['line_of and nearest find rows'] = function()
    local p = new_page({ change('a.txt'), change('lua/x.lua') })

    p:render(30, 9)

    eq(p:line_of('lua/x.lua'), 4)
    eq(p:line_of('missing'), nil)
    eq(p:nearest(1, 1), 3)
    eq(p:nearest(9, -1), 5)
    eq(p:nearest(9, 1), 5)
end

T['rows']['on_cursor snaps to a row and tells which node it is on'] = function()
    local selected = {}
    local p = new_page({ change('a.txt'), change('lua/x.lua') }, selected)

    p:render(30, 9)
    vim.api.nvim_win_set_buf(0, p.buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    p:on_cursor(1, 1)

    eq(vim.api.nvim_win_get_cursor(0)[1], 3)
    eq(p.lnum, 3)
    eq(selected[1].path, 'lua/')
    eq(p:node().kind, 'dir')
    eq(p:file(), nil)

    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    p:on_cursor(8, 3)

    eq(p.lnum, 5)
    eq(p:file().path, 'a.txt')
end

T['rows']['toggle closes a compacted directory, open_to opens it'] = function()
    local p = new_page({ change('lua/iter/x.lua'), change('b.txt') })

    p:render(30, 9)

    local dir = p.items[3].node --[[@as IterTreeDir]]

    eq(dir.name, 'lua/iter/')
    p:toggle(dir)
    p:render(30, 9)
    eq(lines()[3], '  ▸ lua/iter/')
    eq(p:line_of('lua/iter/x.lua'), nil)

    p:open_to('lua/iter/x.lua')
    p:render(30, 9)
    eq(p:line_of('lua/iter/x.lua'), 4)

    p:toggle(dir)
    p:toggle(dir)
    p:render(30, 9)
    eq(lines()[3], '  ▾ lua/iter/')
end

T['rows']['parent is the directory above, nil at the top'] = function()
    local p = new_page({ change('lua/x.lua'), change('b.txt') })

    p:render(30, 9)

    local file = p.items[4].node

    eq(p:parent(file).path, 'lua/')
    eq(p:parent(p.items[5].node), nil)
    eq(p:parent(p.items[3].node), nil)
end

T['rows']['a partly staged path is one row'] = function()
    local p = new_page({ change('a.txt'), change('a.txt', 'staged') })

    p:render(30, 6)

    eq(vim.tbl_count(p.items), 1)
    eq(#p.items[3].node.items, 2)
    eq(p.items[3].node.stage, 'partly')
end

return T
