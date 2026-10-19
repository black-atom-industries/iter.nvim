local anchor = require('iter.annotations.anchor')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@param start_line integer
---@param lines string[]
---@return IterAnchor
local function new_side(start_line, lines)
    return {
        path = 'f.lua',
        side = 'new',
        start_line = start_line,
        end_line = start_line + #lines - 1,
        lines = lines,
    }
end

---@param scope 'line'|'range'|'file'|'review'
---@param a IterAnchor
---@return IterAnnotation
local function annotation(scope, a)
    return {
        id = 'c1',
        scope = scope,
        anchor = a,
        body = 'note',
        outdated = false,
        created_at = 1,
        updated_at = 1,
    }
end

local T = new_set()

T['create()'] = new_set()

T['create()']['copies the anchored lines'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = 2,
        end_line = 3,
    }, { 'a', 'b', 'c', 'd' })

    eq(a, {
        path = 'f.lua',
        side = 'new',
        start_line = 2,
        end_line = 3,
        lines = { 'b', 'c' },
    })
end

T['create()']['keeps the base of an old-side anchor'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'old',
        base = 'index',
        start_line = 1,
        end_line = 1,
    }, { 'gone' })

    eq(a.base, 'index')
    eq(a.lines, { 'gone' })
end

T['create()']['needs a base on the old side'] = function()
    MiniTest.expect.error(function()
        anchor.create({ path = 'f.lua', side = 'old', start_line = 1 }, {})
    end)
end

T['create()']['takes a file anchor without lines'] = function()
    eq(
        anchor.create({ path = 'f.lua', side = 'new' }),
        { path = 'f.lua', side = 'new' }
    )
end

T['resolve()'] = new_set()

T['resolve()']['keeps unchanged text in place'] = function()
    local start, stop =
        anchor.resolve(new_side(2, { 'b', 'c' }), { 'a', 'b', 'c', 'd' })

    eq({ start, stop }, { 2, 3 })
end

T['resolve()']['follows text that shifted down'] = function()
    local start, stop = anchor.resolve(
        new_side(2, { 'b', 'c' }),
        { 'new 1', 'new 2', 'a', 'b', 'c', 'd' }
    )

    eq({ start, stop }, { 4, 5 })
end

T['resolve()']['follows text that shifted up'] = function()
    local start, stop = anchor.resolve(new_side(3, { 'c' }), { 'c', 'd', 'e' })

    eq({ start, stop }, { 1, 1 })
end

T['resolve()']['misses edited text'] = function()
    eq(anchor.resolve(new_side(2, { 'b', 'c' }), { 'a', 'b', 'C', 'd' }), nil)
end

T['resolve()']['misses deleted text'] = function()
    eq(anchor.resolve(new_side(2, { 'b' }), { 'a', 'c' }), nil)
end

T['resolve()']['misses in an empty or missing version'] = function()
    eq(anchor.resolve(new_side(1, { 'a' }), {}), nil)
    eq(anchor.resolve(new_side(1, { 'a' }), nil), nil)
end

T['resolve()']['picks the duplicate nearest to the stored line'] = function()
    local lines = { 'x', 'dup', 'y', 'y', 'y', 'y', 'dup', 'z', 'z', 'dup' }

    eq({ anchor.resolve(new_side(6, { 'dup' }), lines) }, { 7, 7 })
    eq({ anchor.resolve(new_side(3, { 'dup' }), lines) }, { 2, 2 })
    eq({ anchor.resolve(new_side(9, { 'dup' }), lines) }, { 10, 10 })
end

T['resolve()']['breaks a distance tie toward the upper match'] = function()
    eq({
        anchor.resolve(new_side(3, { 'dup' }), { 'dup', 'a', 'b', 'c', 'dup' }),
    }, { 1, 1 })
end

T['resolve()']['prefers the stored position over a nearer copy'] = function()
    eq({ anchor.resolve(new_side(2, { 'a' }), { 'a', 'a', 'a' }) }, { 2, 2 })
end

T['resolve()']['ignores carriage returns on either side'] = function()
    eq({ anchor.resolve(new_side(1, { 'b\r' }), { 'a', 'b' }) }, { 2, 2 })
    eq({ anchor.resolve(new_side(1, { 'b' }), { 'a\r', 'b\r' }) }, { 2, 2 })
end

T['resolve()']['resolves an old-side anchor against its base'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'old',
        base = 'HEAD',
        start_line = 2,
        end_line = 2,
    }, { 'one', 'removed', 'three' })

    eq({ anchor.resolve(a, { 'zero', 'one', 'removed', 'three' }) }, { 3, 3 })
end

T['resolve()']['has nothing to resolve for a file anchor'] = function()
    eq(anchor.resolve({ path = 'f.lua', side = 'new' }, { 'a' }), nil)
end

T['follow()'] = new_set()

T['follow()']['moves the stored position'] = function()
    local c = annotation('range', new_side(2, { 'b', 'c' }))

    local followed, changed = anchor.follow(c, { 'new', 'a', 'b', 'c' })

    eq(changed, true)
    eq(followed.anchor.start_line, 3)
    eq(followed.anchor.end_line, 4)
    eq(followed.outdated, false)
    eq(c.anchor.start_line, 2)
end

T['follow()']['reports no change for unchanged text'] = function()
    local c = annotation('line', new_side(1, { 'a' }))

    local followed, changed = anchor.follow(c, { 'a', 'b' })

    eq(changed, false)
    eq(followed, c)
end

T['follow()']['marks a lost anchor outdated and keeps its position'] = function()
    local c = annotation('line', new_side(2, { 'b' }))

    local followed, changed = anchor.follow(c, { 'a', 'B' })

    eq(changed, true)
    eq(followed.outdated, true)
    eq(followed.anchor, c.anchor)
end

T['follow()']['clears outdated when the text is found again'] = function()
    local c = annotation('line', new_side(2, { 'b' }))
    c.outdated = true

    local followed, changed = anchor.follow(c, { 'b', 'x' })

    eq(changed, true)
    eq(followed.outdated, false)
    eq(followed.anchor.start_line, 1)
end

T['follow()']['never outdates file and review annotations'] = function()
    local file = annotation('file', { path = 'f.lua', side = 'new' })
    local review = annotation('review', { side = 'new' })

    eq({ anchor.follow(file, {}) }, { file, false })
    eq({ anchor.follow(review, {}) }, { review, false })
end

T['version()'] = new_set()

T['version()']['names the version an anchor follows'] = function()
    eq(anchor.version({ side = 'new' }), 'worktree')
    eq(anchor.version({ side = 'old', base = 'HEAD' }), 'HEAD')
    eq(anchor.version({ side = 'old', base = 'index' }), 'index')
end

return T
