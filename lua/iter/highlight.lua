--- All `Iter*` groups, derived from the colorscheme and rederived on every
--- `ColorScheme`. Groups the colorscheme defines itself are left alone.

local M = {}

-- Share of the diff colour in a row background; the rest is Normal.
local BLEND = 0.6

-- Share of the title colour in the file header background; the rest is Normal.
local HEADER_BLEND = 0.2

---@param color integer
---@param base integer
---@param alpha number
---@return integer
local function blend(color, base, alpha)
    local result = 0

    for _, shift in ipairs({ 16, 8, 0 }) do
        local a = bit.band(bit.rshift(color, shift), 0xFF)
        local b = bit.band(bit.rshift(base, shift), 0xFF)
        local mixed = math.floor(a * alpha + b * (1 - alpha))
        result = bit.bor(result, bit.lshift(mixed, shift))
    end

    return result
end

--- The first `key` colour found in `names`, links resolved.
---@param names string[]
---@param key 'fg'|'bg'
---@return integer?
local function color(names, key)
    for _, name in ipairs(names) do
        local hl = vim.api.nvim_get_hl(0, { name = name, link = false })

        if hl[key] ~= nil then
            return hl[key]
        end
    end

    return nil
end

-- Drawer groups: the first foreground found in `sources`, else `fallback`.
---@type table<string, { sources: string[], fallback: integer }>
local FOREGROUNDS = {
    IterStage = { sources = { 'Added', 'String' }, fallback = 0x98C379 },
    IterUnstage = { sources = { 'Removed', 'Error' }, fallback = 0xE06C75 },
    IterUntracked = {
        sources = { 'DiagnosticInfo', 'Directory', 'Identifier' },
        fallback = 0x61AFEF,
    },
    IterConflict = {
        sources = { 'DiagnosticError', 'ErrorMsg', 'Error' },
        fallback = 0xE06C75,
    },
    IterHead = { sources = { 'Identifier', 'Keyword' }, fallback = 0x61AFEF },
    IterUnpushed = { sources = { 'Constant', 'Number' }, fallback = 0xD19A66 },
    IterBehind = { sources = { 'Removed', 'Error' }, fallback = 0xE06C75 },
    IterReviewed = { sources = { 'Added', 'String' }, fallback = 0x98C379 },
    IterReviewedChanged = {
        sources = { 'DiagnosticWarn', 'WarningMsg', 'Constant' },
        fallback = 0xE5C07B,
    },
}

-- Definition each group had right after iter last set it, by group name.
---@type table<string, table>
local owned = {}

-- Neovim drops the `default` flag from the groups when `Normal` is redefined,
-- so definitions are compared without it.
local function definition(name)
    local hl = vim.api.nvim_get_hl(0, { name = name, link = true })
    hl.default = nil

    return hl
end

--- Set a derived group unless the colorscheme defined it. An undefined group
--- gets the derived value as a `default`. A group still holding exactly what
--- iter set last time (a colorscheme without `:hi clear`) is re-derived, and
--- any other definition belongs to the colorscheme and stays.
---@param name string
---@param spec vim.api.keyset.highlight
local function set_derived(name, spec)
    local current = definition(name)

    if next(current) == nil then
        vim.api.nvim_set_hl(
            0,
            name,
            vim.tbl_extend('force', spec, { default = true })
        )
    elseif vim.deep_equal(current, owned[name]) then
        vim.api.nvim_set_hl(0, name, spec)
    else
        owned[name] = nil
        return
    end

    owned[name] = definition(name)
end

--- Define the `Iter*` groups the colorscheme left undefined.
function M.apply()
    local dark = vim.o.background ~= 'light'
    local base = color({ 'Normal' }, 'bg')
    local add_bg = color({ 'DiffAdd' }, 'bg') or (dark and 0x1a3a1a or 0xd0ffd0)
    local del_bg = color({ 'DiffDelete' }, 'bg')
        or (dark and 0x3a1a1a or 0xffd0d0)
    local add_fg = color({ 'diffAdded', 'Added', 'DiffAdd' }, 'fg')
        or (dark and 0x80d080 or 0x206020)
    local del_fg = color({ 'diffRemoved', 'Removed', 'DiffDelete' }, 'fg')
        or (dark and 0xd08080 or 0x802020)
    local title = color({ 'Title' }, 'fg') or (dark and 0xe0a060 or 0x905020)
    local header_bg =
        blend(title, base or (dark and 0x000000 or 0xffffff), HEADER_BLEND)

    -- Rows soften the diff colour towards Normal and words take it whole.
    -- Without a Normal background (transparent) rows take the diff colour
    -- whole and words mix in some of the sign colour instead.
    local add_row, del_row, add_text, del_text

    if base ~= nil then
        add_row, del_row =
            blend(add_bg, base, BLEND), blend(del_bg, base, BLEND)
        add_text, del_text = add_bg, del_bg
    else
        add_row, del_row = add_bg, del_bg
        add_text = blend(add_fg, add_bg, 1 - BLEND)
        del_text = blend(del_fg, del_bg, 1 - BLEND)
    end

    local groups = {
        IterDiffAdd = { bg = add_row },
        IterDiffDelete = { bg = del_row },
        IterDiffAddText = { bg = add_text },
        IterDiffDeleteText = { bg = del_text },
        IterDiffAddNr = { fg = add_fg, bg = add_row },
        IterDiffDeleteNr = { fg = del_fg, bg = del_row },
        IterDiffNr = { link = 'LineNr' },
        IterDiffHeader = {
            fg = color({ 'Normal' }, 'fg'),
            bg = header_bg,
            bold = true,
        },
        IterDiffHeaderRule = { fg = title },
        IterDiffHunk = { link = 'Comment' },
        IterDiffGap = { link = 'Folded' },
        IterDiffFiller = { link = 'NonText' },
        IterDiffAnnotation = { link = 'NormalFloat' },
        IterDiffAnnotationOutdated = { link = 'Comment' },
        IterDiffAnnotationFocus = { link = 'Visual' },
        IterAnnotationSign = { link = 'Special' },
        IterDrawer = { link = 'Normal' },
        IterDrawerTitle = { link = 'Title' },
        IterDrawerSelected = { link = 'Visual' },
        IterDrawerKey = { link = 'Special' },
        IterDrawerHint = { link = 'Comment' },
        IterDrawerCount = { link = 'Special' },
    }

    for name, spec in pairs(FOREGROUNDS) do
        groups[name] = { fg = color(spec.sources, 'fg') or spec.fallback }
    end

    for name, spec in pairs(groups) do
        set_derived(name, spec)
    end
end

local augroup

--- Define the groups and keep them following the colorscheme. Safe to call
--- more than once.
function M.setup()
    M.apply()

    if augroup ~= nil then
        return
    end

    augroup = vim.api.nvim_create_augroup('iter.highlight', { clear = true })
    vim.api.nvim_create_autocmd('ColorScheme', {
        group = augroup,
        callback = M.apply,
    })
end

return M
