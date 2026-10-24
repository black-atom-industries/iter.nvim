local uri = require('iter.uri')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

T['of()'] = function()
    eq(uri.of('review'), 'iter://review')
    eq(uri.of('review', 'lua/a.lua'), 'iter://review/lua/a.lua')
    eq(uri.of('review', 'lua/a.lua', 42), 'iter://review/lua/a.lua#L42')
end

T['parse()'] = function()
    eq(uri.parse('iter://status'), { kind = 'status' })
    eq(uri.parse('iter://status/a.txt'), { kind = 'status', path = 'a.txt' })
    eq(uri.parse('iter://review'), { kind = 'review' })
    eq(uri.parse('iter://annotation'), { kind = 'annotation' })
    eq(uri.parse('iter://annotate'), { kind = 'annotate' })
    eq(uri.parse('iter://annotate/3'), { kind = 'annotate' })
    eq(
        uri.parse('iter://review/lua/a.lua'),
        { kind = 'review', path = 'lua/a.lua' }
    )
    eq(
        uri.parse('iter://review/lua/a.lua#L42'),
        { kind = 'review', path = 'lua/a.lua', line = 42 }
    )
    eq(
        uri.parse('iter://review/sp ace/a#b.txt#L3'),
        { kind = 'review', path = 'sp ace/a#b.txt', line = 3 }
    )
    eq(
        uri.parse('iter://review/a.txt#old'),
        { kind = 'review', path = 'a.txt' }
    )
    eq(uri.parse('iter://review#all'), { kind = 'review', view = 'all' })
    eq(uri.parse('iter://review#all#old'), { kind = 'review', view = 'all' })
    eq(
        uri.parse('iter://review#annotations'),
        { kind = 'review', view = 'annotations' }
    )
    eq(uri.parse('iter://review/all'), { kind = 'review', path = 'all' })
    eq(uri.parse('iter://nope'), nil)
    eq(uri.parse('/tmp/a.txt'), nil)
end

return T
