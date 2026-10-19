# iter.nvim

> **iter** /ˈɪtɛr/, Latin: _journey, path, road, march_
>
> Your code's journey through version control.

A Git staging and code review tool for Neovim.

## Features

- **Status drawer:** a float at the bottom of the current window with Unstaged
  and Staged side by side (stacked in narrow windows). The window above shows
  the diff of the selected file as you move.
- **Branch at a glance** in the status drawer: the header shows the branch,
  how far it is ahead of (`↑`) and behind (`↓`) its upstream and the
  upstream's name; pinned under the files, the last commits with `↑` on those
  not pushed yet.
- **Stage, unstage, discard** whole files. New files are listed one by one
  among the others. Discard asks first, names the paths, and never touches the
  index or ignored files.
- **Review tab:** a tab page for the whole review. One file's diff at a time,
  or every file in one scroll, with hunk jumps, file jumps and `gf` to the
  source line.
- **Hunk staging** in the review diff, applied exactly like `git add -p`.
- **Diff rendering** in Lua: treesitter syntax, word emphasis on changed lines,
  old and new line numbers, hidden context that expands on demand.
- **Annotations** on a line, a range, a deleted line, a file or the whole review,
  in the review diff and in normal file buffers. Annotations follow their code
  when it moves and turn outdated when it is gone.
- **Annotations column** in the review drawer: every annotation in drawer
  order with the viewed progress on top. Moving onto one shows it in the diff;
  jump, edit and delete from there.
- **Viewed marks** per file that drop back when the file changes afterwards.
- **Export:** copy all annotations as a prompt for an agent, then clear them if
  you like.
- **Saved per repository and branch**, shared by linked worktrees.
- **Auto refresh** on index and HEAD changes, focus and writes.
- **Keys per view**, each one remappable or disabled, with a `?` help float.

iter does not commit, push or pull. Use a Git plugin such as mini.git or
fugitive for that.

## Requirements

- Neovim 0.12 or newer
- `git` on `PATH`

Run `:checkhealth iter` to check both.

## Installation

### vim.pack

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

### lazy.nvim

```lua
{
    'black-atom-industries/iter.nvim',
    lazy = false,
    opts = {},
}
```

Call `setup()` at startup. It is what shows annotations in normal file buffers,
so a plugin manager must not delay it until the first `:Iter`.

## Usage

```vim
:Iter          " open the status drawer
:Iter status   " the same
:Iter review   " open the review tab, or switch to it
```

Outside a git repository iter warns and opens nothing. On a clean tree the
status drawer says "Working tree clean"; the review tab still opens, with its
Annotations column.

The status drawer's header reads `HEAD <branch>  ↑n ↓m  <upstream>` with the
number of changes at the right. `↑` and `↓` show only when not 0 and count
against the upstream as last fetched; iter never fetches. A branch without an
upstream shows neither, and a detached HEAD shows `(detached)`. In a narrow
drawer the change count goes first, then the upstream, then the arrows.

Pinned at the bottom of the drawer, above the key hints, Recent commits lists
the last `drawer.commits` commits: `↑` on a commit not on the upstream, the
short sha, the subject and its age (`2h`, `3d`, `5w`). Its title adds
`↑n unpushed` and `↓m behind` when not 0. It stays in view however long the
file list is, and the cursor stays on the files.

In the drawer, `j` and `k` move through the files and the window above shows
the diff. `<CR>` opens the file there and closes the drawer. `r` opens the
review tab. `?` lists the keys of the current view.

## Lua API

```lua
local iter = require('iter')

iter.setup(opts)                     -- see Configuration
iter.status()                        -- same as :Iter status
iter.review()                        -- same as :Iter review
iter.annotate()                      -- annotate the cursor line or the visual range
iter.annotate({ scope = 'review' })  -- annotate the whole review
iter.annotations()                   -- open the review on its Annotations column
iter.yank()                          -- copy the review as a prompt
iter.statusline()                    -- text for your statusline
```

`annotate()` works in any buffer of a file inside a git repository. Map it in
normal and visual mode:

```lua
vim.keymap.set({ 'n', 'x' }, '<leader>a', function()
    require('iter').annotate()
end, { desc = 'Annotate' })
```

`yank()` copies the annotations to the `+` and `"` registers: the
`export.intro` text, then a numbered list with `file:line`, the annotated code
and the annotation. It then asks once whether to clear the annotations.

`statusline()` returns `review · <file> · <i>/<n>` inside the review tab
(`review` when no file is shown), `review · all files · <file> · <i>/<n>`
for the file under the cursor when the pane shows all files, with `split`
after the mode while the diff shows side by side
(`review · split · <file> · <i>/<n>`), and `''` elsewhere. While an
annotation draft is hidden it adds `draft annotation`.

## Configuration

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
    },
    icons = {
        annotation = '󰆉',  -- before each annotation, '' for none
    },
    keys = {},            -- see Keys
    debug = false,        -- write debug lines to the log
})
```

The source of truth is
[`lua/iter/config/defaults.lua`](lua/iter/config/defaults.lua). Unknown
options, views or actions raise an error.

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

| Key | Action | Does |
| --- | ------ | ---- |
| `<CR>` | `open` | Open the file and close the drawer |
| `s` | `stage` | Stage or unstage the file |
| `u` | `unstage` | Unstage the file |
| `d` | `discard` | Discard changes in the file |
| `r` | `review` | Open the review tab |
| `q` | `close` | Close |
| `?` | `help` | Show the keys |
| `<C-d>` | `scroll_down` | Scroll the diff down |
| `<C-u>` | `scroll_up` | Scroll the diff up |
| `h` | `column_left` | Select the column to the left |
| `l` | `column_right` | Select the column to the right |

In the diff above the status drawer, the `expand` key (`<CR>`) on a code line
opens the file at that line and closes the drawer; on hidden context it
expands. A staged line lands where it is in the worktree.

The drawer of the review tab (`review_drawer`):

| Key | Action | Does |
| --- | ------ | ---- |
| `<CR>` | `open` | Open the diff, or jump to the annotation |
| `s` | `stage` | Stage or unstage the file |
| `u` | `unstage` | Unstage the file |
| `d` | `discard` | Discard changes in the file |
| `v` | `viewed` | Toggle viewed |
| `m` | `mode` | Toggle one file or all files |
| `\|` | `split` | Show the diff side by side |
| `-` | `unified` | Show the diff unified |
| `A` | `annotate_file` | Annotate the file |
| `e` | `edit` | Edit the annotation |
| `x` | `delete` | Delete the annotation |
| `y` | `yank` | Copy the review |
| `q` | `close` | Close |
| `?` | `help` | Show the keys |
| `<C-d>` | `scroll_down` | Scroll the diff down |
| `<C-u>` | `scroll_up` | Scroll the diff up |
| `h` | `column_left` | Select the column to the left |
| `l` | `column_right` | Select the column to the right |

The diff pane of the review tab (`diff`):

| Key | Action | Does |
| --- | ------ | ---- |
| `]c` | `next_hunk` | Next hunk |
| `[c` | `prev_hunk` | Previous hunk |
| `]a` | `next_annotation` | Next annotation |
| `[a` | `prev_annotation` | Previous annotation |
| `]f` | `next_file` | Next file |
| `[f` | `prev_file` | Previous file |
| `s` | `stage` | Stage the hunk or the selected lines (normal and visual mode) |
| `u` | `unstage` | Unstage the hunk or the selected lines (normal and visual mode) |
| `a` | `annotate` | Annotate the line or range (normal and visual mode) |
| `A` | `annotate_file` | Annotate the file |
| `e` | `edit` | Edit the annotation |
| `x` | `delete` | Delete the annotation |
| `<CR>` | `expand` | Expand the collapsed file or hidden context |
| `gf` | `goto_file` | Go to the line in the file |
| `v` | `viewed` | Toggle viewed |
| `m` | `mode` | Toggle one file or all files |
| `\|` | `split` | Show the diff side by side |
| `-` | `unified` | Show the diff unified |
| `y` | `yank` | Copy the review |
| `q` | `close` | Close |
| `?` | `help` | Show the keys |

The review drawer has two columns: the files on the left, Unstaged above
Staged, and Annotations on the right in a window of its own that stays in
place while the file list scrolls. `j` and `k` move through both file
sections; `h` and `l` switch between the files and Annotations, and each
keeps its row. In narrow windows Unstaged, Staged and Annotations stack, and
`h` and `l` step through them, skipping a file section without files. The
Annotations column starts with the viewed progress (`viewed ■■■□□□□□ 3 of 8`,
then `· ↻ n` for files changed since they were viewed) and lists every
annotation in drawer file order, review annotations last: the file name with
`:line`, `:first–last` or ` old` for a deleted line, then the start of the
text. Outdated ones are dimmed. Moving onto an annotation shows its file in
the diff pane, scrolled to it and highlighted. `<CR>` moves into the diff
there, opens a file without changes in the tab the review came from, and
opens a review annotation in the editor. `e`
and `x` work only on an annotation row.

In visual mode, `s` and `u` take only the added and deleted lines of the
selection, which may span several hunks. A changed line staged or unstaged
alone takes the place of the line it pairs with. After `s` or `u` on the last change of a file, the pane shows the same
file on its other side. A file opened in the diff pane, with `:edit` for
example, opens in the tab the review came from, and the pane keeps its diff. A
mode change shows in the diff header as `mode 100644 → 100755`; `s` on the file
in the drawer stages it. An untracked file's diff header reads `untracked · +n`.
In the review tab the header also shows the file's viewed state and its
number of annotations, for an untracked file only when it has any.

`m`, in the diff pane or the review drawer, shows every file of the review
in one buffer, in drawer order: Unstaged, then Staged, each file under its
header with a blank line between files. A file on both sides shows twice.
The drawer selection follows the cursor from file to file, and selecting a
file in the drawer puts its header at the top of the pane. `]f` and `[f`
jump between the headers, `]c`, `[c`, `]a` and `[a` run across files, and
staging, annotations, viewed, `gf` and hidden context work on the file
under the cursor. A visual selection over two files stages and annotates
nothing. `m` again shows the selected file alone; the key hint line names
the mode it switches to. The mode lasts until the
review tab closes.

In all-files mode a viewed file shows its header row alone (`✓ viewed`),
with its stat and annotation count. `v` on a file collapses it, `v` on a
collapsed header unviews and expands it, from the diff pane or the drawer.
`<CR>` on a collapsed header shows the whole file and keeps it viewed, until
`v` marks it viewed again or `m` enters the mode again. Entering the mode
shows viewed files collapsed and files changed since they were viewed (`↻`)
whole. `]f` and `[f` stop on collapsed headers; moving the drawer selection
or an annotation preview leaves a collapsed file as it is, and `<CR>` on an
annotation in one expands it.

`|`, in the diff pane or the review drawer, shows the diff side by side: the
old version in a window on the left (`HEAD` for a staged file, `index` for an
unstaged one), the new version on the right (`index` or `worktree`), each
with its own line numbers, syntax and a clean buffer. The right header keeps
the stat and the annotation count and shows the viewed state as its glyph
(`✓`, `↻`, `○`). The two windows scroll
and move the cursor together. A deleted line and the added line it pairs
with share a row, with the changed words highlighted; a line without a
partner faces a row of `╱`. Hidden context shows on both sides and expands
on both. An annotation shows on its side, with blank lines of the same
height on the other. `a` takes the lines of its window's side: in the left
window a selection with a deleted line annotates the old version, unchanged
lines in it included; an added or unchanged line alone annotates the new
one. `s` and `u` stage and unstage
the hunk under the cursor from either window; in visual mode they take the
added and deleted lines on both sides of the selected rows. `m` works here
too, with every file on both sides. `-` goes back to one unified pane, and
so does closing the left window. The key hint line names the layout it
switches to. The status drawer's diff stays unified.

The annotation float (`annotation`). `:w` saves and keeps the float open; `:wq` and `<C-s>` save and close it.

| Key | Action | Does |
| --- | ------ | ---- |
| `<C-s>` | `save` | Save the annotation and close the float (normal and insert mode) |
| `<C-t>` | `toggle` | Hide or show the draft (normal and insert mode) |
| `<C-c>` | `cancel` | Drop the draft (normal and insert mode) |
| `q` | `close` | Close a saved annotation |

While a draft is hidden, `<C-t>` in normal mode shows it again from any
buffer. A `<C-t>` mapping of your own comes back once the draft is gone.

The help float (`help`): `close` on `q`, `?` and `<Esc>`.

### Highlight groups

iter defines its own groups, all named `Iter*`, and derives them from the
colorscheme on every `ColorScheme` event. The list is in
[`lua/iter/highlight.lua`](lua/iter/highlight.lua).

### Files

Annotations and viewed marks live in
`stdpath('data')/iter/<repo>/<branch>.json`. Linked worktrees of one
repository share them. The log is `stdpath('state')/iter/iter.log`.

## Development

The project pins its tools in `mise.toml`: `lua-language-server`, `stylua`
and `just`. Install [mise](https://mise.jdx.dev/), then run `mise install`.

```bash
just checks        # lint, format-check and test
just lint          # lua-language-server --check against Neovim's Lua API
just format        # format all Lua files with stylua
just format-check  # check formatting only
just test          # run the whole test suite
just test-file tests/test_git.lua  # run one test file
```

To run the checks before every commit:

```bash
git config core.hooksPath .githooks
```

### Testing

Tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md).
`just test` clones mini.nvim at a pinned commit into the gitignored `deps/`
folder and runs the suite headless. It exits non-zero on any failure.

Test files are `tests/test_*.lua`. `tests/helpers.lua` creates temporary git
repositories with fixtures and starts a child Neovim with the plugin loaded.
UI tests drive that child and compare screenshots with the references in
`tests/screenshots/`. A missing reference is written on the next run, and
fails the run when `CI` is set. Delete a reference to write it again after an
intended UI change.

## Credits

iter.nvim is a fork of [minifugit.nvim](https://github.com/vieitesss/minifugit.nvim)
by [vieitesss](https://github.com/vieitesss), which gave it its start as a
lightweight Git status UI.
