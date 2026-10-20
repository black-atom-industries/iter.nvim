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
        args = {},
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
        ignore = true,
    },
    icons = {
        annotation = '󰆉',
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
        ignore = 'I',
        review = 'r',
        mode = 'm',
        split = '|',
        unified = '-',
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
        ignore = 'I',
        reviewed = 'r',
        unreviewed = 'R',
        mode = 'm',
        split = '|',
        unified = '-',
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
        reviewed = 'r',
        unreviewed = 'R',
        mode = 'm',
        split = '|',
        unified = '-',
        yank = 'y',
        focus_drawer = '<C-j>',
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
