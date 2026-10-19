-- The error cases pass wrongly typed options on purpose.
---@diagnostic disable: assign-type-mismatch, param-type-mismatch

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local expect_error = MiniTest.expect.error

local config = require('iter.config')
local keymap = require('iter.keymap')

local T = new_set()

T['resolve()'] = new_set()

T['resolve()']['returns the defaults without options'] = function()
    local resolved = config.resolve()

    eq(resolved.options.drawer, { height = 0.3, zindex = 40, breakpoint = 80 })
    eq(resolved.options.diff, {
        expand_step = 20,
        syntax_max_lines = 20000,
        word_diff = true,
    })
    eq(
        resolved.options.export.intro,
        'I reviewed your changes and have these annotations.\nPlease address them.'
    )
    eq(resolved.options.refresh.poll_ms, 2000)
    eq(resolved.options.confirm.discard, true)
    eq(resolved.debug, false)
    eq(resolved.keys.drawer.stage, { 's' })
    eq(resolved.keys.diff.next_hunk, { ']c' })
    eq(resolved.keys.help.close, { 'q', '?', '<Esc>' })
end

T['resolve()']['merges partial options with the defaults'] = function()
    local resolved = config.resolve({
        drawer = { height = 0.5 },
        confirm = { discard = false },
        debug = true,
    })

    eq(resolved.options.drawer, { height = 0.5, zindex = 40, breakpoint = 80 })
    eq(resolved.options.confirm.discard, false)
    eq(resolved.debug, true)
end

T['resolve()']['remaps a key to a string or a list'] = function()
    local resolved = config.resolve({
        keys = { drawer = { stage = 'S', unstage = { 'U', 'gu' } } },
    })

    eq(resolved.keys.drawer.stage, { 'S' })
    eq(resolved.keys.drawer.unstage, { 'U', 'gu' })
    eq(resolved.keys.drawer.discard, { 'd' })
end

T['resolve()']['replaces a default key list as a whole'] = function()
    local resolved = config.resolve({ keys = { help = { close = { 'x' } } } })

    eq(resolved.keys.help.close, { 'x' })
end

T['resolve()']['disables a key with false'] = function()
    local resolved = config.resolve({ keys = { drawer = { discard = false } } })

    eq(resolved.keys.drawer.discard, {})
    eq(resolved.keys.drawer.stage, { 's' })
end

T['resolve()']['does not mutate the defaults'] = function()
    config.resolve({ keys = { drawer = { stage = 'S' } } })

    eq(config.resolve().keys.drawer.stage, { 's' })
end

T['resolve() errors'] = new_set()

T['resolve() errors']['on options that are not a table'] = function()
    expect_error(function()
        config.resolve('nope')
    end, 'opts: expected table')
end

T['resolve() errors']['on an unknown option'] = function()
    expect_error(function()
        config.resolve({ status = { height = 0.5 } })
    end, 'opts%.status is not an option')

    expect_error(function()
        config.resolve({ drawer = { width = 10 } })
    end, 'opts%.drawer%.width is not an option')
end

T['resolve() errors']['on a wrong option type'] = function()
    expect_error(function()
        config.resolve({ drawer = { height = 'tall' } })
    end, 'opts%.drawer%.height: expected number')

    expect_error(function()
        config.resolve({ drawer = { zindex = 1.5 } })
    end, 'opts%.drawer%.zindex: expected integer')

    expect_error(function()
        config.resolve({ diff = { word_diff = 'yes' } })
    end, 'opts%.diff%.word_diff: expected boolean')

    expect_error(function()
        config.resolve({ export = { intro = 1 } })
    end, 'opts%.export%.intro: expected string')

    expect_error(function()
        config.resolve({ drawer = 1 })
    end, 'opts%.drawer: expected table')
end

T['resolve() errors']['on a drawer height outside (0, 1]'] = function()
    expect_error(function()
        config.resolve({ drawer = { height = 0 } })
    end, 'opts%.drawer%.height must be a number between 0 and 1')

    expect_error(function()
        config.resolve({ drawer = { height = 1.5 } })
    end, 'opts%.drawer%.height must be a number between 0 and 1')
end

T['resolve() errors']['on an unknown view'] = function()
    expect_error(function()
        config.resolve({ keys = { status = { stage = 'S' } } })
    end, 'opts%.keys%.status is not a view')
end

T['resolve() errors']['on an unknown action'] = function()
    expect_error(function()
        config.resolve({ keys = { drawer = { commit = 'c' } } })
    end, 'opts%.keys%.drawer%.commit is not an action of drawer')
end

T['resolve() errors']['on an invalid key value'] = function()
    local message = 'opts%.keys%.drawer%.stage must be a key, a list of keys,'
        .. ' or false'

    for _, value in ipairs({ true, '', {}, { 's', 1 }, 3 }) do
        expect_error(function()
            config.resolve({ keys = { drawer = { stage = value } } })
        end, message)
    end
end

T['resolve() errors']['on keys that are not tables'] = function()
    expect_error(function()
        config.resolve({ keys = 'x' })
    end, 'opts%.keys: expected table')

    expect_error(function()
        config.resolve({ keys = { drawer = 'x' } })
    end, 'opts%.keys%.drawer: expected table')
end

T['keymap'] = new_set({
    hooks = {
        pre_case = function()
            _G.buf = vim.api.nvim_create_buf(false, true)
        end,
        post_case = function()
            vim.api.nvim_buf_delete(_G.buf, { force = true })
            _G.buf = nil
        end,
    },
})

---@param buf integer
---@param lhs string
---@return table
local function buf_map(buf, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
        if map.lhs == lhs then
            return map
        end
    end

    return {}
end

T['keymap']['attach() binds the resolved keys of handled actions'] = function()
    local keys = config.resolve({
        keys = { drawer = { stage = { 'S', 'gs' }, discard = false } },
    }).keys.drawer
    local calls = {}

    keymap.attach(_G.buf, 'drawer', keys, {
        stage = function()
            table.insert(calls, 'stage')
        end,
        discard = function()
            table.insert(calls, 'discard')
        end,
    })

    eq(buf_map(_G.buf, 'S').desc, 'Stage or unstage the file')
    eq(buf_map(_G.buf, 'gs').desc, 'Stage or unstage the file')
    eq(buf_map(_G.buf, 's'), {})
    eq(buf_map(_G.buf, 'd'), {})
    eq(buf_map(_G.buf, 'u'), {})

    buf_map(_G.buf, 'S').callback()
    eq(calls, { 'stage' })
end

T['keymap']['list() returns handled, bound actions in order'] = function()
    local keys = config.resolve({
        keys = { drawer = { stage = 'S', discard = false } },
    }).keys.drawer
    local noop = function() end

    eq(
        keymap.list(
            'drawer',
            keys,
            { close = noop, discard = noop, stage = noop }
        ),
        {
            {
                action = 'stage',
                lhs = { 'S' },
                desc = 'Stage or unstage the file',
                modes = { 'n' },
            },
            {
                action = 'close',
                lhs = { 'q' },
                desc = 'Close',
                modes = { 'n' },
            },
        }
    )
end

T['keymap']['attach() maps a multi-mode action in each mode'] = function()
    local keys = config.resolve().keys.annotation

    keymap.attach(_G.buf, 'annotation', keys, { save = function() end })

    for _, mode in ipairs({ 'n', 'i' }) do
        local descs = vim.tbl_map(function(map)
            return map.desc
        end, vim.api.nvim_buf_get_keymap(_G.buf, mode))

        eq(descs, { 'Save the annotation and close the float' })
    end

    eq(vim.api.nvim_buf_get_keymap(_G.buf, 'x'), {})
end

T['keymap']['describes every default action'] = function()
    local keys = config.resolve().keys

    for view, actions in pairs(keys) do
        local handlers = {}

        for action in pairs(actions) do
            handlers[action] = function() end
        end

        eq(#keymap.list(view, actions, handlers), vim.tbl_count(actions))
    end
end

T['keymap']['actions() match the configurable keys of every view'] = function()
    local defaults = require('iter.config.defaults')

    for view, keys in pairs(defaults.keys) do
        local expected = vim.tbl_keys(keys)
        local actual = keymap.actions(view)
        table.sort(expected)
        table.sort(actual)
        eq({ view, actual }, { view, expected })
    end

    local views = vim.tbl_keys(defaults.keys)
    table.sort(views)
    eq(
        views,
        { 'annotation', 'diff', 'drawer', 'help', 'picker', 'review_drawer' }
    )
end

T['health'] = new_set()

T['health']['checks Neovim 0.12 and git, nothing else'] = function()
    local health = vim.health
    local reports = {}
    vim.health = {
        start = function(_) end,
        ok = function(msg)
            table.insert(reports, 'ok ' .. msg)
        end,
        warn = function(msg)
            table.insert(reports, 'warn ' .. msg)
        end,
        error = function(msg)
            table.insert(reports, 'error ' .. msg)
        end,
    }

    local ok, err = pcall(require('iter.health').check)
    vim.health = health

    eq({ ok, err }, { true, nil })
    eq(reports, { 'ok Neovim 0.12 or newer', 'ok `git` is executable' })
end

return T
