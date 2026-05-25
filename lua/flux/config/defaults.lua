---@class FluxPreviewOptions
---@field wrap boolean
---@field show_line_numbers boolean
---@field show_metadata boolean
---@field diff_layout 'stacked'|'split'|'auto'
---@field diff_auto_threshold integer

---@class FluxStatusOptions
---@field width number
---@field min_width integer
---@field layout 'topleft'|'replace'

---@class FluxOptions
---@field preview FluxPreviewOptions
---@field status FluxStatusOptions
---@field debug boolean

---@class FluxKeymapEntry
---@field key string
---@field modes string[]
---@field desc string
---@field action string
---@field area string
---@field args? table

local M = {}

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

M.options = {
    debug = false,
    preview = {
        wrap = false,
        show_line_numbers = true,
        show_metadata = true,
        diff_layout = 'stacked',
        diff_auto_threshold = 120,
    },
    status = {
        width = 0.4,
        min_width = 20,
        layout = 'topleft',
    },
}

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

---@type FluxKeymapEntry[]
M.keymaps_status = {
    {
        key = '<CR>',
        modes = { 'n' },
        desc = 'Open git status entry',
        action = 'enter_entry',
        area = 'status',
    },
    {
        key = 'o',
        modes = { 'n' },
        desc = 'Open entry and close status',
        action = 'enter_entry_and_close',
        area = 'status',
    },
    {
        key = '=',
        modes = { 'n' },
        desc = 'Show git status entry diff',
        action = 'diff_entry',
        area = 'status',
    },
    {
        key = 'q',
        modes = { 'n' },
        desc = 'Close git status window',
        action = 'close',
        area = 'status',
    },
    {
        key = '/',
        modes = { 'n' },
        desc = 'Filter git status entries',
        action = 'filter_entries',
        area = 'status',
    },
    {
        key = '<BS>',
        modes = { 'n' },
        desc = 'Clear git status filter',
        action = 'clear_filter',
        area = 'status',
    },
    {
        key = 'r',
        modes = { 'n' },
        desc = 'Refresh git status',
        action = 'refresh',
        area = 'status',
    },
    {
        key = 's',
        modes = { 'n' },
        desc = 'Stage git status entry',
        action = 'stage_entry',
        area = 'status',
    },
    {
        key = 'u',
        modes = { 'n' },
        desc = 'Unstage git status entry',
        action = 'unstage_entry',
        area = 'status',
    },
    {
        key = 'S',
        modes = { 'n' },
        desc = 'Stage all git status entries',
        action = 'stage_all_entries',
        area = 'status',
    },
    {
        key = 'U',
        modes = { 'n' },
        desc = 'Unstage all git status entries',
        action = 'unstage_all_entries',
        area = 'status',
    },
    {
        key = 'd',
        modes = { 'n' },
        desc = 'Discard git status entry',
        action = 'discard_entry',
        area = 'status',
    },
    {
        key = 'D',
        modes = { 'n' },
        desc = 'Discard git status entry without confirmation',
        action = 'discard_entry',
        args = { force = true },
        area = 'status',
    },
    {
        key = 'c',
        modes = { 'n' },
        desc = 'Commit staged changes',
        action = 'commit',
        area = 'status',
    },
    {
        key = 'p',
        modes = { 'n' },
        desc = 'Push unpushed commits',
        action = 'push',
        area = 'status',
    },
    {
        key = '?',
        modes = { 'n' },
        desc = 'Toggle git status mappings',
        action = 'toggle_help',
        area = 'status',
    },
    {
        key = 'l',
        modes = { 'n' },
        desc = 'Toggle stacked/split diff preview layout',
        action = 'toggle_preview_layout',
        area = 'status',
    },
    {
        key = 's',
        modes = { 'x' },
        desc = 'Stage selected git status entries',
        action = 'stage_selected_entries',
        area = 'status',
    },
    {
        key = 'u',
        modes = { 'x' },
        desc = 'Unstage selected git status entries',
        action = 'unstage_selected_entries',
        area = 'status',
    },
}

---@type FluxKeymapEntry[]
M.keymaps_diff_stacked = {
    {
        key = 'q',
        modes = { 'n' },
        desc = 'Close git diff preview',
        action = 'close_diff',
        area = 'diff_stacked',
    },
    {
        key = ']h',
        modes = { 'n' },
        desc = 'Jump to next git diff hunk',
        action = 'jump_hunk_next',
        area = 'diff_stacked',
    },
    {
        key = '[h',
        modes = { 'n' },
        desc = 'Jump to previous git diff hunk',
        action = 'jump_hunk_prev',
        area = 'diff_stacked',
    },
    {
        key = 'aw',
        modes = { 'n' },
        desc = 'Toggle git diff preview wrap',
        action = 'toggle_wrap',
        area = 'diff_stacked',
    },
    {
        key = 'an',
        modes = { 'n' },
        desc = 'Toggle git diff preview line numbers',
        action = 'toggle_numbers',
        area = 'diff_stacked',
    },
    {
        key = 'am',
        modes = { 'n' },
        desc = 'Toggle git diff preview metadata',
        action = 'toggle_headers',
        area = 'diff_stacked',
    },
    {
        key = 's',
        modes = { 'n' },
        desc = 'Stage current git diff hunk',
        action = 'stage_current_hunk',
        area = 'diff_stacked',
    },
    {
        key = 'u',
        modes = { 'n' },
        desc = 'Unstage current git diff hunk',
        action = 'unstage_current_hunk',
        area = 'diff_stacked',
    },
    {
        key = 'd',
        modes = { 'n' },
        desc = 'Discard current git diff hunk',
        action = 'discard_current_hunk',
        area = 'diff_stacked',
    },
    {
        key = 'al',
        modes = { 'n' },
        desc = 'Toggle stacked/split git diff preview layout',
        action = 'toggle_layout',
        area = 'diff_stacked',
    },
    {
        key = '?',
        modes = { 'n' },
        desc = 'Toggle git mappings help',
        action = 'toggle_help',
        area = 'diff_stacked',
    },
}

---@type FluxKeymapEntry[]
M.keymaps_diff_split = {
    {
        key = 'q',
        modes = { 'n' },
        desc = 'Close git diff preview',
        action = 'close_diff',
        area = 'diff_split',
    },
    {
        key = 'aw',
        modes = { 'n' },
        desc = 'Toggle git diff preview wrap',
        action = 'toggle_wrap',
        area = 'diff_split',
    },
    {
        key = ']h',
        modes = { 'n' },
        desc = 'Jump to next git diff hunk',
        action = 'jump_hunk_next',
        area = 'diff_split',
    },
    {
        key = '[h',
        modes = { 'n' },
        desc = 'Jump to previous git diff hunk',
        action = 'jump_hunk_prev',
        area = 'diff_split',
    },
    {
        key = 'an',
        modes = { 'n' },
        desc = 'Toggle git diff preview line numbers',
        action = 'toggle_split_numbers',
        area = 'diff_split',
    },
    {
        key = 's',
        modes = { 'n' },
        desc = 'Stage current git diff hunk',
        action = 'stage_current_hunk',
        area = 'diff_split',
    },
    {
        key = 'u',
        modes = { 'n' },
        desc = 'Unstage current git diff hunk',
        action = 'unstage_current_hunk',
        area = 'diff_split',
    },
    {
        key = 'd',
        modes = { 'n' },
        desc = 'Discard current git diff hunk',
        action = 'discard_current_hunk',
        area = 'diff_split',
    },
    {
        key = 'l',
        modes = { 'n' },
        desc = 'Toggle stacked/split git diff preview layout',
        action = 'toggle_layout',
        area = 'diff_split',
    },
    {
        key = '?',
        modes = { 'n' },
        desc = 'Toggle git mappings help',
        action = 'toggle_help',
        area = 'diff_split',
    },
}

---@type FluxKeymapEntry[]
M.keymaps_help = {
    {
        key = 'q',
        modes = { 'n' },
        desc = 'Close git mappings help',
        action = 'close',
        area = 'help',
    },
    {
        key = '?',
        modes = { 'n' },
        desc = 'Close git mappings help',
        action = 'close',
        area = 'help',
    },
    {
        key = '<Esc>',
        modes = { 'n' },
        desc = 'Close git mappings help',
        action = 'close',
        area = 'help',
    },
}

-- ---------------------------------------------------------------------------
-- Highlight specs
-- ---------------------------------------------------------------------------

---@class FluxHighlightSpec
---@field name string
---@field sources string[]
---@field fallback_fg integer?
---@field fallback_bg integer?

M.highlight_specs = {
    staged = {
        name = 'FluxStage',
        sources = { 'Added', 'String' },
        fallback_fg = 0x98C379,
    },
    unstaged = {
        name = 'FluxUnstage',
        sources = { 'Removed', 'Error' },
        fallback_fg = 0xE06C75,
    },
    untracked = {
        name = 'FluxUntracked',
        sources = { 'DiagnosticInfo', 'Directory', 'Identifier' },
        fallback_fg = 0x61AFEF,
    },
    ignored = {
        name = 'FluxIgnored',
        sources = { 'Comment' },
        fallback_fg = 0x5C6370,
    },
    conflict = {
        name = 'FluxConflict',
        sources = { 'DiagnosticError', 'ErrorMsg', 'Error' },
        fallback_fg = 0xE06C75,
    },
    head = {
        name = 'FluxHead',
        sources = { 'Identifier', 'Keyword' },
        fallback_fg = 0x61AFEF,
    },
    diff_added = {
        name = 'FluxDiffAdded',
        sources = { 'DiffAdd', 'Added', 'String' },
        fallback_bg = 0x2E4D33,
    },
    diff_removed = {
        name = 'FluxDiffRemoved',
        sources = { 'DiffDelete', 'Removed', 'Error' },
        fallback_bg = 0x5A2D34,
    },
    unpushed = {
        name = 'FluxUnpushed',
        sources = { 'Constant', 'Number' },
        fallback_fg = 0xD19A66,
    },
    loading = {
        name = 'FluxLoading',
        sources = { 'DiagnosticInfo', 'Identifier' },
        fallback_fg = 0x61AFEF,
    },
    diff_line_nr = {
        name = 'FluxDiffLineNr',
        sources = { 'LineNr', 'Comment' },
        fallback_fg = 0x5C6370,
    },
}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

M.spinner_frames = { '-', '\\', '|', '/' }

M.owned_buffer_fields = {
    'buf',
    'diff_buf',
    'diff_left_buf',
    'diff_right_buf',
    'help_buf',
}

M.highlight_namespace = 'GitStatusWindow'

M.diff_header_hl_name = 'FluxDiffHeader'

M.diff_hunk_header_hl_name = 'FluxDiffHunkHeader'

return M
