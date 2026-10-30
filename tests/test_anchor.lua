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

T['create()']['keeps a commit sha as the base of an old-side anchor'] = function()
    local sha = string.rep('a1', 20)
    local a = anchor.create({
        path = 'f.lua',
        side = 'old',
        base = sha,
        start_line = 1,
    }, { 'gone' })

    eq(a.base, sha)
    eq(anchor.version(a), sha)
end

T['create()']['refuses a base that is no version'] = function()
    for _, base in ipairs({ 'main', 'a1b2c3d', string.rep('g', 40) }) do
        MiniTest.expect.error(function()
            anchor.create({ path = 'f.lua', side = 'old', base = base }, {})
        end)
    end
end

T['old_base()'] = new_set()

T['old_base()']['names the version the deleted rows come from'] = function()
    eq(anchor.old_base({ side = 'unstaged' }), 'index')
    eq(anchor.old_base({ side = 'staged' }), 'HEAD')
    eq(anchor.old_base({ side = 'base', base = 'abc' }), 'abc')
end

T['short_base()'] = new_set()

T['short_base()']['gives the short sha of an old side on a commit only'] = function()
    local sha = string.rep('ab', 20)

    eq(anchor.short_base({ side = 'old', base = sha }), 'abababa')
    eq(anchor.short_base({ side = 'old', base = 'HEAD' }), nil)
    eq(anchor.short_base({ side = 'old', base = 'index' }), nil)
    eq(anchor.short_base({ side = 'new' }), nil)
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

T['create()']['stores the columns and the quote of a passage'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = 1,
        end_line = 1,
        start_col = 4,
        end_col = 9,
    }, { 'one two three' })

    eq(a.lines, { 'one two three' })
    eq({ a.start_col, a.end_col, a.quote }, { 4, 9, 'two t' })
end

T['create()']['joins a multi-line quote with newlines'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = 1,
        end_line = 3,
        start_col = 2,
        end_col = 1,
    }, { 'abc', 'def', 'ghi' })

    eq(a.quote, 'c\ndef\ng')
    eq({ a.start_col, a.end_col }, { 2, 1 })
end

T['create()']['clamps the end column to the line'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = 1,
        end_line = 1,
        start_col = 1,
        end_col = 99,
    }, { 'abc' })

    eq({ a.end_col, a.quote }, { 3, 'bc' })
end

T['create()']['an empty selection makes a line anchor'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = 1,
        end_line = 1,
        start_col = 0,
        end_col = 0,
    }, { '' })

    eq(a.quote, nil)
    eq(a.start_col, nil)
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

---@param start_line integer
---@param lines string[]
---@param start_col integer
---@param end_col integer
---@return IterAnchor
local function passage(start_line, lines, start_col, end_col)
    return anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = start_line,
        end_line = start_line + #lines - 1,
        start_col = start_col,
        end_col = end_col,
    }, lines)
end

T['resolve()']['keeps a passage at its stored position'] = function()
    local a = passage(1, { 'one two three' }, 4, 7)

    eq({ anchor.resolve(a, { 'one two three' }) }, { 1, 1, 4, 7 })
    eq({ anchor.resolve(a, { 'one two, and more' }) }, { 1, 1, 4, 7 })
end

T['resolve()']['follows a passage that moved within its line'] = function()
    local a = passage(1, { 'one two three' }, 4, 7)

    eq({ anchor.resolve(a, { 'well, one two three' }) }, { 1, 1, 10, 13 })
end

T['resolve()']['follows a passage to another line'] = function()
    local a = passage(1, { 'one two three' }, 4, 7)

    eq({ anchor.resolve(a, { 'new', 'x', 'a two b' }) }, { 3, 3, 2, 5 })
end

---@param lines string[]
---@param line integer
---@param start_col integer
---@param end_col integer
---@return IterAnchor
local function on(lines, line, start_col, end_col)
    return anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = line,
        end_line = line,
        start_col = start_col,
        end_col = end_col,
    }, lines)
end

T['resolve()']['an anchor without context takes the occurrence nearest to the stored line'] = function()
    local lines =
        { 'two', 'a', 'b', 'c', 'xx two xx', 'd', 'two two', 'e', 'f', 'two' }
    local a = on(lines, 5, 3, 6)
    a.before, a.after = nil, nil

    lines[5] = 'xx tow xx'

    eq({ anchor.resolve(a, lines) }, { 7, 7, 4, 7 })
end

T['resolve()']['an anchor without context takes the nearest column on a line, then the upper line on a tie'] = function()
    local a = on({ 'a two b two c' }, 1, 8, 11)
    a.before, a.after = nil, nil

    eq({ anchor.resolve(a, { 'two x two x two xx' }) }, { 1, 1, 6, 9 })

    local tie = on({ 'x', 'y', 'a two b' }, 3, 2, 5)
    tie.before, tie.after = nil, nil

    eq({ anchor.resolve(tie, { 'two', 'x', 'y', 'z', 'two' }) }, { 1, 1, 0, 3 })
end

T['create()']['stores the text around a passage'] = function()
    local a = on({ 'He said no. Later she said no again.' }, 1, 27, 29)

    eq(a.quote, 'no')
    eq(a.before, 'He said no. Later she said ')
    eq(a.after, ' again.')
end

T['create()']['cuts the context to 40 bytes and whole characters'] = function()
    local line = string.rep('ä', 30) .. ' word ' .. string.rep('ö', 30)
    local start = #string.rep('ä', 30) + 1
    local a = on({ line }, 1, start, start + 4)

    eq(a.quote, 'word')
    eq(#a.before <= 40 and #a.after <= 40, true)
    eq(vim.fn.strchars(a.before), vim.str_utfindex(a.before, 'utf-32'))
    eq(a.before:match('^[äö ]*$') ~= nil, true)
    eq(a.after:match('^[äö ]*$') ~= nil, true)
end

T['create()']['takes context across lines'] = function()
    local a = on({ 'first', 'second word', 'third' }, 2, 7, 11)

    eq(a.before, 'first\nsecond ')
    eq(a.after, '\nthird')
end

T['create()']['leaves a carriage return out of the quote'] = function()
    local a = anchor.create({
        path = 'f.lua',
        side = 'new',
        start_line = 1,
        end_line = 2,
        start_col = 0,
        end_col = 3,
    }, { 'one\r', 'two\r' })

    eq(a.quote, 'one\ntwo')
    eq(a.end_col, 3)
end

T['resolve()']['follows the right copy of a repeated word after an insertion'] = function()
    local a = on({ 'He said no. Later she said no again.' }, 1, 27, 29)

    eq(
        { anchor.resolve(a, { 'Then he said no. Later she said no again.' }) },
        { 1, 1, 32, 34 }
    )
    eq({
        anchor.resolve(a, { 'First.', 'He said no. Later she said no again.' }),
    }, { 2, 2, 27, 29 })
end

T['resolve()']['still resolves when the text on one side changed'] = function()
    local a = on({ 'He said no. Later she said no again.' }, 1, 27, 29)

    eq(
        { anchor.resolve(a, { 'He said no. And later she said no, twice.' }) },
        { 1, 1, 31, 33 }
    )
    eq(
        { anchor.resolve(a, { 'He said no. Later she said no.' }) },
        { 1, 1, 27, 29 }
    )
end

T['resolve()']['a repeat that cannot be told apart is lost'] = function()
    local a = on({ 'say no, and say no' }, 1, 16, 18)

    eq(anchor.resolve(a, { 'it is no and so is no' }), nil)
    eq(anchor.resolve(a, { 'say no', 'say no' }), nil)
end

T['resolve()']['a single occurrence follows without a context match'] = function()
    local a = on({ 'He said no. Later she said no again.' }, 1, 27, 29)

    eq({ anchor.resolve(a, { 'Totally different: no' }) }, { 1, 1, 19, 21 })
end

T['resolve()']['keeps a passage at its stored position when its context is intact'] = function()
    local a = on({ 'no no no' }, 1, 3, 5)

    eq({ anchor.resolve(a, { 'no no no' }) }, { 1, 1, 3, 5 })
end

T['resolve()']['does not take the stored position when the context changed'] = function()
    local a = on({ 'say no, and say no' }, 1, 16, 18)

    eq({ anchor.resolve(a, { 'say no, and say no!' }) }, { 1, 1, 16, 18 })
    eq({ anchor.resolve(a, { 'x say no, and say no' }) }, { 1, 1, 18, 20 })
end

T['resolve()']['finds whole words only'] = function()
    local a = on({ 'the old man' }, 1, 4, 7)

    eq(anchor.resolve(a, { 'the cold man' }), nil)
    eq(anchor.resolve(a, { 'the older man' }), nil)
    eq({ anchor.resolve(a, { 'cold and old' }) }, { 1, 1, 9, 12 })
    eq({ anchor.resolve(a, { 'the old, man' }) }, { 1, 1, 4, 7 })
end

T['resolve()']['a passage that cut into a word may do so again'] = function()
    local a = on({ 'the bold man' }, 1, 5, 7)

    eq(a.quote, 'ol')
    eq({ anchor.resolve(a, { 'so the bold man' }) }, { 1, 1, 8, 10 })
end

T['resolve()']['treats a multibyte letter as part of a word'] = function()
    local a = on({ 'der alte Mann' }, 1, 4, 8)

    eq(anchor.resolve(a, { 'der Malte Mann' }), nil)
    eq(anchor.resolve(a, { 'der älte Mann' }), nil)
end

T['resolve()']['misses a passage whose words are gone'] = function()
    local a = passage(1, { 'one two three' }, 4, 7)

    eq(anchor.resolve(a, { 'one three', 'tw o' }), nil)
end

T['resolve()']['finds the quote as plain text, not a pattern'] = function()
    local a = passage(1, { 'a.b-c %d+' }, 0, 9)

    eq({ anchor.resolve(a, { 'x', 'a.b-c %d+' }) }, { 2, 2, 0, 9 })
    eq(anchor.resolve(a, { 'aXb-c 12' }), nil)
end

T['resolve()']['counts columns in bytes for multibyte text'] = function()
    local a = passage(1, { 'Größe über alles' }, 0, 7)

    eq(a.quote, 'Größe')
    eq({ anchor.resolve(a, { 'dann Größe ändert' }) }, { 1, 1, 5, 12 })
end

T['resolve()']['follows a multi-line passage'] = function()
    local a = passage(1, { 'abc', 'def', 'ghi' }, 2, 1)

    eq({ anchor.resolve(a, { 'new', 'abc', 'def', 'ghi' }) }, { 2, 4, 2, 1 })
    eq(anchor.resolve(a, { 'abc', 'dxf', 'ghi' }), nil)
end

T['resolve()']['ignores a carriage return at the end of a line'] = function()
    local a = passage(1, { 'one two' }, 4, 7)

    eq({ anchor.resolve(a, { 'one two\r' }) }, { 1, 1, 4, 7 })
    eq({ anchor.resolve(a, { 'x', 'one two\r' }) }, { 2, 2, 4, 7 })
end

T['follow()']['clears outdated when the text is found again'] = function()
    local c = annotation('line', new_side(2, { 'b' }))
    c.outdated = true

    local followed, changed = anchor.follow(c, { 'b', 'x' })

    eq(changed, true)
    eq(followed.outdated, false)
    eq(followed.anchor.start_line, 1)
end

T['follow()']['moves a passage and rewrites its lines'] = function()
    local c = annotation('line', passage(1, { 'one two three' }, 4, 7))

    local followed, changed = anchor.follow(c, { 'so one two three' })

    eq(changed, true)
    eq(followed.anchor.lines, { 'so one two three' })
    eq({ followed.anchor.start_col, followed.anchor.end_col }, { 7, 10 })
    eq(c.anchor.start_col, 4)
end

T['follow()']['refreshes the lines of a passage that stayed'] = function()
    local c = annotation('line', passage(1, { 'one two three' }, 4, 7))

    local followed, changed = anchor.follow(c, { 'one two and four' })

    eq(changed, true)
    eq(followed.anchor.lines, { 'one two and four' })
    eq(anchor.follow(c, { 'one two three' }), c)
end

T['follow()']['refreshes the context of a moved passage'] = function()
    local c = annotation('line', passage(1, { 'one two three' }, 4, 7))

    local followed = anchor.follow(c, { 'so one two three more' })

    eq(followed.anchor.before, 'so one ')
    eq(followed.anchor.after, ' three more')
end

T['follow()']['outdates a passage whose words are gone'] = function()
    local c = annotation('line', passage(1, { 'one two three' }, 4, 7))

    local followed, changed = anchor.follow(c, { 'one three' })

    eq(changed, true)
    eq(followed.outdated, true)
    eq(followed.anchor.quote, 'two')
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
