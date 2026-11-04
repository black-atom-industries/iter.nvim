local Surface = require('iter.graphics.surface')
local document = require('iter.diff.document')
local ribbons = require('iter.diff.ribbons')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

--- A document from a row spec: `c` context, `d` del, `a` add, in file order.
---@param spec string
---@return IterDocument
local function doc_of(spec)
    local rows = { { kind = 'header', text = 'f' } }
    local line = 0

    for kind in spec:gmatch('.') do
        line = line + 1

        local name = ({ c = 'context', d = 'del', a = 'add' })[kind]

        table.insert(rows, {
            kind = name,
            text = name .. line,
            old = kind ~= 'a' and line or nil,
            new = kind ~= 'd' and line or nil,
        })
    end

    ---@type any
    local file = { side = 'unstaged', path = 'f', rows = rows }

    return document.build({ { file = file } }, 'split')
end

local function plain_top(lnum)
    return lnum - 1
end

local PALETTE = {
    add = { 0, 200, 0 },
    del = { 200, 0, 0 },
    add_active = { 0, 250, 0 },
    del_active = { 250, 0, 0 },
}

local T = new_set()

T['chunks()'] = new_set()

T['chunks()']['groups runs of changed lines per side'] = function()
    local chunks = ribbons.chunks(doc_of('caaac'))

    eq(#chunks, 1)
    eq(chunks[1].first, 3)
    eq(chunks[1].last, 5)
    eq(chunks[1].old_first, nil)
    eq(chunks[1].new_first, 3)
    eq(chunks[1].new_last, 5)
end

T['chunks()']['context separates chunks'] = function()
    local chunks = ribbons.chunks(doc_of('cdcac'))

    eq(#chunks, 2)
    eq(chunks[1].new_first, nil)
    eq(chunks[2].old_first, nil)
end

T['chunk_at()'] = new_set()

T['chunk_at()']['finds the chunk of a line, nil outside'] = function()
    local chunks = ribbons.chunks(doc_of('cdcac'))

    eq(ribbons.chunk_at(chunks, 3), chunks[1])
    eq(ribbons.chunk_at(chunks, 5), chunks[2])
    eq(ribbons.chunk_at(chunks, 4), nil)
end

T['shapes()'] = new_set()

T['shapes()']['an added chunk starts from a point on the left'] = function()
    local chunks = { { first = 5, last = 7, new_first = 5, new_last = 7 } }
    local shape = ribbons.shapes(chunks, 20, plain_top, 1, 20)[1]

    eq(shape.kind, 'add')
    eq({ shape.lt, shape.lb, shape.rt, shape.rb }, { 4, 4, 4, 7 })
    eq(shape.left_empty, true)
    eq(shape.right_empty, false)
end

T['shapes()']['a same-size change is a straight band'] = function()
    local chunks = ribbons.chunks(doc_of('cdac'))
    local shape = ribbons.shapes(chunks, 20, plain_top, 1, 20)[1]

    eq(shape.kind, 'change')
    eq(shape.lt, shape.rt)
    eq(shape.lb, shape.rb)
end

T['shapes()']['an annotation above moves the band by its rows'] = function()
    local chunks = { { first = 5, last = 5, new_first = 5, new_last = 5 } }
    local shape = ribbons.shapes(chunks, 20, function(lnum)
        return lnum <= 4 and lnum - 1 or lnum + 1
    end, 1, 20)[1]

    -- The point stays under line 4, the band starts below the annotation.
    eq({ shape.lt, shape.rt, shape.rb }, { 4, 6, 7 })
end

T['shapes()']['keeps a chunk sloping off the edge, drops the far ones'] = function()
    local chunks = {
        { first = 2, last = 3, new_first = 2, new_last = 3 },
        { first = 9, last = 12, new_first = 9, new_last = 12 },
        { first = 40, last = 41, new_first = 40, new_last = 41 },
    }
    local shapes = ribbons.shapes(chunks, 10, function(lnum)
        return lnum - 8
    end, 8, 17)

    eq(#shapes, 1)
    eq(shapes[1].rt, 1)
end

T['shapes()']['marks the active chunk'] = function()
    local chunks = ribbons.chunks(doc_of('cdcac'))
    local shapes = ribbons.shapes(chunks, 20, plain_top, 1, 20, chunks[2])

    eq(shapes[1].active, false)
    eq(shapes[2].active, true)
end

T['paint()'] = new_set()

T['paint()']['a change fades from red to green'] = function()
    local surface = Surface.new(100, 80)

    ribbons.paint(surface, {
        {
            kind = 'change',
            active = false,
            lt = 1,
            lb = 2,
            rt = 1,
            rb = 2,
            left_empty = false,
            right_empty = false,
        },
    }, {}, PALETTE, 20)

    local left, right = surface:pixel(1, 30), surface:pixel(98, 30)

    eq(left[4], 255)
    eq(right[4], 255)
    eq(left[1] > 190 and left[2] < 10, true)
    eq(right[2] > 190 and right[1] < 10, true)
    eq(surface:pixel(50, 10)[4], 0)
    eq(surface:pixel(50, 50)[4], 0)
end

T['paint()']['an added band narrows to a line on the left'] = function()
    local surface = Surface.new(100, 180)

    ribbons.paint(surface, {
        {
            kind = 'add',
            active = false,
            lt = 1,
            lb = 1,
            rt = 1,
            rb = 8,
            left_empty = true,
            right_empty = false,
        },
    }, {}, PALETTE, 20)

    eq(surface:pixel(0, 100)[4], 0)
    eq(surface:pixel(99, 100)[2] > 190, true)
    eq(surface:pixel(99, 100)[4] > 200, true)
end

T['paint()']['the active chunk takes the stronger tint'] = function()
    local surface = Surface.new(100, 80)

    ribbons.paint(surface, {
        {
            kind = 'add',
            active = true,
            lt = 1,
            lb = 2,
            rt = 1,
            rb = 2,
            left_empty = false,
            right_empty = false,
        },
    }, {}, PALETTE, 20)

    eq(surface:pixel(50, 30), { 0, 250, 0, 255 })
end

T['paint()']['a point starts on the row edge'] = function()
    local surface = Surface.new(100, 80)

    ribbons.paint(surface, {
        {
            kind = 'add',
            active = false,
            lt = 2,
            lb = 2,
            rt = 2,
            rb = 3,
            left_empty = true,
            right_empty = false,
        },
    }, {}, PALETTE, 18)

    eq(surface:pixel(0, 35)[4], 0)
    eq(surface:pixel(0, 36)[4] > 0, true)
    eq(surface:pixel(0, 40)[4], 0)
end

T['paint()']['bands fill their row, rules a thin line'] = function()
    local surface = Surface.new(20, 80)

    ribbons.paint(surface, {}, {
        { y = 0, color = { 1, 2, 3 } },
        { y = 2, color = { 4, 5, 6 }, rule = true },
    }, PALETTE, 20)

    eq(surface:pixel(10, 10), { 1, 2, 3, 255 })
    eq(surface:pixel(10, 30)[4], 0)
    eq(surface:pixel(10, 49), { 4, 5, 6, 255 })
    eq(surface:pixel(10, 42)[4], 0)
end

return T
