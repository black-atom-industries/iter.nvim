--- All `Iter*` groups, derived from the colorscheme and rederived on every
--- `ColorScheme`.

local M = {}

-- Share of the diff colour in a row background; the rest is Normal.
local BLEND = 0.6

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
    IterIgnored = { sources = { 'Comment' }, fallback = 0x5C6370 },
    IterConflict = {
        sources = { 'DiagnosticError', 'ErrorMsg', 'Error' },
        fallback = 0xE06C75,
    },
    IterHead = { sources = { 'Identifier', 'Keyword' }, fallback = 0x61AFEF },
    IterUnpushed = { sources = { 'Constant', 'Number' }, fallback = 0xD19A66 },
    IterViewed = { sources = { 'Added', 'String' }, fallback = 0x98C379 },
    IterViewedChanged = {
        sources = { 'DiagnosticWarn', 'WarningMsg', 'Constant' },
        fallback = 0xE5C07B,
    },
}

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
        IterDiffHeader = { link = 'Title' },
        IterDiffHunk = { link = 'Comment' },
        IterDiffGap = { link = 'Folded' },
        IterDiffComment = { link = 'NormalFloat' },
        IterDiffCommentOutdated = { link = 'Comment' },
        IterCommentSign = { link = 'Special' },
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
        vim.api.nvim_set_hl(0, name, spec)
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
