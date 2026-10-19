# iter.nvim

> **iter** /ˈɪtɛr/, Latin: _journey, path, road, march_
>
> Your code's journey through version control.

A Git staging and code review tool for Neovim.

## Features

- **Status drawer:** a float at the bottom of the current window with Unstaged
  and Staged side by side (stacked in narrow windows). The window above shows
  the diff of the selected file as you move.
- **Stage, unstage, discard** whole files. New files are listed one by one
  among the others. Discard asks first, names the paths, and never touches the
  index or ignored files.
- **Review tab:** a tab page for the whole review. One file's diff at a time
  with hunk jumps, file jumps and `gf` to the source line.
- **Hunk staging** in the review diff, applied exactly like `git add -p`.
- **Diff rendering** in Lua: treesitter syntax, word emphasis on changed lines,
  old and new line numbers, hidden context that expands on demand.
- **Annotations** on a line, a range, a deleted line, a file or the whole review,
  in the review diff and in normal file buffers. Annotations follow their code
  when it moves and turn outdated when it is gone.
- **Annotation picker** grouped by file, to filter, jump, edit and delete.
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
drawer says "Working tree clean"; the review tab still opens for review
annotations.

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
iter.annotations()                   -- open the annotation picker
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
(`review` when no file is shown) and `''` elsewhere. While an annotation draft is hidden it adds `draft annotation`.

## Configuration

`setup()` takes a table. Every field is optional. These are the defaults:

```lua
require('iter').setup({
    drawer = {
        height = 0.3,     -- fraction of the window height
        zindex = 40,      -- float stacking order; help, picker and annotation floats sit above it
        breakpoint = 80,  -- drawer width below which the columns stack
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
| `h` | `column_left` | Select the Unstaged column |
| `l` | `column_right` | Select the Staged column |

In the diff above the status drawer, the `expand` key (`<CR>`) on a code line
opens the file at that line and closes the drawer; on hidden context it
expands. A staged line lands where it is in the worktree.

The drawer of the review tab (`review_drawer`):

| Key | Action | Does |
| --- | ------ | ---- |
| `<CR>` | `open` | Open the file |
| `s` | `stage` | Stage or unstage the file |
| `u` | `unstage` | Unstage the file |
| `d` | `discard` | Discard changes in the file |
| `v` | `viewed` | Toggle viewed |
| `A` | `annotate_file` | Annotate the file |
| `L` | `picker` | List annotations |
| `y` | `yank` | Copy the review |
| `q` | `close` | Close |
| `?` | `help` | Show the keys |
| `h` | `column_left` | Select the Unstaged column |
| `l` | `column_right` | Select the Staged column |

The diff pane of the review tab (`diff`):

| Key | Action | Does |
| --- | ------ | ---- |
| `]c` | `next_hunk` | Next hunk |
| `[c` | `prev_hunk` | Previous hunk |
| `]a` | `next_annotation` | Next annotation |
| `[a` | `prev_annotation` | Previous annotation |
| `]f` | `next_file` | Next file |
| `[f` | `prev_file` | Previous file |
| `s` | `stage` | Stage the hunk |
| `u` | `unstage` | Unstage the hunk |
| `a` | `annotate` | Annotate the line or range (normal and visual mode) |
| `A` | `annotate_file` | Annotate the file |
| `e` | `edit` | Edit the annotation |
| `x` | `delete` | Delete the annotation |
| `<CR>` | `expand` | Expand hidden context |
| `gf` | `goto_file` | Go to the line in the file |
| `v` | `viewed` | Toggle viewed |
| `L` | `picker` | List annotations |
| `y` | `yank` | Copy the review |
| `q` | `close` | Close |
| `?` | `help` | Show the keys |

After `s` or `u` on the last hunk of a file, the pane shows the same file on
its other side. A file opened in the diff pane, with `:edit` for example, opens
in the tab the review came from, and the pane keeps its diff. A mode change
shows in the diff header as `mode 100644 → 100755`; `s` on the file in the
drawer stages it.

The annotation float (`annotation`). `:w` also saves and `:wq` saves and closes.

| Key | Action | Does |
| --- | ------ | ---- |
| `<C-s>` | `save` | Save the annotation (normal and insert mode) |
| `<C-t>` | `toggle` | Hide or show the draft (normal and insert mode) |
| `<C-c>` | `cancel` | Drop the draft (normal and insert mode) |
| `q` | `close` | Close a saved annotation |

While a draft is hidden, `<C-t>` in normal mode shows it again from any
buffer. A `<C-t>` mapping of your own comes back once the draft is gone.

The annotation picker (`picker`). Type to filter. All keys work in normal and
insert mode.

| Key | Action | Does |
| --- | ------ | ---- |
| `<C-n>` | `next` | Next annotation |
| `<C-p>` | `prev` | Previous annotation |
| `<CR>` | `jump` | Jump to the annotation |
| `<C-e>` | `edit` | Edit the annotation |
| `<C-x>` | `delete` | Delete the annotation |
| `<Esc>` | `close` | Close |

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
