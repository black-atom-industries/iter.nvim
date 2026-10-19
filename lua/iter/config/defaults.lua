-- All user-facing option fields are optional: setup() deep-merges partial
-- tables with M.options, so the resolved config always has every field.

---@class IterDrawerOptions
---@field height? number Fraction of the pane height, in (0, 1]
---@field zindex? integer
---@field breakpoint? integer Drawer width below which the columns stack
---@field commits? integer Recent commits the status drawer lists, 0 hides them

---@class IterDiffOptions
---@field expand_step? integer Hidden context lines revealed per expand
---@field syntax_max_lines? integer Files longer than this get no syntax
---@field word_diff? boolean

---@class IterExportOptions
---@field intro? string Text placed before the exported annotations

---@class IterRefreshOptions
---@field poll_ms? integer

---@class IterConfirmOptions
---@field discard? boolean Ask before discarding changes

---@alias IterView 'drawer'|'review_drawer'|'diff'|'annotation'|'help'

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
        commits = 3,
    },
    diff = {
        expand_step = 20,
        syntax_max_lines = 20000,
        word_diff = true,
    },
    export = {
        intro = 'I reviewed your changes and have these annotations.\n'
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
        stage = 's',
        unstage = 'u',
        discard = 'd',
        review = 'r',
        close = 'q',
        help = '?',
        scroll_down = '<C-d>',
        scroll_up = '<C-u>',
        column_left = 'h',
        column_right = 'l',
    },
    review_drawer = {
        open = '<CR>',
        stage = 's',
        unstage = 'u',
        discard = 'd',
        viewed = 'v',
        mode = 'm',
        annotate_file = 'A',
        edit = 'e',
        delete = 'x',
        yank = 'y',
        close = 'q',
        help = '?',
        scroll_down = '<C-d>',
        scroll_up = '<C-u>',
        column_left = 'h',
        column_right = 'l',
    },
    diff = {
        next_hunk = ']c',
        prev_hunk = '[c',
        next_annotation = ']a',
        prev_annotation = '[a',
        next_file = ']f',
        prev_file = '[f',
        stage = 's',
        unstage = 'u',
        annotate = 'a',
        annotate_file = 'A',
        edit = 'e',
        delete = 'x',
        expand = '<CR>',
        goto_file = 'gf',
        viewed = 'v',
        mode = 'm',
        yank = 'y',
        close = 'q',
        help = '?',
    },
    annotation = {
        save = '<C-s>',
        toggle = '<C-t>',
        cancel = '<C-c>',
        close = 'q',
    },
    help = {
        close = { 'q', '?', '<Esc>' },
    },
}

return M
