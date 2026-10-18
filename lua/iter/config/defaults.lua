-- All user-facing option fields are optional: setup() deep-merges partial
-- tables with M.options, so the resolved config always has every field.

---@class IterDrawerOptions
---@field height? number Fraction of the editor height, in (0, 1]
---@field zindex? integer
---@field breakpoint? integer Drawer width below which the columns stack

---@class IterDiffOptions
---@field expand_step? integer Hidden context lines revealed per expand
---@field syntax_max_lines? integer Files longer than this get no syntax
---@field word_diff? boolean

---@class IterExportOptions
---@field intro? string Text placed before the exported comments

---@class IterRefreshOptions
---@field poll_ms? integer

---@class IterConfirmOptions
---@field discard? boolean Ask before discarding changes

---@alias IterView 'drawer'|'review_drawer'|'diff'|'comment'|'picker'|'help'

---@alias IterKeyValue string|string[]|false

---@class IterOptions
---@field drawer? IterDrawerOptions
---@field diff? IterDiffOptions
---@field export? IterExportOptions
---@field refresh? IterRefreshOptions
---@field confirm? IterConfirmOptions
---@field keys? table<IterView, table<string, IterKeyValue>>
---@field debug? boolean

local M = {}

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

M.options = {
    debug = false,
    drawer = {
        height = 0.3,
        zindex = 40,
        breakpoint = 80,
    },
    diff = {
        expand_step = 20,
        syntax_max_lines = 20000,
        word_diff = true,
    },
    export = {
        intro = 'I reviewed your changes and have these comments. '
            .. 'Please address them.',
    },
    refresh = {
        poll_ms = 2000,
    },
    confirm = {
        discard = true,
    },
}

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

-- Every view and action a user may set in `keys`. A value is an lhs, a list of
-- lhs, or false to leave the action unmapped.
---@type table<IterView, table<string, IterKeyValue>>
M.keys = {
    drawer = {
        open = '<CR>',
        preview = '=',
        stage = 's',
        unstage = 'u',
        discard = 'd',
        expand = '<Tab>',
        review = 'r',
        close = 'q',
        help = '?',
        column_left = 'h',
        column_right = 'l',
    },
    review_drawer = {
        open = '<CR>',
        stage = 's',
        unstage = 'u',
        discard = 'd',
        expand = '<Tab>',
        viewed = 'v',
        mode = 'm',
        comment_file = 'C',
        picker = 'L',
        yank = 'y',
        close = 'q',
        help = '?',
        column_left = 'h',
        column_right = 'l',
    },
    diff = {
        next_hunk = ']c',
        prev_hunk = '[c',
        next_comment = ']a',
        prev_comment = '[a',
        next_file = ']f',
        prev_file = '[f',
        stage = 's',
        unstage = 'u',
        discard = 'd',
        comment = 'c',
        comment_file = 'C',
        edit = 'e',
        delete = 'x',
        expand = '<CR>',
        goto_file = 'gf',
        viewed = 'v',
        mode = 'm',
        picker = 'L',
        yank = 'y',
        close = 'q',
        help = '?',
    },
    comment = {
        save = '<C-s>',
        toggle = '<C-t>',
        cancel = '<C-c>',
        close = 'q',
    },
    picker = {
        next = '<C-n>',
        prev = '<C-p>',
        jump = '<CR>',
        edit = '<C-e>',
        delete = '<C-x>',
        close = '<Esc>',
    },
    help = {
        close = { 'q', '?', '<Esc>' },
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
}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

M.owned_buffer_fields = {
    'buf',
    'diff_buf',
    'diff_left_buf',
    'diff_right_buf',
    'help_buf',
}

M.highlight_namespace = 'GitStatusWindow'

return M
