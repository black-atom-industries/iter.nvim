# Conventions

These conventions apply to all project changes.

## Scope

iter is a Neovim-native staging and code review tool. It joins a minimal status menu (from
[minifugit.nvim](https://github.com/vieitesss/minifugit.nvim)), [tuicr](https://github.com/agavra/tuicr)'s
one-scroll review with annotations, reviewed marks and an export for agents, and
[annotator.nvim](https://github.com/chpeters/annotator.nvim)'s annotations in normal buffers.

Out of scope: committing, pushing, pulling and hosted pull requests (iter reviews a checked-out branch against a base
and never talks to a host; the Git actions stay with a Git plugin such as mini.git), Jujutsu and Mercurial, merge conflict resolution, branch management, stash, a log browser, annotation types, and sending
the review straight to an agent pane.

## Architecture

- The review compares the worktree with a base. Without a base the old side is `HEAD` for a staged file and the index
  for an unstaged one. With a base the old side is the base's tree and the new side is always the worktree, because
  annotations, reviewed marks and the outdated rule anchor to the worktree. Ranges that end at another commit are out.
- A base is a spec, resolved by `git.resolve_base` on every refresh: `{ kind = 'branch', ref }`,
  `{ kind = 'commit', sha }` or `{ kind = 'rev', ref, sha }`. A branch resolves to its merge-base with HEAD, so it
  follows the branch moving. A commit, picked from the `b` list, resolves to its parent, so the commit is part of the
  review; a root commit resolves to the empty tree. A rev, a ref typed after `:Iter review` or passed as
  `iter.review({ base })` that isn't a branch, keeps the ref as typed and the sha it named then, and resolves to that
  commit itself, git's usual "since". `git.base_spec` turns a typed ref into a branch or a rev spec. A commit or rev that
  is no longer an ancestor of HEAD, such as after a rebase, doesn't resolve. A base that no longer resolves warns, and
  the review shows working changes; it is cleared from the store, except right after a checkout, where the new
  branch's stored base stays. On a detached HEAD a picked base applies to the open review and is not stored, since every
  detached checkout shares one store file.
- The review names a base with `changes.base_text`, in the header and the export alike: `since main (a1b2c3d)` for a
  branch with its merge-base, `since v1.0 (a1b2c3d)` for a rev with its commit, `from a1b2c3d` for a picked commit.
  The column title (`changes.base_title`) drops the sha: `Since main`, `Since v1.0`, `From a1b2c3d`.
- The parent branch (`git.parent_branch`) is the branch HEAD was created from: the reflog's `Created from` line when
  that ref still exists, else the candidate (local branches and the remote default branch) whose merge-base with HEAD is
  the fewest commits back. Branches that contain HEAD don't count, and ties go to the default branch, then to a local
  branch over a remote one. The default branch is the target of `origin/HEAD`, else `main`, else `master`. On the default
  branch there is no parent: the picker presets working changes and offers the merge base with the upstream after it.
- The base picker (`iter.ui.picker`) titles its Branches and Commits with `virt_lines`, so a buffer line is an item's
  index.
- Against a base the drawer has one file column beside Annotations: one diff per file, the changes from
  `git.base_changes` (`git diff -M --name-status` against the resolved sha plus the untracked files of the status read
  the poll already made). Stage, unstage,
  discard and ignore refuse there, in the drawer and in the diff pane. Working changes keeps Unstaged and Staged.
- Diff flow: git's unified diff → `iter.diff.parser` (hunks) → `iter.diff.model` (rows: header, hunk, context, del,
  add, gap, each with old and new line numbers) → `iter.diff.view` (buffer lines and extmarks). Hunks always come from
  git's diff, so staging applies exactly what git produced. The full old and new file contents are fetched for syntax
  and context; when they don't match the diff text (filters, CRLF), only the hunk text is used.
- A view renders a document (`iter.diff.document`): sections in order, one per file diff, and for each buffer line
  its section and model row (none on the blank line between two files). One file is a document of one section; the
  review's all-files mode is one section per drawer file, Unstaged then Staged. Callers map lines with `at()` and
  `line_of()`, and a selection to model rows with `rows_in()`, never with offsets.
- The split layout (side by side) is a document whose lines carry a model row per side. `model.pairs` pairs the del
  and add rows of each change group (linematch, one by one above 60 lines); a pair shares a line, an unpaired del or
  add faces a filler row (`kind = 'filler'`), every other row shows on both sides. Word emphasis uses the same pairs.
  The view keeps its own window for the new side and opens the old side's pane left of it, with `scrollbind` and
  `cursorbind`; both have the same lines, and an annotation's `virt_lines` on one side get blank `virt_lines` of the
  same height on the other. Moves the code makes go through `View:sync()`, since the binds follow only the current
  window.
- A patch of selected lines (`patch.lines`) writes each change group in pair order, the split layout's: a deleted
  line next to the added line it pairs with, so a staged or unstaged line goes next to its partner, which stays unless the selection takes it too.
- A document of several files decorates per viewport: syntax, word emphasis and annotation `virt_lines` for the lines
  in view and two screens around them, again on `WinScrolled`; row highlights, headers and annotation positions cover
  the whole document. A read of all files keeps a file's rows, and so its parse, while its blob ids and worktree stat
  (`git.diff_ids`) stay the same.
- The diff buffer holds plain code. Row kinds show through line highlights and line numbers through a `statuscolumn`
  that reads the model, so a yank gives clean code.
- Syntax comes from a treesitter string parser per file version, cached per blob, with captures only for the rows
  shown. Word emphasis pairs changed lines with `vim.text.diff` and skips lines that mostly changed.
- Hidden context is gap rows in the model that expand in batches, not folds.
- A collapsed file (reviewed, in all-files mode) is a document section of its header row alone, in both layouts,
  not a fold. Its annotations are placed hidden on the header, so the header still counts them.
- The renderer is pure Lua. A binary dependency (such as libvscode-diff) comes in only after Nik decides for it.
- `Iter*` highlight groups derive from the colorscheme on every `ColorScheme` event.
- Annotations are `virt_lines` extmarks: line and range annotations under their last row, deleted-line annotations on
  the del row, file annotations on the header row.
- Anchors resolve with one function: an exact block match at the stored lines first, then the match nearest to them.
  A passage anchor (`quote` set, from a charwise `v` selection) also stores `start_col` and `end_col` (0-based bytes,
  the end exclusive) and up to 40 bytes of text `before` and `after` the quote. It resolves by the quote, as plain text
  on the word edges it had when stored: at the stored position when the context there is intact, else at the
  occurrence whose surroundings match best. Two equally good occurrences, or several with no matching context, make it
  outdated; one occurrence follows. An anchor without context takes the nearest occurrence. Resolving returns the
  columns, and `follow` refreshes the context. People and agents see columns as 1-based characters, not bytes.
- Annotated text is tinted with `IterAnnotationText`, from the lines `list.line_of` locates: the column range of a
  passage, every line of a line or range annotation whole to the window's edge (`line_hl_group`, empty lines and wrapped rows included), nothing for outdated, file and review annotations. The
  buffer marks and the diff view draw it at a priority under syntax and the visual selection. The colour is the
  `@function` foreground blended into `Normal`.
  The new side follows the worktree file, the old side its `base`: `HEAD`, `index`, or the full sha of the commit or
  tree a base resolved to. A sha-based old-side annotation shows in a base diff view while the view's resolved base is
  that sha, and stays in the Annotations column, the sidebar and the export, read from its own commit. Its labels
  name that commit by its short sha (`anchor.short_base`): `old a1b2c3d` in the Annotations column and the sidebar,
  `(old side, a1b2c3d)` in the export; an old side on `HEAD` or `index` reads `old` and `(old side)`.
- Outdated has one rule, `iter.annotations.list.line_of`: an annotation with text is outdated when the content of the
  version it follows lacks that text; the worktree's content is the loaded buffer's, else the file's. The Annotations
  column, the export, the diff view marks and the buffer marks all decide through it. Only without that content (or
  without text) does the stored `outdated` flag answer; it is a cache that `anchor.follow` updates when a written
  buffer moves or loses the text. A diff view places an annotation where its own version has the text, without
  persisting; a staged view whose index still has text the worktree lost places it there, outdated.
- Store: `stdpath('data')/iter/<main worktree basename>-<first 8 hex of sha256 of git-common-dir>/<branch>.json`, so
  linked worktrees share it. The branch name has `%` and `/` percent-encoded; a detached HEAD uses `HEAD.json`. Writes
  go through a temp file renamed into place, after re-reading and merging by annotation id, all under a lock file next
  to the store (`<branch>.json.lock`, created exclusively, holding a token of its instance). A held lock is waited for
  briefly with backoff; one older than the stale timeout (`LOCK_STALE_MS`) belongs to a dead instance and is taken over,
  once per write. While another instance holds it, the change stays in this instance (`store.cached` shows it), a
  warning says so, and the next write of that file saves it first. Leaving Neovim waits for the lock up to the stale
  timeout and takes it over then; a change it still can't save is reported as lost. The review drawer and the buffer
  marks read through one cache per root (`store.cached`), read again when the file's stat or HEAD changes.
- The store file also holds the branch's `base` (a base spec), the base the review opens with. A `base` or
  `reviewed_by_base` entry iter can't read is dropped on read without setting the file aside, so the annotations stay.
  Switching branches switches to that branch's stored base. Annotations are shared across bases.
- Reviewed: reviewed when the stored `git hash-object` of the worktree file equals the current one, changed when it
  differs, unreviewed without a record. Staging doesn't change it. A mark belongs to the base it was made against:
  working changes use `reviewed`, a base uses `reviewed_by_base[key]` with the key `branch:<ref>`, `commit:<sha>` or `rev:<sha>`
  (`reviewed.base_key`). Empty buckets are pruned.
- Discard never touches the index or ignored files: an unstaged row restores from the index, an untracked row deletes
  only its untracked files, and the confirm names the paths. The Staged column has no discard.
- The drawer float sits at the bottom of its pane (`relative = 'win'`, `anchor = 'SW'`) at `drawer.zindex`; the base
  picker `drawer.zindex + 5`, over the drawer's footprint with its chrome, so it shows there whatever picker plugin
  is installed; the help float uses `drawer.zindex + 10`, the annotation float `+ 20`. Every float follows editor and window resizes through
  `iter.ui.float`: the drawer through `float.open`, the help and annotation floats through `float.follow_resize`. In the
  review tab the drawer covers a spacer split of its own height, so it never hides the diff.
- In the status drawer the pane above shows the diff view in place of its buffer. The view saves the window-local
  options it changes and restores them on every exit path.
- The drawer's lines come from `iter.ui.layout`: pure functions from a list of column specs and the width to render
  lines, side by side at `drawer.breakpoint` and wider, stacked below it. A stack (`IterLayoutStack`) puts several
  specs as titled sections in one column; the review drawer's columns layout stacks Unstaged above Staged beside the
  Annotations column, below `drawer.wide_breakpoint` (from it they sit side by side), and `h` and `l` step between those columns, each keeping its last selection. There
  `layout.split` gives the Annotations column a layout of its own, shown in the float's side window (`IterFloatSide`):
  a focusable window over the right of the float's text rows at `drawer.zindex + 1`, with its own buffer, so the file
  list scrolls alone. The float opens, moves and closes it; the drawer closes when it is closed from outside, and
  focus moves into it only through `h` and `l`, opening the review on the Annotations column, and a resize that splits
  it off while an annotation is selected in the drawer. The drawer holds what the status and review
  drawers share; the review tab plugs in its reviewed marks, annotation counts, header, Annotations column, its preview
  and spacer sizing as the drawer's extras (`IterDrawerExtras`). Columns the extras add come after the file columns;
  their items carry a `key`, and `Drawer:selected()` returns files only.
- Reviewed marks, annotation counts and the Annotations column show only in the review drawer.
- iter's buffers carry `iter://` addresses as names, without buffer numbers (`iter.uri`): `BufReadCmd` on
  `iter://*` routes a buffer `:edit` made to what its name addresses and wipes it, after giving its window the previous
  buffer back. Each of iter's buffers is registered with the windows it belongs in and a redraw: `:edit` in one of
  them redraws it, and one shown in another window goes back to that window's previous buffer and routes too.
  iter's buffers stay unlisted, and a window is never handed one of them back. Addresses route only while the open
  drawer or review is of the current directory's repository. `util.name_buf` wipes another buffer of the new name
  unless it is a loaded buffer of iter's own (then the name stays with it), and wipes the buffer of the old name that
  `nvim_buf_set_name` leaves behind. `SessionLoadPost` wipes `iter://` buffers that aren't iter's own.
- The review tab carries its label in the tab variable `iter_label`; `iter.tabline` renders it for users who set
  'tabline' to it.
- The ahead and behind counts with the upstream's name, and the Recent commits section, show only in the status
  drawer. They count against the upstream as last fetched; iter never fetches. A poll reads HEAD and the upstream with
  one `git rev-parse`, and reads the counts (`rev-list --left-right`) and the commits (`log`) again only when either
  moved. Commit ages are computed at render from the committer date.
- The Recent commits section is a second, non-focusable float (`IterFloat`'s strip) pinned between the file area and
  the key hint line inside the drawer's footprint; only the file columns scroll. The float owns the strip and closes it
  with itself.
- The status header keeps `HEAD <branch>` whole and sheds from the right when it doesn't fit: the summary shrinks to
  the total, then goes, then the upstream, then the arrows.
- The export, the Annotations column and the sidebar list annotations through `iter.annotations.list`: files in drawer order,
  then other files by name, the review last; by line within a file, each resolved with `line_of`.
- Against a base the export names it in a paragraph after the intro, `Reviewed ` and the header's words:
  `Reviewed since main (a1b2c3d)`, `Reviewed since v1.0 (a1b2c3d)` or `Reviewed from a1b2c3d`. The line comes from the
  open review's base (`Review:since`), never
  from the stored one, and is the same for the drawer and the sidebar. Without a base the text has no such line.
- The annotation sidebar (`iter.ui.sidebar`) is a vertical split at the tab's edge, one per tabpage. Every sidebar
  redraws through `refresh_annotations` and the store watcher.
- `iter.annotations.statuscolumn` backs `require('iter').statuscolumn()`: a wrapped row of an annotated line draws the
  sign's bar in the sign column. It reads the sign extmarks of the buffer marks once per render and text change, never
  the store per row. iter never sets the global 'statuscolumn'; its own windows set a window-local one.
- Every list of annotations yanks one with `y` and all with `Y`, then asks whether to clear what was copied. On a file
  row `y` yanks that file's annotations.

## Project shape

- Keep the public `iter` entrypoints thin and move behavior into focused modules.
- `iter.diff.view` and `iter.git` read no config; their callers pass the options in (the view's `keys`,
  `expand_step`, `syntax_max_lines`, `word_diff` and `icon`, the `diff.args` of every `git.file_diff` and
  `git.file_diff_bytes`), so a staged patch comes from the same diff the view shows.
- Config types live in `lua/iter/config/types.lua`; `lua/iter/config/defaults.lua` holds only values.
- Separate data collection, formatting, and UI rendering. A good default flow is: Git/process output -> parsed data -> renderable lines -> buffer/window updates.
- Prefer small single-purpose modules over catch-all utility files.
- Model stateful UI pieces as table-based objects with `__index`; keep pure transforms and parsers as local helper functions or stateless modules.

## Lua style

- Follow the repo's Stylua rules: 4 spaces, 80-column width, Unix line endings, always-parenthesized calls, and a preference for single quotes.
- Use LuaLS annotations for non-trivial modules and APIs: `---@class`, `---@field`, `---@alias`, `---@param`, and `---@return`.
- Default to `local` functions and locals; only export what is part of a module API.
- Prefer early returns and explicit `nil` handling over deeply nested conditionals.
- Validate option tables and constructor inputs with `vim.validate`.

## Neovim API usage

- Prefer the Lua Neovim API (`vim.api`, `vim.fn`, `vim.system`) over stringly Vimscript-style code when a Lua API exists.
- Centralize shell/process interactions instead of spawning ad hoc commands from multiple places. Git access should go through shared helpers.
- Keep render steps side-effect free until the final buffer/window apply step.
- Reuse existing editor highlight groups first, then provide sensible fallback colors.

## Good practices

- Keep parsing and formatting logic deterministic and easy to inspect from plain strings/tables.
- `iter.log` writes plugin-internal diagnostics to the log file and never shows them. User notices go through
  `iter.util`: `util.warn` for something the user can act on (an action that doesn't apply where it was asked, or a
  state iter worked around), `util.error` for a failure of what the user asked (a git command, a read or a write).
  Both prefix `[iter] `, pass the title `iter` and write the notice to the log too. Nothing calls `vim.notify` or
  `vim.print` directly; health checks report through `vim.health`.
- Preserve compatibility assumptions already present in the project: Neovim 0.12+ and a working `git` executable.
- Run lints before committing: `just lint`. It checks at LuaLS's Hint level, the editor's, and reports zero problems.
- Run the test suite before submitting changes: `just test`. See README for details.
- For UI or git-status changes, validate against realistic repository states such as modified, untracked, renamed, and conflicted files when relevant.
- When creating commits, match the existing conventional-commit style seen in history (`feat:`, `fix:`, `refactor:`, `style:`, `chore:`).
