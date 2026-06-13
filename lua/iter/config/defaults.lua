-- All user-facing option fields are optional: setup() deep-merges partial
-- tables with M.options, so the resolved config always has every field.

---@class IterPreviewOptions
---@field wrap? boolean

---@class IterStatusOptions
---@field height? number

---@class IterConfirmOptions
---@field discard? boolean Ask before discarding changes (d)
---@field force_discard? boolean Ask before force-discarding changes (D)
---@field force_push? boolean Ask before force-pushing with lease (P)

---@class IterOptions
---@field preview? IterPreviewOptions
---@field status? IterStatusOptions
---@field confirmations? IterConfirmOptions
---@field keymaps? table
---@field debug? boolean

---@class IterKeymapEntry
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
    },
    status = {
        height = 0.25,
    },
    confirmations = {
        discard = true,
        force_discard = true,
        force_push = true,
    },
}

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

---@type IterKeymapEntry[]
M.keymaps_status = {
    {
        key = '<CR>',
        modes = { 'n' },
        desc = 'Open git status entry',
        action = 'enter_entry',
        area = 'status',
    },
    {
        key = '<C-]>',
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
        desc = 'Force discard git status entry',
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
        key = 'P',
        modes = { 'n' },
        desc = 'Force push with lease',
        action = 'push_force',
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
        desc = 'Open side-by-side diff via diffs.nvim',
        action = 'open_split_diff',
        area = 'status',
    },
    {
        key = '<C-d>',
        modes = { 'n' },
        desc = 'Scroll diff preview down',
        action = 'scroll_diff_down',
        area = 'status',
    },
    {
        key = '<C-u>',
        modes = { 'n' },
        desc = 'Scroll diff preview up',
        action = 'scroll_diff_up',
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

---@type IterKeymapEntry[]
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
        desc = 'Open side-by-side diff via diffs.nvim',
        action = 'open_split_diff',
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

---@type IterKeymapEntry[]
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

---@class IterHighlightSpec
---@field name string
---@field sources string[]
---@field fallback_fg integer?
---@field fallback_bg integer?

M.highlight_specs = {
    staged = {
        name = 'IterStage',
        sources = { 'Added', 'String' },
        fallback_fg = 0x98C379,
    },
    unstaged = {
        name = 'IterUnstage',
        sources = { 'Removed', 'Error' },
        fallback_fg = 0xE06C75,
    },
    untracked = {
        name = 'IterUntracked',
        sources = { 'DiagnosticInfo', 'Directory', 'Identifier' },
        fallback_fg = 0x61AFEF,
    },
    ignored = {
        name = 'IterIgnored',
        sources = { 'Comment' },
        fallback_fg = 0x5C6370,
    },
    conflict = {
        name = 'IterConflict',
        sources = { 'DiagnosticError', 'ErrorMsg', 'Error' },
        fallback_fg = 0xE06C75,
    },
    head = {
        name = 'IterHead',
        sources = { 'Identifier', 'Keyword' },
        fallback_fg = 0x61AFEF,
    },
    unpushed = {
        name = 'IterUnpushed',
        sources = { 'Constant', 'Number' },
        fallback_fg = 0xD19A66,
    },
    loading = {
        name = 'IterLoading',
        sources = { 'DiagnosticInfo', 'Identifier' },
        fallback_fg = 0x61AFEF,
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

return M
