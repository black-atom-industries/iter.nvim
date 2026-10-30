---@meta

-- All user-facing option fields are optional: setup() deep-merges partial
-- tables with the defaults, so the resolved config always has every field.

---@class IterDrawerOptions
---@field height? number Fraction of the pane height, in (0, 1]
---@field zindex? integer
---@field breakpoint? integer Drawer width below which the columns stack
---@field wide_breakpoint? integer Drawer width from which the review drawer shows Unstaged and Staged side by side
---@field commits? integer Recent commits the status drawer lists, 0 hides them

---@class IterDiffOptions
---@field expand_step? integer Hidden context lines revealed per expand
---@field syntax_max_lines? integer Files longer than this get no syntax
---@field word_diff? boolean
---@field layout? IterLayoutOption Diff layout a Neovim session starts in, 'auto' to follow the width
---@field split_breakpoint? integer Diff width from which 'auto' shows the diff side by side
---@field wrap? boolean Whether a Neovim session starts with long lines wrapped in the unified layout
---@field args? string[] Extra flags for every `git diff`, see the README for the allowed ones

---@class IterExportOptions
---@field intro? string Text placed before the exported annotations

---@class IterAnnotateOptions
---@field side? 'left'|'right' Side of the window the sidebar opens on
---@field width? integer Columns of the sidebar, 10 or more
---@field review_breakpoint? integer Tab width from which the review shows the sidebar in place of the drawer's Annotations column; 0 = always

---@class IterRefreshOptions
---@field poll_ms? integer

---@class IterConfirmOptions
---@field discard? boolean Ask before discarding changes
---@field ignore? boolean Ask before adding a path to .gitignore

---@class IterIconsOptions
---@field annotation? string Shown before each annotation, '' for none

---@alias IterLayoutOption 'unified'|'split'|'auto'

---@alias IterView 'drawer'|'review_drawer'|'diff'|'annotate'|'annotation'|'help'|'picker'|'commits'

---@alias IterKeyValue string|string[]|false

---@class IterOptions
---@field drawer? IterDrawerOptions
---@field diff? IterDiffOptions
---@field export? IterExportOptions
---@field annotate? IterAnnotateOptions
---@field refresh? IterRefreshOptions
---@field confirm? IterConfirmOptions
---@field icons? IterIconsOptions
---@field keys? table<IterView, table<string, IterKeyValue>>
---@field debug? boolean

---@class IterResolvedOptions
---@field drawer { height: number, zindex: integer, breakpoint: integer, wide_breakpoint: integer, commits: integer }
---@field diff { expand_step: integer, syntax_max_lines: integer, word_diff: boolean, layout: IterLayoutOption, split_breakpoint: integer, wrap: boolean, args: string[] }
---@field export { intro: string }
---@field annotate { side: 'left'|'right', width: integer, review_breakpoint: integer }
---@field refresh { poll_ms: integer }
---@field confirm { discard: boolean, ignore: boolean }
---@field icons { annotation: string }
---@field debug boolean

---@class IterConfig
---@field options IterResolvedOptions
---@field keys table<IterView, table<string, string[]>> Empty list: unmapped
---@field debug boolean Whether to write debug-level logs to the iter log file
