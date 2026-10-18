# iter.nvim renovation

Rough outline for the rework on `feat/renovation`. Each phase finishes before the next one starts.

## Goal

A Neovim-native code review and staging tool. It joins three things Nik uses today:

- **iter** (from minifugit): a simple status menu to stage files and hunks, and commit.
- **tuicr**: review all changes in one scrolling diff, comment on lines, ranges, files or the whole review, mark files
  as reviewed, and export the comments as Markdown for an agent.
- **annotator.nvim**: typed annotations (comment, suggest, delete, label) and yanking them in batches.

Pull requests are out of scope for now.

References:

- <https://github.com/agavra/tuicr>
- <https://github.com/chpeters/annotator.nvim>
- <https://github.com/vieitesss/minifugit.nvim>

## Scope

### Layout

iter has two surfaces.

- **Drawer** (`gs`, `:Iter`): a bottom drawer inside the pane it is opened from, a split or a single full pane, like
  radar.nvim's panel. It lists Unstaged and Staged side by side, without viewed marks; untracked files sit
  under Unstaged with a `?`. The pane above the
  drawer is the live preview of the selected file's diff: `j`/`k` updates it in place, like a snacks picker preview, and Enter opens the file
  there and closes the drawer. Only the columns adapt to the drawer's width; paths truncate from the left. The drawer
  stages and unstages whole files; hunks are staged in the review tab. `r` opens the review tab, or switches to it
  when it is already open.
- **Review tab**: a tab page of its own for the whole review (designs 4a to 4e): Unstaged (untracked included) and
  Staged, with jumps between them, plus viewed marks, comments and the comment picker. Drawer at the bottom, diff of the file
  under the cursor above. `q` closes the tab; `r` is not mapped there. The branch diff against the base branch joins in M2, together with the Unpushed column.
- The drawer is a float anchored to the bottom of its pane, so it can draw above other floats such as
  radar.nvim's persistent panel. Its zindex is a config option, set above radar's by default; radar gets the same
  option.

### Diff pane

- One file at a time by default. A toggle switches to a continuous scroll of all changed files, as in tuicr.
- Unified view with treesitter syntax, intra-line word emphasis, an old/new line number rail, and hidden context
  between hunks that expands on demand. A toggle switches to side-by-side.
- iter renders diffs itself. A binary dependency is acceptable.

### Comments

- Plain text, no types. The input is a real buffer in a float, so comments span lines and take pasted code.
- A comment attaches to a line, a range, a deleted (old-side) line, a whole file, or the whole review. Comments also
  work in normal file buffers, so iter replaces annotator.nvim.
- Comments and viewed marks are saved to disk per repository and branch.
- A comment follows its line when the code moves. When the line can't be found again, the comment stays and is marked
  outdated.
- A comment picker lists all comments grouped by file and jumps to the one picked; `]c` and `[c` move between
  comments in the diff pane.
- Each file can be marked viewed. When the file changes afterwards, by Nik or an agent, it drops back to unviewed and
  shows that it changed since it was viewed.

### Export

- One key copies the review to the clipboard: a configurable intro prompt, then a numbered list where each item has
  `file:line` (or range, or file), the commented code, and the comment text.
- After copying, iter asks once whether to clear the comments.

### Git actions

- Stage and unstage files and hunks, stage selected lines, discard with confirmation.
- Untracked directories expand to their files.
- An Unpushed column lists unpushed commits (or the last few when there is no upstream). On a commit, the pane shows
  its diff and takes comments.
- iter does not commit. Commit, amend, reword, fixup, push and pull stay with mini.git's `:Git`, because each git
  flag would need its own menu in iter.
- Keys are buffer-local and single letters, defined per view (the orange notes in the design). They are the
  defaults; every key can be remapped or disabled in `setup()`.
- `?` opens a help float listing the current view's keys, generated from the keymap config. Discard asks for
  confirmation as today.
- The drawer's columns sit side by side from 80 columns of drawer width and stack below that; the breakpoint is a
  config option.
- On a clean tree the drawer opens and says "Working tree clean"; the review tab still opens for comments. Outside a
  git repository iter shows a warning and opens nothing.
- The only user command is `:Iter` with the subcommands `status` (the default) and `review`. Everything else is Lua
  API for users to map.

### Milestones

- **M1, replaces tuicr and annotator.nvim:** mini view with preview, review tab, unified renderer, untracked
  directories, comments in diffs and buffers with persistence and re-anchoring, the comment picker, viewed marks,
  export, the drawer above radar's panel.
- **M2, git and view extras:** stage selected lines, branch diff in the review tab, Unpushed column,
  side-by-side, continuous scroll.

### Out of scope

Pull requests, commits and remote sync, Jujutsu and Mercurial, merge conflict resolution, branch management, stash,
a log browser, comment types, and sending the review straight to an agent pane.

### Build decisions

- Neovim 0.12 or newer.
- Tests use mini.test, replacing the vendored plenary.nvim. UI tests run a child Neovim against a temporary git
  repository and compare screen snapshots, so the real drawer and review flow are checked without a person.
- The diff renderer is pure Lua first: `vim.text.diff` for hunks and word ranges, treesitter for syntax, ideas
  adapted from minifugit.nvim, diffs.nvim and codediff.nvim. A binary dependency comes in only if word diff or
  side-by-side alignment can't reach good quality in Lua, and that choice waits for Nik.
- Implementation runs without Nik: one Conventional Commit per working slice on `feat/renovation`, never pushed.
  Before each commit: stylua check, lua-language-server check, the full mini.test suite including UI snapshots, and a
  review of the slice's diff against this document.

## Phases

### 1. Dots wiring — done

`plugin/50_specs/black_atom/iter.lua` in dots loads the local checkout and maps `gs` to the status window. It points
at the main checkout, not this worktree.

### 2. Starting point — done

- Worktree `.claude/worktrees/review-relaunch` on `feat/renovation`, branched from `main` at `fc5310f`.
- `nbr-repo-setup` survey (results below). Setup itself waits until the scope is clear.

### 3. Scope grill — done

The result is the Scope section above.

### 4. Interface design — done

The Design canvas artifact holds the M1 flow, with draft keymaps as notes beside each view.

### 5. Dependencies and rendering — done

iter renders diffs itself in pure Lua; no binary dependency for M1.

- Hunks come from git's unified diff, so staging applies exactly what git produced. The full old and new file
  contents are fetched separately for syntax and context expansion; when they don't match the diff text (filters,
  CRLF), only the hunk text is parsed.
- Data flow: parser (git text to hunks) → model (aligned rows per file: context, delete, add, gap, header, with old
  and new line numbers) → view (buffer lines and extmarks). Unified view is one projection of the model; side-by-side
  in M2 is a second one with filler rows.
- The buffer holds plain code. Row kinds show through line highlights, line numbers through a `statuscolumn` that
  reads the model, so yanking gives clean code and syntax columns need no offset.
- Syntax: a treesitter string parser per full file version, captures only for the rows shown, cached per blob.
- Word emphasis: changed lines are paired with `vim.text.diff` and linematch, then token-diffed; emphasis is skipped
  when most of the line changed.
- Hidden context is gap rows in the model that expand in batches, not native folds.
- Comments are `virt_lines` extmarks on the matching row; deleted-line comments sit on the delete row, file comments
  on the header row.
- Highlight groups (`IterDiffAdd`, `IterDiffDelete`, their `Text` and `Nr` variants, gap, header, comment) derive
  from the colorscheme on every `ColorScheme` event.
- A binary such as libvscode-diff would only add moved-code detection and finer changes on very long lines. That is
  a later decision for Nik, outside M1.

### 6. Draft, inspect, plan — done

The M1 plan below holds the inspection, the module sketch and the slices.

## M1 plan

### Inspection

| File | Verdict | Reason |
| ---- | ------- | ------ |
| `plugin/iter.lua` | adapt | Gains the `status` and `review` subcommands with completion. |
| `lua/iter/init.lua` | replace | Becomes the thin API: `setup`, `status`, `review`, `comment`, `comments`, `yank`, `statusline`. |
| `lua/iter/config/init.lua` | replace | Keymap areas and list-of-entries merging give way to `keys.<view>.<action> = lhs or false`. |
| `lua/iter/config/defaults.lua` | replace | Commit, push, filter and split options go; drawer, diff, export and refresh options come in. The highlight specs carry over. |
| `lua/iter/git.lua` | adapt | Keep `run`, `run_async`, `parse_status`, `status_snapshot`, stage, unstage, discard, `apply_hunk`, `diff`, `upstream`. Debt: `root_opts()` spawns `git rev-parse` before every action; `run` logs whole stdout (full diffs) at INFO on every call. |
| `lua/iter/health.lua` | adapt | `if vim.fn.executable('git') then` is always true (0 is truthy in Lua); checks Neovim 0.10 and diffs.nvim. |
| `lua/iter/log.lua` | keep | Small and fine. |
| `lua/iter/ui/render.lua` | keep | `IterRenderLine` plus `apply` suits the drawer, help and picker. |
| `lua/iter/ui/highlight.lua` | replace | Folded into `iter.highlight`, which also derives the diff groups. |
| `lua/iter/ui/buffer.lua` | delete | Thin wrapper; `set_lines` returns early on an empty list, so a buffer can't be cleared. |
| `lua/iter/ui/utils.lua` | delete | Entirely commented out. |
| `lua/iter/ui/diff/parser.lua` | keep | `parse_hunk_header`, `parse_lines` and `parse_hunks` feed the model. `line_at_raw_row` and `assign_stacked_rows` go. |
| `lua/iter/ui/diff/position.lua` | delete | Rows carry their own numbers. `old_line_to_new_line` moves into `iter.diff.model` for `gf` from a staged diff. |
| `lua/iter/ui/diff/diffs_nvim.lua` | delete | iter renders diffs itself. |
| `lua/iter/ui/status/init.lua` | replace | Split window becomes the drawer float. The debounced fs watcher moves to `iter.watch`; it builds `root .. '/.git/index'`, which doesn't exist in a linked worktree, where `.git` is a file, so auto-refresh is dead in this worktree. |
| `lua/iter/ui/status/window.lua` | replace | `capture_winopts`/`restore_winopts` move into the diff view, which borrows the pane's window. |
| `lua/iter/ui/status/keymaps.lua` | replace | Generic `iter.keymap`. The debounced `CursorMoved` preview-follow carries over to the drawer. |
| `lua/iter/ui/status/actions.lua` | adapt | File stage, unstage and discard with confirm move into the drawer; commit, push and visual selection go. |
| `lua/iter/ui/status/formatting.lua` | replace | Two-column drawer rendering. `status_group_for` and the section classification carry over. |
| `lua/iter/ui/status/selection.lua` | replace | Selection becomes `(row, column)`; restoring by item key carries over. |
| `lua/iter/ui/status/help.lua` | replace | Generic help float built from the view's keys. |
| `lua/iter/ui/status/common.lua` | keep | Becomes `iter.util` (notify, `is_valid_win`). |
| `lua/iter/ui/status/preview.lua` and `preview/*` | delete | Built around diffs.nvim. `hunks.hunk_patch` moves to `iter.diff.patch`; `rail.lua` shows the statuscolumn pattern for the view. |

`file_change_counts` and `current_file_change_counts` are public, but neither dots nor `~/.config/nvim` calls them.

### Modules

| Module | Responsibility |
| ------ | -------------- |
| `iter` | Public API and `setup()`. |
| `iter.config` | Defaults, validation, resolution. |
| `iter.keymap` | Binds a view's keys to handlers on a buffer; lists them for help. |
| `iter.git` | Process layer, status, blobs (`show :path`, `HEAD:path`), `hash-object`, `ls-files` for untracked dirs, `git-path`, repo identity. |
| `iter.changes` | Snapshot → Unstaged and Staged item lists, untracked directory expansion. |
| `iter.watch` | Debounced refresh from directory watchers on the parents of `git rev-parse --git-path index` and `HEAD`, filtered to the filenames `index` and `HEAD` (git renames `index.lock` over `index`, which kills a file watcher), plus `FocusGained`, `BufWritePost` and a poll while a drawer is open. |
| `iter.highlight` | All `Iter*` groups, rederived on `ColorScheme`. |
| `iter.diff.parser` | Git diff text → hunks and lines. |
| `iter.diff.model` | Hunks and blobs → rows; gap expansion; line mapping. |
| `iter.diff.syntax` | Treesitter captures per blob, cached by oid. |
| `iter.diff.words` | Word ranges for paired del/add rows. |
| `iter.diff.view` | `IterDiffView`: buffer, statuscolumn rail, extmarks, cursor → row. |
| `iter.diff.patch` | Hunk → patch lines for `git apply`. |
| `iter.ui.float` | Float placement anchored to a window, zindex, reposition on resize. |
| `iter.ui.drawer` | `IterDrawer` for the status and review contexts. |
| `iter.ui.help` | Help float from a view's keys. |
| `iter.ui.render` | Render lines with highlights. |
| `iter.review` | `IterReview` tab. |
| `iter.store` | Per repo and branch JSON: comments and viewed records. |
| `iter.comments.anchor` | Create anchors, resolve them against a version's lines. |
| `iter.comments.editor` | Comment float and the `<C-t>` draft lifecycle. |
| `iter.comments.marks` | `virt_lines` in diff views and normal buffers. |
| `iter.comments.picker` | Picker float. |
| `iter.viewed` | Viewed state per file: viewed, changed, unviewed. |
| `iter.export` | Review text, clipboard, clear prompt. |
| `iter.util` | Notify, window checks. |

```lua
---@class IterOptions           -- setup(); every field optional
---@field drawer? { height?: number, zindex?: integer, breakpoint?: integer }
---@field diff? { expand_step?: integer, syntax_max_lines?: integer, word_diff?: boolean }
---@field export? { intro?: string }
---@field refresh? { poll_ms?: integer }
---@field confirm? { discard?: boolean }
---@field keys? table<IterView, table<string, string|string[]|false>>
---@field debug? boolean

---@alias IterView 'drawer'|'review_drawer'|'diff'|'comment'|'picker'|'help'

-- Defaults:
-- drawer = { height = 0.3, zindex = 40, breakpoint = 80 }
-- diff = { expand_step = 20, syntax_max_lines = 20000, word_diff = true }
-- export.intro = 'I reviewed your changes and have these comments. Please address them.'
-- refresh.poll_ms = 2000, confirm.discard = true
-- keys.drawer = { open = '<CR>', stage = 's', unstage = 'u', discard = 'd', expand = '<Tab>',
--   review = 'r', close = 'q', help = '?', column_left = 'h', column_right = 'l' }
-- keys.review_drawer = { open = '<CR>', stage = 's', unstage = 'u', discard = 'd', expand = '<Tab>',
--   viewed = 'v', mode = 'm', comment_file = 'C', picker = 'L', yank = 'y', close = 'q', help = '?',
--   column_left = 'h', column_right = 'l' }
-- keys.diff = { next_hunk = ']c', prev_hunk = '[c', next_comment = ']a', prev_comment = '[a',
--   next_file = ']f', prev_file = '[f', stage = 's', unstage = 'u', comment = 'c', comment_file = 'C',
--   edit = 'e', delete = 'x', expand = '<CR>', goto_file = 'gf', viewed = 'v', mode = 'm',
--   picker = 'L', yank = 'y', close = 'q', help = '?' }
-- keys.comment = { save = '<C-s>', toggle = '<C-t>', cancel = '<C-c>', close = 'q' }
-- keys.picker = { next = '<C-n>', prev = '<C-p>', jump = '<CR>', edit = '<C-e>', delete = '<C-x>',
--   close = '<Esc>' }
-- keys.help = { close = { 'q', '?', '<Esc>' } }

---@alias IterSide 'unstaged'|'staged'

---@class IterChange            -- one drawer item
---@field path string
---@field orig_path? string
---@field side IterSide
---@field code string            -- porcelain letter for this side: M A D R C U ?
---@field dir? boolean           -- untracked directory
---@field expanded? boolean
---@field children? IterChange[]

---@class IterChanges
---@field root string
---@field branch string          -- 'HEAD' when detached
---@field ahead? integer
---@field unstaged IterChange[]  -- untracked last
---@field staged IterChange[]

---@class IterDiffRow
---@field kind 'header'|'hunk'|'context'|'del'|'add'|'gap'
---@field text string            -- plain code, no +/- prefix
---@field old? integer
---@field new? integer
---@field hunk? integer          -- index into IterFileDiff.hunks
---@field pair? integer          -- row of the paired del/add
---@field words? integer[][]     -- byte ranges { start, end }
---@field gap? { old: integer, new: integer, count: integer }

---@class IterFileDiff
---@field path string
---@field orig_path? string
---@field side IterSide
---@field code string
---@field raw string[]           -- git diff text, source for patches
---@field hunks IterDiffHunk[]
---@field rows IterDiffRow[]
---@field old_lines? string[]    -- unstaged: index; staged: HEAD
---@field new_lines? string[]    -- unstaged: worktree; staged: index
---@field binary boolean
---@field stat { add: integer, del: integer }

---@class IterDiffView
---@field buf integer
---@field win integer
---@field files IterFileDiff[]   -- one in file mode
---@field rows IterDiffRow[]     -- concatenated
---@field file_ranges { first: integer, last: integer }[]
---@field saved_winopts table    -- restored when the view leaves a user window

---@class IterAnchor
---@field path? string           -- nil for scope 'review'
---@field side 'old'|'new'
---@field base? 'HEAD'|'index'   -- old side: version the deleted line came from
---@field start_line? integer
---@field end_line? integer
---@field lines? string[]        -- anchored text, for re-anchoring and export

---@class IterComment
---@field id string
---@field scope 'line'|'range'|'file'|'review'
---@field anchor IterAnchor
---@field body string
---@field outdated boolean
---@field created_at integer
---@field updated_at integer

---@class IterViewed            -- store.viewed[path]
---@field hash string            -- git hash-object of the worktree file, 'deleted' when missing
---@field at integer

---@class IterStoreFile          -- stdpath('data')/iter/<repo-id>/<branch>.json
---@field version 1
---@field comments IterComment[]
---@field viewed table<string, IterViewed>

---@class IterDrawerRow
---@field unstaged? IterChange
---@field staged? IterChange

---@class IterDrawer
---@field context 'status'|'review'
---@field pane integer           -- window the float is anchored to
---@field win? integer
---@field buf integer
---@field changes IterChanges
---@field rows IterDrawerRow[]   -- buffer line → cells
---@field column IterSide        -- selected column
---@field layout 'columns'|'stacked'
---@field on_select fun(change: IterChange?)

---@class IterReview
---@field tab integer
---@field diff_win integer
---@field spacer_win integer     -- bottom split the drawer float covers
---@field drawer IterDrawer
---@field view IterDiffView
---@field mode 'file'|'all'
---@field current? { path: string, side: IterSide }
```

Rules the sketch relies on:

- Store path: `<repo-id>` is the basename of the main worktree plus the first 8 hex of the sha256 of the resolved
  `git rev-parse --git-common-dir`, so linked worktrees share one store. `<branch>` is the branch name with `%` and
  `/` percent-encoded (`feat%2Frenovation.json`); detached HEAD uses `HEAD.json`, which no branch can be named.
  Writes go to a temp file and are renamed into place.
- Anchors resolve with one function, `anchor.resolve(anchor, lines) → start, end | nil`: an exact block match at the
  stored lines first, then the match nearest to them. The persisted anchor follows the worktree file for the new
  side, and the `base` version (HEAD or index) for the old side; `outdated` is set when it isn't found and cleared
  when it is found again. A diff view places a comment by resolving against its own version without persisting.
- Viewed state: viewed when the stored hash equals the current worktree hash, changed when it differs, unviewed
  without a record. Staging doesn't change it. Hashes are recomputed on every refresh from `iter.watch`, batched
  with `git hash-object --stdin-paths`.
- The drawer float uses `relative = 'win'`, `anchor = 'SW'` at the bottom of its pane, the pane's width, and
  `drawer.zindex` (default 40, above radar's 20). Help, picker and comment floats set an explicit zindex of
  `drawer.zindex + n`.
- In the status context the pane above the drawer shows the diff view in place of its buffer while the drawer is
  open. The view saves the window-local options it changes and restores them before it switches the window back to
  another buffer, on every exit path. In the review tab the drawer float covers a spacer split of its own height, so
  the diff pane is never hidden under it.
- Discard never touches the index or ignored files: an unstaged row restores from the index, an untracked dir
  deletes only its listed untracked files, and the confirm names the paths. The Staged column has no discard.
- Comment counts appear only in the review drawer, never in the status drawer.

### Slices

Each slice leaves `just checks` green and the plugin usable.

#### S1 · Config, keymap layer, `:Iter` subcommands

- Goal: `setup()` takes `keys.<view>.<action>` (lhs or `false`) and the new options; `:Iter` and `:Iter status` open
  the existing status window through the new keymap layer.
- Files: `plugin/iter.lua`, `iter/init.lua`, `iter/config/*`, new `iter/keymap.lua`, `ui/status/keymaps.lua`,
  `ui/status/help.lua`, `ui/status/actions.lua`, `iter/git.lua`, `tests/test_config.lua`, `tests/test_git.lua`.
- Accept: remapping a key and disabling one with `false` work; unknown views, actions or option types raise a clear
  error; `:Iter foo` errors and completion lists the existing subcommands; outside a git repo `:Iter` warns and opens
  nothing.
- Tests: functional resolve and validation cases; child UI for remap, disable, outside-repo warning.
- Removes: commit, push, force push, filter, `l`/`al` split, scroll, `S`/`U`, visual `s`/`u`, `D` and their actions;
  `git.commit_file`, `commit_template`, `push`, `push_async`, `push_destination`; `confirmations.force_*`; the test
  `push() reports edge cases`.

#### S2 · Diff model and view core

- Goal: parser → model → `IterDiffView` renders one file's diff with the rail, row highlights, hunk rows and
  expandable gaps; usable standalone, not wired into the UI yet.
- Files: new `iter/diff/model.lua`, `iter/diff/view.lua`, `iter/highlight.lua`, `iter/git.lua` (blobs),
  `tests/test_diff_model.lua`, `tests/test_diff_view.lua`.
- Accept: rows hold plain code with correct old/new numbers for modified, added, deleted, untracked, renamed and
  binary files; blob lines that don't match the diff fall back to hunk-only rows; `statuscolumn` shows old and new
  numbers and blanks on virtual lines; a gap expands in batches and fully when few lines remain; `IterDiff*` groups
  follow `ColorScheme`; the borrowed window gets its saved options back before it shows another buffer.
- Tests: functional model cases per file state and gap expansion; child UI screenshot of a two-hunk file with a gap;
  all borrowed `vim.wo` values equal the originals after the view leaves the window.
- Removes: nothing.

#### S2b · Float, changes and util modules

- Goal: float placement, the changes list and the shared helpers exist standalone with tests, not wired into the UI.
- Files: new `iter/ui/float.lua`, `iter/changes.lua`, `iter/util.lua`; `iter/git.lua` (`ls-files` for untracked dirs,
  ahead count), `tests/test_float.lua`, `tests/test_changes.lua`.
- Accept: `float` places a window at the bottom of a given window with `relative = 'win'`, `anchor = 'SW'`, its
  width and a given zindex, and repositions it on resize; `changes` builds Unstaged (untracked last) and Staged from
  a snapshot, expands an untracked dir to its untracked files without ignored ones, and truncates paths from the left
  with `…`.
- Tests: functional `changes` from the fixture repo (renamed, untracked dir, ignored file in it) and truncation; child
  UI float config and position after a resize.
- Removes: nothing.

#### S3 · Drawer float

- Goal: `:Iter status` opens the drawer float at the bottom of the current pane with Unstaged and Staged, file and
  directory staging, and the preview in the pane following the selection through `IterDiffView`.
- Files: new `iter/ui/drawer.lua`; `iter/init.lua`, `iter/git.lua`, `iter/ui/float.lua`, `iter/changes.lua`,
  `tests/test_ui_drawer.lua`.
- Accept: columns side by side from `drawer.breakpoint` (80) and stacked below; `j`/`k` move and the preview follows
  (debounced), `h`/`l` switch column; `s`/`u` act on a file or untracked dir and keep the selection on the nearest row;
  `d` (confirm naming the paths) on an unstaged row restores from the index only, so a staged part survives, and on
  an untracked dir deletes only its listed untracked files; `d` in the Staged column is not bound and warns "unstage
  first"; `<Tab>` expands an untracked dir; `<CR>` opens the file in the pane and closes the drawer (deleted files keep
  the drawer and the preview); `q` closes and restores the pane; `r` is not bound yet; the float keeps its place after
  pane resizes and draws above other floats at a lower zindex.
- Tests: child UI screenshots at 80 columns and in a 60-column split; stage via `s`; declined discard confirm changes
  nothing; discard on a file with staged and unstaged changes keeps the staged part; untracked-dir discard leaves an
  ignored file; a fake float at zindex 20 sits under the drawer; after `<CR>`, after `q` and after wiping the pane's
  buffer while the drawer is open, all borrowed `vim.wo` values equal the originals; resize.
- Removes: `ui/status/**`, `ui/buffer.lua`, `ui/utils.lua`, `ui/highlight.lua`, `ui/diff/diffs_nvim.lua`,
  `ui/diff/position.lua` (its `old_line_to_new_line` moves to `iter.diff.model`, its test case to
  `tests/test_diff_model.lua`), `line_at_raw_row` and `assign_stacked_rows` with their tests,
  `tests/test_ui_status.lua`, `tests/screenshots/status-fixture-entries`, `tests/test_diff_position.lua`.

#### S4 · Drawer header, help, empty states, refresh

- Goal: the drawer shows its header and key hint line, opens a help float on `?`, handles a clean tree, and
  refreshes itself in normal and linked worktrees.
- Files: new `iter/ui/help.lua`, `iter/watch.lua`; `iter/ui/drawer.lua`, `iter/git.lua`, `iter/health.lua`,
  `justfile`, `tests/minimal_init.lua`, `tests/test_ui_drawer.lua`, `tests/test_watch.lua`.
- Accept: header `HEAD <branch> ↑<ahead> · <n> changes`; `?` lists the drawer's current keys including remaps and
  closes on `q`, `?`, `<Esc>`, with zindex `drawer.zindex + 10`; a clean tree shows "Working tree clean"; external
  `git add` updates the drawer in a linked worktree, also the second time; selection survives refresh. Health checks
  Neovim 0.12 and `git` with `executable() == 1`, without diffs.nvim; `git.run` logs commands, not their output.
- Tests: child UI screenshots of help and clean tree; two consecutive external `git add` in a temp linked worktree
  each refresh the drawer.
- Removes: the diffs.nvim pin in `justfile`, its rtp entry in `tests/minimal_init.lua`, the health check for it.

#### S5 · Syntax and word diff

- Goal: diff rows get treesitter syntax from the full blobs and word emphasis on paired changed lines.
- Files: new `iter/diff/syntax.lua`, `iter/diff/words.lua`; `iter/diff/view.lua`, `tests/test_diff_words.lua`,
  `tests/test_diff_view.lua`.
- Accept: del rows take captures from the old blob, add and context from the new; files above the size cap render
  without syntax; emphasis is skipped above ~60% changed, ~500 chars per line or 60-line groups; results ignore a
  stale render generation.
- Tests: functional word ranges (ASCII, UTF-8, punctuation, mostly changed); child UI screenshot of a Lua fixture
  (bundled parser) showing syntax and word emphasis.
- Removes: nothing.

#### S6 · Review tab

- Goal: `r` in the drawer and `:Iter review` open the review tab (or switch to it) with the diff pane, the drawer on a
  spacer split, and navigation.
- Files: new `iter/review.lua`; `iter/init.lua`, `plugin/iter.lua`, `iter/ui/drawer.lua`, `iter/diff/view.lua`,
  `tests/test_ui_review.lua`.
- Accept: one review tab at most; review drawer keys `j`/`k`, `<CR>` into the diff pane, `s`/`u`/`d`, `<Tab>`, `q`
  closes the tab; no `r`; diff pane `]c`/`[c` hunks, `]f`/`[f` files in drawer order, `<CR>` on a gap expands it,
  `gf` opens the file at the line in the previous tab (staged rows mapped through the unstaged diff), `q` closes the
  tab; `r` in the status drawer is bound from this slice on; the diff pane's cursor row stays visible above the
  drawer; the diff pane re-renders on external changes and keeps the cursor near its row; on a clean tree the tab
  opens with an empty diff pane; `require('iter').statusline()` returns `review · <file> · <i>/<n>` inside the tab
  and `''` elsewhere; closing the tab leaves no borrowed window options changed.
- Tests: child UI screenshot of the tab; open twice gives one tab; cursor at the last diff row stays visible;
  `gf` target line for unstaged and staged rows; an external file write re-renders the diff pane; `statusline()`
  values; borrowed `vim.wo` values after tab close.
- Removes: nothing.

#### S7 · Hunk staging in the diff pane

- Goal: `s`/`u` in the review diff pane stage or unstage the hunk under the cursor.
- Files: new `iter/diff/patch.lua`; `iter/review.lua`, `tests/test_diff_patch.lua`, `tests/test_ui_review.lua`.
- Accept: the patch is exactly git's hunk with the file header; `s` only on unstaged rows, `u` only on staged rows,
  else a warning; `git apply --check` runs first, and on failure iter refreshes and warns without applying; after
  apply the cursor stays on the nearest remaining hunk and the drawer updates.
- Tests: functional patch for first, middle and last hunks, new and deleted files; child UI stage and unstage of one
  hunk out of two, checked with `git diff --cached`; a stale hunk (file changed after render) warns and changes
  nothing.
- Removes: nothing.

#### S8 · Store and anchors

- Goal: comments and viewed records persist per repo and branch, and anchors resolve against changed text.
- Files: new `iter/store.lua`, `iter/comments/anchor.lua`; `iter/git.lua`, `tests/test_store.lua`,
  `tests/test_anchor.lua`.
- Accept: path, encoding and detached-HEAD rules above; a linked worktree on the same repo sees the same repo id;
  writes are atomic; each write re-reads the file and merges by comment id, so two Neovim instances don't drop each
  other's comments; a missing file loads as empty; a corrupt file is renamed to `<name>.corrupt-<timestamp>`, then
  loads as empty with one warning; the store path re-resolves when HEAD changes; resolve keeps, moves, marks outdated
  and un-outdates per the rules above.
- Tests: functional store round trip, branch encoding, worktree identity in a temp repo; corrupt file kept aside;
  two interleaved writers keep both comments; a checkout switches to the other branch's file; anchor cases for
  unchanged, shifted, edited, deleted, duplicated text (nearest wins), old side.
- Removes: nothing.

#### S9a · Comment marks in diff views

- Goal: stored comments show as `virt_lines` in diff views, with `]a`/`[a`.
- Files: new `iter/comments/marks.lua`; `iter/diff/view.lua`, `iter/review.lua`, `iter/ui/drawer.lua`,
  `tests/test_ui_marks.lua`.
- Accept: line and range comments sit under their last row, deleted-line comments on the del row, file comments on
  the header row; outdated comments are dimmed and labelled; text wraps to the window and rewraps on `WinResized`;
  review drawer rows and header show comment counts, the status drawer none; `]a`/`[a` only in iter buffers.
- Tests: child UI screenshot of a diff with each comment kind; `]a`/`[a` order; no counts in the status drawer.
- Removes: nothing.

#### S9b · Comment marks in normal buffers

- Goal: normal file buffers in the repo show their comments and keep them anchored as the file changes.
- Files: `iter/comments/marks.lua`, `iter/init.lua`, `tests/test_ui_marks.lua`.
- Accept: buffers of repo files show comments after `BufWinEnter`; `BufWritePost` re-anchors and persists; comments
  that can't be found again turn outdated.
- Tests: child UI screenshot of a normal buffer; re-anchor after inserting lines above and saving; outdated after
  deleting the anchored line.
- Removes: nothing.

#### S10 · Comment float

- Goal: `c` (line or visual range), `C` (file), `e` (edit), `x` (delete) and `require('iter').comment()` write
  comments through a float editor with the draft lifecycle.
- Files: new `iter/comments/editor.lua`; `iter/review.lua`, `iter/ui/drawer.lua` (`C`), `iter/init.lua`,
  `tests/test_ui_editor.lua`.
- Accept: opens in insert mode; `<C-s>` (insert and normal) and `:w` save, `:wq` saves and closes; `<C-t>` hides and
  shows the float in the same place, mapped inside the float in insert and normal mode and globally in normal mode
  only while a draft exists, and any user `<C-t>` mapping is saved and restored; `<C-c>` drops the draft; `q` closes
  only when saved; one draft at a time; `require('iter').statusline()` includes `draft comment` while hidden;
  `comment({ scope = 'review' })` adds a review comment; `x` confirms; the float uses zindex `drawer.zindex + 20`.
- Tests: child UI for save via each path, hide and show, restore of a user `<C-t>` map, no iter `<C-t>` map left after
  save and after cancel, `q` refusal, visual range anchor, normal-buffer comment.
- Removes: nothing.

#### S11 · Comment picker

- Goal: `L` and `require('iter').comments()` open a picker grouped by file that filters as you type.
- Files: new `iter/comments/picker.lua`; `iter/review.lua`, `iter/ui/drawer.lua`, `iter/init.lua`,
  `tests/test_ui_picker.lua`.
- Accept: groups in drawer order with the review group last; `<C-n>`/`<C-p>` move; `<CR>` jumps to the review tab
  when it is open and the file is in the changes (old-side comments always go there, opening it), else to the file
  buffer at the line; `<C-e>` edits, `<C-x>` deletes after confirm, `<Esc>` closes; outdated comments marked; zindex
  `drawer.zindex + 10`.
- Tests: child UI screenshot; filter narrows; jump lands on the anchored line.
- Removes: nothing.

#### S12 · Viewed marks

- Goal: `v` toggles a file viewed; drawer rows show `○`/`✓`/`↻` and the review header counts.
- Files: new `iter/viewed.lua`; `iter/ui/drawer.lua`, `iter/review.lua`, `iter/watch.lua`, `tests/test_viewed.lua`,
  `tests/test_ui_review.lua`.
- Accept: viewed survives restart and staging; an edit from outside Neovim turns it into "changed since viewed"
  within one refresh; the diff header shows the state; header
  `viewed <n> of <m> · ↻ <k> changed · <c> comments · <o> outdated`; the status drawer shows no viewed marks and
  no comment counts.
- Tests: functional state for viewed, changed, deleted, unviewed; child UI after an external file write.
- Removes: nothing.

#### S13 · Export

- Goal: `y` and `require('iter').yank()` copy the review and ask once whether to clear it.
- Files: new `iter/export.lua`; `iter/review.lua`, `iter/ui/drawer.lua`, `iter/init.lua`, `tests/test_export.lua`.
- Accept: `export.intro`, then a numbered list: `file:line`, `file:start-end`, `(old side)`, `(outdated)`,
  `file (file)`, `Review`; fenced code with the filetype's language; comment text; files in drawer order, review last;
  copies to `+` (and `"`); prompt `Copied <n> comments. Clear them? [y/N]`, `y` clears, `n`/`<Esc>` keeps; nothing to
  copy warns.
- Tests: functional exact text for a fixture store; child UI for both prompt answers.
- Removes: nothing.

#### S14 · Cleanup

- Goal: docs and leftovers match the code.
- Files: `README.md`, `docs/CONVENTIONS.md`, `ROADMAP.md`, `nvim_test.lua`, `iter/git.lua`, `iter/init.lua`,
  `tests/test_git.lua`.
- Accept: README documents `:Iter`, the API and `setup()` keys; CONVENTIONS says Neovim 0.12 and no diffs.nvim;
  `grep -r diffs lua tests` is empty; no unused modules.
- Tests: suite stays green.
- Removes: `file_change_counts`, `current_file_change_counts` and their tests, `nvim_test.lua`.

#### S15 · Continuous all-files mode (M2)

Milestones put continuous scroll in M2, so this slice is not part of M1; `m` stays unmapped until then.

- Goal: `m` switches the review diff pane between one file and all changed files in one scroll.
- Files: `iter/diff/view.lua`, `iter/review.lua`, `iter/diff/syntax.lua`, `tests/test_ui_review.lua`.
- Accept: files concatenate with header rows in drawer order; `]f`/`[f` and drawer selection follow the cursor;
  syntax, words and comment marks render per viewport; staging, comments and viewed work the same in both modes.
- Tests: child UI screenshot of three files; drawer follows the cursor across a file boundary.
- Removes: nothing. No earlier slice depends on it.

## Collected findings

Items to fold into the scope and plan.

- radar.nvim's bottom panel is a float at zindex 20 and needs a configurable zindex option too. That change belongs
  to the radar.nvim repo, outside this run.
- Agent verification: a test setup the agent can run on its own, including driving the real drawer and review flow
  in a headless or scripted Neovim, so changes are checked without Nik.
- Repo setup: run `nbr-repo-setup` (all topics plus release media recorded with `nbr-record-clip`) once the
  dependencies are settled.
- Repo setup survey:
  - `agent-tooling`: `AGENTS.md` exists but is not lean; no `.agents/skills/`, no `.claude/skills` link;
    `.pi/extensions/checks.ts` still names flux.nvim.
  - `git`: `.githooks/pre-commit` runs `just checks` but `core.hooksPath` is unset, so it never runs.
  - `docs-structure`: `ROADMAP.md` and `handoffs/` at the root; `docs/CONVENTIONS.md` calls diffs.nvim required.
  - `workflow`: tag-push `release.yml` and `nightly.yml`, no release-please, no `CHANGELOG.md`; `test.yml`
    duplicates `tests.yml` and cannot pass.
  - `dependencies`: plenary and diffs.nvim pinned in `justfile`, no upgrade skill.
  - Release media: clips recorded with `nbr-record-clip`.
- `nvim_test.lua` at the root loads iter from `~/personal/iter.nvim` and sets options that no longer exist.
