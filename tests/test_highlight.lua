local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality

local highlight

local function hl(name)
    return vim.api.nvim_get_hl(0, { name = name, link = true })
end

local function colorscheme_event()
    vim.api.nvim_exec_autocmds('ColorScheme', {})
end

local T = new_set({
    hooks = {
        pre_case = function()
            package.loaded['iter.highlight'] = nil
            highlight = require('iter.highlight')
            vim.cmd('highlight clear')
        end,
        post_case = function()
            vim.cmd('highlight clear')
            pcall(vim.api.nvim_del_augroup_by_name, 'iter.highlight')
        end,
    },
})

T['apply()'] = new_set()

T['apply()']['derives groups nothing defined'] = function()
    highlight.apply()

    neq(hl('IterDiffAdd').bg, nil)
    eq(hl('IterDrawer').link, 'Normal')
    eq(hl('IterSidebar').link, 'NormalFloat')
end

T['apply()']['the drawer takes NormalFloat when Normal has no background'] = function()
    -- A fresh Neovim: `:hi clear` keeps the links earlier cases set.
    local child = MiniTest.new_child_neovim()
    child.start({ '-u', dofile('tests/helpers.lua').minimal_init })
    child.api.nvim_set_hl(0, 'Normal', {})
    child.lua([[require('iter.highlight').apply()]])

    eq(
        child.api.nvim_get_hl(0, { name = 'IterDrawer', link = true }).link,
        'NormalFloat'
    )
    child.stop()
end

T['apply()']['keeps groups defined before iter'] = function()
    vim.api.nvim_set_hl(0, 'IterDiffAdd', { bg = 0x123456 })
    vim.api.nvim_set_hl(0, 'IterDrawer', { link = 'Pmenu' })

    highlight.apply()
    highlight.apply()

    eq(hl('IterDiffAdd').bg, 0x123456)
    eq(hl('IterDrawer').link, 'Pmenu')
    neq(hl('IterDiffDelete').bg, nil)
end

T['apply()']['keeps groups defined after iter without hi clear'] = function()
    highlight.apply()
    vim.api.nvim_set_hl(0, 'IterDiffAdd', { bg = 0x123456 })
    vim.api.nvim_set_hl(0, 'IterDrawer', { link = 'Pmenu' })

    highlight.apply()

    eq(hl('IterDiffAdd').bg, 0x123456)
    eq(hl('IterDrawer').link, 'Pmenu')
end

T['apply()']['re-derives its own groups when the colorscheme has no hi clear'] = function()
    vim.api.nvim_set_hl(0, 'Normal', { bg = 0x000000 })
    vim.api.nvim_set_hl(0, 'DiffAdd', { bg = 0x003300 })
    highlight.apply()
    local before = hl('IterDiffAdd').bg

    vim.api.nvim_set_hl(0, 'DiffAdd', { bg = 0x006600 })
    highlight.apply()

    neq(hl('IterDiffAdd').bg, before)
    eq(hl('IterDiffAdd').bg, 0x003d00)
end

T['apply()']['file and drawer headers take a band of the title colour and a rule in it'] = function()
    vim.api.nvim_set_hl(0, 'Normal', { fg = 0xcccccc, bg = 0x000000 })
    vim.api.nvim_set_hl(0, 'Title', { fg = 0xffffff })

    highlight.apply()

    -- 20 % of the title colour over Normal: 0xff * 0.2 = 0x33.
    eq(hl('IterDiffHeader').bg, 0x333333)
    eq(hl('IterDiffHeader').fg, 0xcccccc)
    eq(hl('IterDiffHeaderRule').fg, 0xffffff)
    eq(hl('IterDrawerHeader').bg, 0x333333)
end

T['apply()']['annotated text takes a faint share of the function colour over Normal'] = function()
    vim.api.nvim_set_hl(0, 'Normal', { bg = 0x000000 })
    vim.api.nvim_set_hl(0, 'Function', { fg = 0xc8c8c8 })
    vim.api.nvim_set_hl(0, '@function', { link = 'Function' })
    vim.api.nvim_set_hl(0, 'Visual', { bg = 0xffffff })

    highlight.apply()

    local part = math.floor(0xc8 * 0.15)
    eq(hl('IterAnnotationText').bg, part * 0x10101)
    eq(hl('IterAnnotationText').fg, nil)

    vim.api.nvim_set_hl(0, 'Normal', { bg = 0xffffff })
    vim.api.nvim_set_hl(0, '@function', { fg = 0x0000ff })
    highlight.apply()

    -- 15 % of blue over white: floor(0xff * .85) = 0xd8
    eq(hl('IterAnnotationText').bg, 0xd8d8ff)
end

T['apply()']['annotated text falls back to Visual without a function colour'] = function()
    vim.api.nvim_set_hl(0, 'Normal', { bg = 0x000000 })
    vim.api.nvim_set_hl(0, 'Function', {})
    vim.api.nvim_set_hl(0, '@function', {})
    vim.api.nvim_set_hl(0, 'Visual', { bg = 0xc8c8c8 })

    highlight.apply()

    local part = math.floor(0xc8 * 0.35)
    eq(hl('IterAnnotationText').bg, part * 0x10101)
end

T['apply()']['annotated text has a background without Normal and Visual'] = function()
    highlight.apply()

    neq(hl('IterAnnotationText').bg, nil)
end

T['setup()'] = new_set()

T['setup()']['colorscheme with hi clear keeps its groups and derives the rest'] = function()
    highlight.setup()
    local derived_delete = hl('IterDiffDelete').bg

    vim.cmd('highlight clear')
    vim.api.nvim_set_hl(0, 'IterDiffAdd', { bg = 0x123456 })
    vim.api.nvim_set_hl(0, 'IterDrawer', { link = 'Pmenu' })
    vim.api.nvim_set_hl(0, 'DiffDelete', { bg = 0x330000 })
    colorscheme_event()

    eq(hl('IterDiffAdd').bg, 0x123456)
    eq(hl('IterDrawer').link, 'Pmenu')
    neq(hl('IterDiffDelete').bg, derived_delete)
end

T['setup()']['colorscheme without hi clear keeps its groups and re-derives the rest'] = function()
    vim.api.nvim_set_hl(0, 'Normal', { bg = 0x000000 })
    vim.api.nvim_set_hl(0, 'DiffDelete', { bg = 0x330000 })
    highlight.setup()
    local derived_delete = hl('IterDiffDelete').bg

    vim.api.nvim_set_hl(0, 'IterDiffAdd', { bg = 0x123456 })
    vim.api.nvim_set_hl(0, 'DiffDelete', { bg = 0x660000 })
    colorscheme_event()

    eq(hl('IterDiffAdd').bg, 0x123456)
    neq(hl('IterDiffDelete').bg, derived_delete)
end

T['setup()']['a group dropped by the colorscheme derives again'] = function()
    highlight.setup()
    vim.api.nvim_set_hl(0, 'IterDrawer', { link = 'Pmenu' })
    colorscheme_event()
    eq(hl('IterDrawer').link, 'Pmenu')

    vim.cmd('highlight clear')
    colorscheme_event()

    eq(hl('IterDrawer').link, 'Normal')
end

return T
