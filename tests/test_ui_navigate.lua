local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local FILE = {
    '  indented line',
    'plain words here',
    'third line',
    'fourth line, more words',
    'fifth line',
}

---@param scope string
---@param start_line integer
---@param end_line integer
---@param extra? table
---@return table
local function line_note(scope, start_line, end_line, extra)
    return {
        scope = scope,
        body = 'note',
        outdated = false,
        anchor = vim.tbl_extend('force', {
            path = 'm.txt',
            side = 'new',
            start_line = start_line,
            end_line = end_line,
            lines = vim.list_slice(FILE, start_line, end_line),
        }, extra or {}),
    }
end

---@param note table
local function seed(note)
    child.lua(
        [[require('iter.store').put_annotation(vim.fn.getcwd(), ...)]],
        { note }
    )
end

---@return integer[]
local function cursor()
    return child.api.nvim_win_get_cursor(0)
end

---@return string[]
local function notes()
    return vim.tbl_map(function(note)
        return note[1]
    end, child.lua_get('_G.notes'))
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['m.txt'] = FILE })
            helpers.start_child(child, repo)
            child.lua([[require('iter').setup()]])
            child.lua([[
                _G.notes = {}
                vim.notify = function(msg, level)
                    table.insert(_G.notes, { msg, level })
                end
            ]])
            child.cmd('edit m.txt')
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

--- A line note, a passage in line 2, a second passage in line 2, a range, a
--- passage in line 4, in store order that is not line order.
local function seed_notes()
    seed(line_note('range', 3, 3))
    seed(
        line_note(
            'line',
            2,
            2,
            { start_col = 6, end_col = 11, quote = 'words' }
        )
    )
    seed(line_note('line', 1, 1))
    seed(
        line_note('line', 2, 2, { start_col = 0, end_col = 5, quote = 'plain' })
    )
    seed(
        line_note(
            'line',
            4,
            4,
            { start_col = 13, end_col = 23, quote = 'more words' }
        )
    )
end

T['next_annotation()'] = new_set()

T['next_annotation()']['steps through line and passage notes in order'] = function()
    seed_notes()
    child.api.nvim_win_set_cursor(0, { 1, 2 })

    local stops = {}

    for _ = 1, 5 do
        child.lua([[require('iter').next_annotation()]])
        table.insert(stops, cursor())
    end

    eq(stops, {
        { 2, 0 },
        { 2, 6 },
        { 3, 0 },
        { 4, 13 },
        { 1, 2 },
    })
end

T['next_annotation()']['lands on the first non-blank of a line note'] = function()
    seed(line_note('line', 1, 1))
    child.api.nvim_win_set_cursor(0, { 5, 0 })
    child.lua([[require('iter').next_annotation()]])

    eq(cursor(), { 1, 2 })
end

T['next_annotation()']['moves on from a note under the cursor'] = function()
    seed_notes()
    child.api.nvim_win_set_cursor(0, { 2, 3 })
    child.lua([[require('iter').next_annotation()]])

    eq(cursor(), { 2, 6 })
end

T['next_annotation()']['skips notes whose text is gone, file and old-side notes'] = function()
    seed(line_note('line', 3, 3))
    seed({
        scope = 'line',
        body = 'gone',
        outdated = false,
        anchor = {
            path = 'm.txt',
            side = 'new',
            start_line = 5,
            end_line = 5,
            lines = { 'removed text' },
        },
    })
    seed({
        scope = 'file',
        body = 'file',
        outdated = false,
        anchor = { path = 'm.txt', side = 'new' },
    })
    seed({
        scope = 'line',
        body = 'old',
        outdated = false,
        anchor = {
            path = 'm.txt',
            side = 'old',
            base = 'HEAD',
            start_line = 2,
            end_line = 2,
            lines = { 'plain words here' },
        },
    })
    child.api.nvim_win_set_cursor(0, { 1, 0 })

    child.lua([[require('iter').next_annotation()]])
    eq(cursor(), { 3, 0 })

    child.lua([[require('iter').next_annotation()]])
    eq(cursor(), { 3, 0 })
    eq(notes(), {})
end

T['next_annotation()']['warns without annotations in the buffer'] = function()
    child.api.nvim_win_set_cursor(0, { 2, 3 })
    child.lua([[require('iter').next_annotation()]])

    eq(cursor(), { 2, 3 })
    eq(notes(), { '[iter] No annotations in this buffer' })
end

T['prev_annotation()'] = new_set()

T['prev_annotation()']['steps back through the notes and wraps'] = function()
    seed_notes()
    child.api.nvim_win_set_cursor(0, { 5, 0 })

    local stops = {}

    for _ = 1, 6 do
        child.lua([[require('iter').prev_annotation()]])
        table.insert(stops, cursor())
    end

    eq(stops, {
        { 4, 13 },
        { 3, 0 },
        { 2, 6 },
        { 2, 0 },
        { 1, 2 },
        { 4, 13 },
    })
end

T['prev_annotation()']['warns without annotations in the buffer'] = function()
    child.lua([[require('iter').prev_annotation()]])

    eq(notes(), { '[iter] No annotations in this buffer' })
end

T['next_annotation()']['follows a passage whose paragraph was rewritten'] = function()
    seed(
        line_note(
            'line',
            2,
            2,
            { start_col = 6, end_col = 11, quote = 'words' }
        )
    )
    child.api.nvim_buf_set_lines(0, 1, 2, false, { 'a few plain words here' })
    child.api.nvim_win_set_cursor(0, { 1, 0 })
    child.lua([[require('iter').next_annotation()]])

    eq(cursor(), { 2, 12 })
end

return T
