<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
  <img alt="iter.nvim: review, annotate, hand back, repeat" src="docs/assets/banner-light.svg">
</picture>

# iter.nvim

Iterate on code changes in Neovim: review, annotate, hand back, repeat.

Whether the changes are yours or an agent's, iter is the review half of the
loop. You read the diff, stage what is ready, annotate what is not, and copy
the annotations out as a prompt. When the code changes again, iter shows what
is new since your last pass.

iter does not commit, push or pull. Keep a Git plugin such as mini.git or
fugitive for that.

![The review tab: moving through the files, a annotates a line, r marks the file reviewed and moves on, the Annotations column lists the annotation](docs/assets/review.webp)

## Contents

- [The loop](#the-loop)
  - [See what changed](#see-what-changed)
  - [Review](#review)
  - [Annotate](#annotate)
  - [Hand back](#hand-back)
- [Install](#install)
- [Quick start](#quick-start)
- [Annotations outside iter](#annotations-outside-iter)
- [Reference](#reference)
  - [Status drawer](#status-drawer)
  - [Review tab](#review-tab)
  - [Keys](#keys)
  - [Configuration](#configuration)
  - [Lua API](#lua-api)
  - [Addresses](#addresses)
  - [Tab label](#tab-label)
  - [Events](#events)
  - [Highlight groups](#highlight-groups)
  - [Files](#files)
- [Development](#development)
- [Credits](#credits)

## The loop

### See what changed

`:Iter` opens the status drawer, a float at the bottom of the current window.
Unstaged and Staged sit side by side, stacked in narrow windows, and the
window above shows the diff of the selected file as you move. The header shows
the branch and how far it is ahead (`↑`) and behind (`↓`) its upstream, and
the last commits are pinned under the files.

`s`, `u` and `d` stage, unstage and discard whole files, and `I` adds an
untracked path to `.gitignore`. `r` opens the review.

![The status drawer: moving through the files previews each diff, s stages a file, ? lists the keys](docs/assets/drawer.webp)

### Review

The review tab holds the whole review: the review drawer below, the diff
above. iter draws the diff itself, with treesitter syntax, the changed words
emphasized, old and new line numbers, and hidden context that `<CR>` expands.
`m` shows every file in one scroll and `|` shows old and new side by side.
The status drawer and the review keep the layout you picked last, for the
whole Neovim session.

`r` marks a file reviewed and moves on to the next file you haven't reviewed.
On a reviewed file it just moves on, and `R` removes the mark.
A reviewed file that changes again turns `↻`, so the next pass shows what
moved. In all-files mode a reviewed file collapses to its header.

![All files: m shows every file, r collapses each reviewed file and moves to the next, | shows the diff side by side, - and m switch back](docs/assets/layouts.webp)

Stage as you go: `s` and `u` take the hunk under the cursor, or in visual
mode only the selected lines, applied like `git add -p`.

### Annotate

`a` annotates the line or the visual range, `A` the whole file. Annotations
also work in normal file buffers through `require('iter').annotate()`. They
follow their code when it moves and turn outdated when it is gone.

The Annotations column of the review drawer lists every annotation, with the
reviewed progress on top. Moving onto one shows it in the diff, `<CR>` jumps
there, `e` edits and `x` deletes.

### Hand back

`y` copies the review as a prompt for an agent: an intro, then every
annotation with its `file:line` and the code it is on. iter then asks whether
to clear the annotations, and the next round starts.

Annotations and reviewed marks are saved per repository and branch, and
linked worktrees share them. Drawers and the review refresh on their own when
the index, HEAD or the files change.

## Install

iter needs Neovim 0.12 or newer and `git` on `PATH`. `:checkhealth iter`
checks both.

With `vim.pack`:

```lua
vim.pack.add({
    {
        src = 'https://github.com/black-atom-industries/iter.nvim',
        version = vim.version.range('*'), -- stable version
        -- version = 'nightly',
    },
})

require('iter').setup()
```

With lazy.nvim:

```lua
{
    'black-atom-industries/iter.nvim',
    lazy = false,
    opts = {},
}
```

Call `setup()` at startup. It draws annotations in normal file buffers, so a
plugin manager must not delay it until the first `:Iter`.

## Quick start

```vim
:Iter          " open the status drawer
:Iter status   " the same
:Iter review   " open the review tab, or switch to it
```

`?` lists the keys of the view you are in.

## Annotations outside iter

iter maps keys only in its own buffers. To annotate from any buffer of a file
in the repository, map the API yourself:

```lua
local iter = require('iter')

-- The cursor line, or the visual selection
vim.keymap.set({ 'n', 'x' }, '<leader>aa', function()
    iter.annotate()
end, { desc = 'Annotate the line or selection' })

-- The whole file
vim.keymap.set('n', '<leader>af', function()
    iter.annotate({ scope = 'file' })
end, { desc = 'Annotate the file' })

-- The whole review
vim.keymap.set('n', '<leader>ar', function()
    iter.annotate({ scope = 'review' })
end, { desc = 'Annotate the review' })

-- Open the review on its Annotations column
vim.keymap.set('n', '<leader>al', iter.annotations, { desc = 'List the annotations' })
```

Line and range annotations show in the buffer, as a sign on the line and the
text below it. File and review annotations show in the review and in the
export.

## Reference

### Status drawer

The header reads `HEAD <branch>  ↑n ↓m  <upstream>` with the number of changes
on the right, or `N unstaged · M staged` when the columns stack. The arrows
count against the upstream as last fetched (iter never fetches) and show only
when not 0. A detached HEAD reads `(detached)`. In a narrow drawer the change
count goes first, then the upstream, then the arrows.

Recent commits, pinned above the key hints, lists the last `drawer.commits`
commits with the short sha, subject and age (`2h`, `3d`, `5w`), and `↑` on
those not on the upstream yet.

A rename reads `old → new` on one row, and a narrow column cuts the old path
first. `I` on an untracked row appends its path to the `.gitignore` at the
repository root, anchored and with glob characters escaped (`untracked.txt`
becomes `/untracked.txt`), after a confirm.

In the diff above the drawer, `<CR>` on a code line opens the file at that
line and closes the drawer. A staged line lands where it is in the worktree.
On a clean tree the drawer says "Working tree clean". Outside a git repository
iter warns and opens nothing.

### Review tab

The review drawer has the files on the left, Unstaged above Staged, and the
Annotations column on the right in a window of its own that stays put while
the files scroll. `h` and `l` switch between them; in narrow windows the three
stack and `h` and `l` step through them.

The Annotations column starts with the progress (`reviewed ■■■□□□□□ 3 of 8`,
then `· ↻ n` for files changed since they were reviewed), then every
annotation in file order, review annotations last: the file with `:line`,
`:first–last` or ` old` for a deleted line, and the start of the text.
Outdated annotations are dimmed. `<CR>` on one opens a file without changes in
the tab the review came from, and a review annotation in the editor.

The diff header shows the reviewed state, the stat and the number of
annotations. It also names a mode change (`mode 100644 → 100755`) and reads
`untracked · +n` for an untracked file. After `s` or `u` on the last change of
a file, the pane shows the file's other side. A file opened in the diff pane
with `:edit` opens in the tab the review came from.

In visual mode `s` and `u` take only the added and deleted lines of the
selection, across hunks if needed. A changed line staged alone goes next to
the line it pairs with.

**All files.** `m` shows every file in one buffer in drawer order, each under
its header. A file on both sides shows twice. The drawer selection follows the
cursor, `]f` and `[f` jump between headers, and `]c`, `[c`, `]a` and `[a` run
across files. A reviewed file shows its header alone, and `<CR>` on that header
opens it until `r` or `m` closes it again. The mode lasts until the review tab
closes.

**Side by side.** `|` puts the old version in a window on the left (`HEAD` for
a staged file, `index` for an unstaged one) and the new version on the right,
scrolling together. A deleted line and the added line it pairs with share a
row; a line without a partner faces a row of `╱`. `a` in the left window
annotates the old version. `s` and `u` work from either window. `-` or closing
the left window goes back to one pane. The status drawer's diff takes `m`, `|`
and `-` too.

**Annotation float.** `<C-s>` and `:wq` save and close, `:w` saves, `<C-t>`
hides the draft and shows it again from any buffer, `<C-c>` drops it, and `q`
closes a saved annotation.

### Keys

Keys are buffer-local and set per view. A value is a key, a list of keys, or
`false` to leave the action unmapped:

```lua
require('iter').setup({
    keys = {
        drawer = { stage = { 's', '<Space>' }, discard = false },
        diff = { annotate = 'gc' },
    },
})
```

The status drawer (`drawer`):

| Key     | Action         | Does                                 |
| ------- | -------------- | ------------------------------------ |
| `<CR>`  | `open`         | Open the file and close the drawer   |
| `s`     | `stage`        | Stage or unstage the file            |
| `u`     | `unstage`      | Unstage the file                     |
| `d`     | `discard`      | Discard changes in the file          |
| `I`     | `ignore`       | Add the untracked file to .gitignore |
| `r`     | `review`       | Open the review tab                  |
| `m`     | `mode`         | Toggle one file or all files         |
| `\|`    | `split`        | Show the diff side by side           |
| `-`     | `unified`      | Show the diff unified                |
| `q`     | `close`        | Close                                |
| `?`     | `help`         | Show the keys                        |
| `<C-d>` | `scroll_down`  | Scroll the diff down                 |
| `<C-u>` | `scroll_up`    | Scroll the diff up                   |
| `h`     | `column_left`  | Select the column to the left        |
| `l`     | `column_right` | Select the column to the right       |

The review drawer (`review_drawer`):

| Key     | Action          | Does                                     |
| ------- | --------------- | ---------------------------------------- |
| `<CR>`  | `open`          | Open the diff, or jump to the annotation |
| `s`     | `stage`         | Stage or unstage the file                |
| `u`     | `unstage`       | Unstage the file                         |
| `d`     | `discard`       | Discard changes in the file              |
| `I`     | `ignore`        | Add the untracked file to .gitignore     |
| `r`     | `reviewed`      | Mark reviewed and go to the next file    |
| `R`     | `unreviewed`    | Remove the reviewed mark                 |
| `m`     | `mode`          | Toggle one file or all files             |
| `\|`    | `split`         | Show the diff side by side               |
| `-`     | `unified`       | Show the diff unified                    |
| `A`     | `annotate_file` | Annotate the file                        |
| `e`     | `edit`          | Edit the annotation                      |
| `x`     | `delete`        | Delete the annotation                    |
| `y`     | `yank`          | Copy the review                          |
| `q`     | `close`         | Close                                    |
| `?`     | `help`          | Show the keys                            |
| `<C-d>` | `scroll_down`   | Scroll the diff down                     |
| `<C-u>` | `scroll_up`     | Scroll the diff up                       |
| `h`     | `column_left`   | Select the column to the left            |
| `l`     | `column_right`  | Select the column to the right           |

The diff pane (`diff`), in the review tab and above the status drawer:

| Key     | Action            | Does                                                            |
| ------- | ----------------- | --------------------------------------------------------------- |
| `]c`    | `next_hunk`       | Next hunk                                                       |
| `[c`    | `prev_hunk`       | Previous hunk                                                   |
| `]a`    | `next_annotation` | Next annotation                                                 |
| `[a`    | `prev_annotation` | Previous annotation                                             |
| `]f`    | `next_file`       | Next file                                                       |
| `[f`    | `prev_file`       | Previous file                                                   |
| `s`     | `stage`           | Stage the hunk or the selected lines (normal and visual mode)   |
| `u`     | `unstage`         | Unstage the hunk or the selected lines (normal and visual mode) |
| `a`     | `annotate`        | Annotate the line or range (normal and visual mode)             |
| `A`     | `annotate_file`   | Annotate the file                                               |
| `e`     | `edit`            | Edit the annotation                                             |
| `x`     | `delete`          | Delete the annotation                                           |
| `<CR>`  | `expand`          | Expand the collapsed file or hidden context                     |
| `gf`    | `goto_file`       | Go to the line in the file                                      |
| `r`     | `reviewed`        | Mark reviewed and go to the next file                           |
| `R`     | `unreviewed`      | Remove the reviewed mark                                        |
| `m`     | `mode`            | Toggle one file or all files                                    |
| `\|`    | `split`           | Show the diff side by side                                      |
| `-`     | `unified`         | Show the diff unified                                           |
| `y`     | `yank`            | Copy the review                                                 |
| `<C-j>` | `focus_drawer`    | Focus the drawer                                                |
| `q`     | `close`           | Close                                                           |
| `?`     | `help`            | Show the keys                                                   |

The annotation float (`annotation`):

| Key     | Action   | Does                                                             |
| ------- | -------- | ---------------------------------------------------------------- |
| `<C-s>` | `save`   | Save the annotation and close the float (normal and insert mode) |
| `<C-t>` | `toggle` | Hide or show the draft (normal and insert mode)                  |
| `<C-c>` | `cancel` | Drop the draft (normal and insert mode)                          |
| `q`     | `close`  | Close a saved annotation                                         |

The help float (`help`) closes on `q`, `?` and `<Esc>`.

### Configuration

`setup()` takes a table. Every field is optional. These are the defaults:

```lua
require('iter').setup({
    drawer = {
        height = 0.3,     -- fraction of the window height
        zindex = 40,      -- float stacking order; help and annotation floats sit above it
        breakpoint = 80,  -- drawer width below which the columns stack
        commits = 3,      -- recent commits the status drawer lists, 0 hides them
    },
    diff = {
        expand_step = 20,          -- hidden context lines shown per expand
        syntax_max_lines = 20000,  -- longer files get no syntax highlighting
        word_diff = true,          -- highlight the changed words in changed lines
        args = {},                 -- extra flags for every `git diff`, see below
    },
    export = {
        intro = 'I reviewed your changes and have these annotations.\n'
            .. 'Please address them.',
    },
    refresh = {
        poll_ms = 2000,   -- poll interval while a drawer is open
    },
    confirm = {
        discard = true,   -- ask before discarding changes
        ignore = true,    -- ask before adding a path to .gitignore
    },
    icons = {
        annotation = '󰆉',  -- before each annotation, '' for none
    },
    keys = {},            -- see Keys
    debug = false,        -- write debug lines to the log
})
```

[`lua/iter/config/defaults.lua`](lua/iter/config/defaults.lua) is the source
of truth. Unknown options, views or actions raise an error.

`diff.args` adds flags to every `git diff` iter runs, for display and for
staging. Only flags that keep hunks `git apply` can take back are allowed:

- `--diff-algorithm=<myers|minimal|patience|histogram>`, `--patience`,
  `--histogram`, `--minimal`
- `--indent-heuristic`, `--no-indent-heuristic`
- `--inter-hunk-context=<n>`
- `-U<n>` or `--unified=<n>`, with `n` of 1 or more

```lua
require('iter').setup({ diff = { args = { '--histogram', '-U5' } } })
```

### Lua API

```lua
local iter = require('iter')

iter.setup(opts)                     -- see Configuration
iter.status()                        -- same as :Iter status
iter.review()                        -- same as :Iter review
iter.annotate()                      -- annotate the cursor line or the visual range
iter.annotate({ scope = 'file' })    -- annotate the current buffer's file
iter.annotate({ scope = 'review' })  -- annotate the whole review
iter.annotations()                   -- open the review on its Annotations column
iter.yank()                          -- copy the review as a prompt
iter.statusline()                    -- text for your statusline
iter.uri()                           -- address of the review's diff cursor
iter.open_uri(uri)                   -- open an iter:// address, unescaped
iter.tabline()                       -- a 'tabline' that labels the review tab
```

`annotate()` works in any buffer of a file inside a git repository.

`yank()` copies to the `+` and `"` registers: the `export.intro` text, then a
numbered list with `file:line`, the annotated code and the annotation. Then it
asks once whether to clear the annotations.

`statusline()` returns `review · <file> · <i>/<n>` in the review tab, with
`all files` or `split` after `review` in those modes. Elsewhere in a
repository it returns `<branch> · <n>` with n the changed files, and `''`
outside one. A hidden annotation draft adds `draft annotation`. It never runs
git: a cache per repository refreshes on writes, focus, directory changes and
shell commands.

```lua
vim.o.statusline = "%f %m%=%{v:lua.require'iter'.statusline()} "
```

`uri()` returns `iter://review/<path>#L<n>` for the cursor in the review's
diff, with the worktree line of the cursor row, and `nil` elsewhere. Save it
and open it later with `open_uri()`.

### Addresses

iter's buffers are named with `iter://` addresses, and `:edit` of one opens
what it names in the repository of the current directory:

| Address                     | Opens                                                                    |
| --------------------------- | ------------------------------------------------------------------------ |
| `iter://status`             | The status drawer, or focuses it                                         |
| `iter://status/<path>`      | The status drawer with `<path>` selected                                 |
| `iter://review`             | The review tab, or switches to it                                        |
| `iter://review/<path>`      | The review tab with `<path>` selected, Unstaged before Staged            |
| `iter://review/<path>#L<n>` | The same, with the cursor on worktree line `n`, revealed if it is hidden |
| `iter://review#all`         | The review tab in all-files mode                                         |
| `iter://review#annotations` | The review tab on its Annotations column                                 |
| `iter://annotation`         | The hidden annotation draft                                              |

A path outside the changes opens the view with a warning. On the command line
`#` needs a backslash (`:e iter://review/a.txt\#L3`); `open_uri()` takes the
address as it is. iter's buffers stay unlisted, and a restored session gets
none of them back.

### Tab label

The review tab sets `vim.t.iter_label` to `iter review`. Neovim's default
tabline ignores it and counts the drawer float among the windows. `tabline()`
is a 'tabline' like the default that shows the label and counts only normal
windows:

```lua
vim.o.tabline = "%!v:lua.require'iter'.tabline()"
```

### Events

iter fires `User` autocmds with the repository root and the paths in `data`:

| Pattern       | When                                                            | `data`                                                                               |
| ------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `IterRefresh` | A drawer or review read the status, after an action or a change | `root`, `paths`: every changed path, a file on both sides once                       |
| `IterStage`   | A stage, unstage or discard of files, hunks or lines succeeded  | `root`, `paths`: the paths acted on, `action`: `'stage'`, `'unstage'` or `'discard'` |

```lua
vim.api.nvim_create_autocmd('User', {
    pattern = 'IterStage',
    callback = function(args)
        print(args.data.action, table.concat(args.data.paths, ' '))
    end,
})
```

### Highlight groups

iter derives its `Iter*` groups from the colorscheme on every `ColorScheme`
event, so no colorscheme needs to define them. A group the colorscheme does
define wins, whether or not it runs `:hi clear`. "Derived from" lists the
first group found with that colour, then the fallback. Row backgrounds blend
the diff colour 60 % towards `Normal`.

| Group                        | Colours                               | Derived from                                                         |
| ---------------------------- | ------------------------------------- | -------------------------------------------------------------------- |
| `IterStage`                  | Staged files in the drawer            | fg of `Added`, `String`                                              |
| `IterUnstage`                | Unstaged files in the drawer          | fg of `Removed`, `Error`                                             |
| `IterUntracked`              | Untracked files                       | fg of `DiagnosticInfo`, `Directory`, `Identifier`                    |
| `IterConflict`               | Files with merge conflicts            | fg of `DiagnosticError`, `ErrorMsg`, `Error`                         |
| `IterHead`                   | Branch name in the drawer             | fg of `Identifier`, `Keyword`                                        |
| `IterUnpushed`               | Unpushed commits and the ahead count  | fg of `Constant`, `Number`                                           |
| `IterBehind`                 | Behind count                          | fg of `Removed`, `Error`                                             |
| `IterReviewed`               | Reviewed marks and progress           | fg of `Added`, `String`                                              |
| `IterReviewedChanged`        | Files changed since reviewed          | fg of `DiagnosticWarn`, `WarningMsg`, `Constant`                     |
| `IterDrawer`                 | Drawer text                           | link to `Normal`                                                     |
| `IterDrawerTitle`            | Drawer titles                         | link to `Title`                                                      |
| `IterDrawerSelected`         | Selected drawer row                   | link to `Visual`                                                     |
| `IterDrawerKey`              | Key hints                             | link to `Special`                                                    |
| `IterDrawerHint`             | Dimmed drawer text                    | link to `Comment`                                                    |
| `IterDrawerCount`            | Counts in section titles              | link to `Special`                                                    |
| `IterDiffAdd`                | Added line rows                       | bg of `DiffAdd`, blended with `Normal`                               |
| `IterDiffDelete`             | Deleted line rows                     | bg of `DiffDelete`, blended with `Normal`                            |
| `IterDiffAddText`            | Changed words in added lines          | bg of `DiffAdd`                                                      |
| `IterDiffDeleteText`         | Changed words in deleted lines        | bg of `DiffDelete`                                                   |
| `IterDiffAddNr`              | Line number of added lines            | fg of `diffAdded`, `Added`, `DiffAdd`; bg as `IterDiffAdd`           |
| `IterDiffDeleteNr`           | Line number of deleted lines          | fg of `diffRemoved`, `Removed`, `DiffDelete`; bg as `IterDiffDelete` |
| `IterDiffNr`                 | Line number of context lines          | link to `LineNr`                                                     |
| `IterDiffHeader`             | File header rows in the diff          | fg of `Normal`; bg of `Title` fg, blended with `Normal`; bold        |
| `IterDiffHeaderRule`         | Rule above a file header, code letter | fg of `Title`                                                        |
| `IterDiffHunk`               | Hunk headers and stats                | link to `Comment`                                                    |
| `IterDiffGap`                | Collapsed unchanged lines             | link to `Folded`                                                     |
| `IterDiffFiller`             | Filler rows beside a one-sided change | link to `NonText`                                                    |
| `IterDiffAnnotation`         | Annotation text                       | link to `NormalFloat`                                                |
| `IterDiffAnnotationOutdated` | Annotation whose lines changed        | link to `Comment`                                                    |
| `IterDiffAnnotationFocus`    | Focused annotation                    | link to `Visual`                                                     |
| `IterAnnotationSign`         | Annotation sign in the gutter         | link to `Special`                                                    |

### Files

Annotations and reviewed marks live in
`stdpath('data')/iter/<repo>/<branch>.json`, the log in
`stdpath('state')/iter/iter.log`.

## Development

The project pins its tools in `mise.toml`: `lua-language-server`, `stylua`,
`just` and Node. Install [mise](https://mise.jdx.dev/), then run
`mise install` and `npm ci` (Vite+, which formats the Markdown).

```bash
just checks        # lint, format-check and test
just lint          # lua-language-server --check against Neovim's Lua API
just format        # format Lua with stylua and Markdown with vp fmt
just test          # run the whole test suite
just test-file tests/test_git.lua  # run one test file
```

Run `just git-config` once per clone. It points Git at the hooks in
`.githooks/`: format and lint before every commit, `just checks` before every
push.

Tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md),
pinned in `deps/` by `just test` and moved with `just bump-mini`. UI tests
drive a child Neovim and compare screenshots with the references in
`tests/screenshots/`. A missing reference is written on the next run, and
fails it when `CI` is set; delete a reference to write it again after an
intended UI change.

The README clips are recorded with [VHS](https://github.com/charmbracelet/vhs)
from the tapes in `docs/assets/tapes/`; each tape says how to run it.

## Credits

iter.nvim started as a fork of
[minifugit.nvim](https://github.com/vieitesss/minifugit.nvim) by
[vieitesss](https://github.com/vieitesss). The review follows
[tuicr](https://github.com/agavra/tuicr), and annotations in normal buffers
follow [annotator.nvim](https://github.com/chpeters/annotator.nvim).
