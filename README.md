# iter.nvim

> **iter** /ˈɪtɛr/ — Latin: _journey, path, road, march_
>
> Your code's journey through version control.

A lightweight Git status UI for Neovim, inspired by
[vim-fugitive](https://github.com/tpope/vim-fugitive).

iter.nvim focuses on a compact status window for everyday Git operations
without leaving Neovim.

## Features

- Open a Git status window with `:Iter`.
- View your files' status.
- Discard unstaged changes or delete untracked paths, with confirmation by
  default.
- Stage and unstage files from the status window (visual mode as well).
- Preview diffs for the entry under the cursor in stacked or split view.
- Stage and unstage hunks from the diff window.
- Create commits.
- Animated loading spinner while pushing your commits.
- View unpushed commits in the status window and preview the diffs.
- Run `:checkhealth iter` to verify Neovim, Git, and diffs.nvim requirements.

## Requirements

- Neovim 0.10+
- `git` executable on `PATH`
- [diffs.nvim](https://github.com/barrettruth/diffs.nvim) — renders the diff
  previews (treesitter syntax inside hunks, intra-line word highlighting,
  colorscheme-derived colors)

## Configuration

### vim.pack

```lua
vim.pack.add({
    'https://github.com/barrettruth/diffs.nvim',
    {
        src = 'https://github.com/black-atom-industries/iter.nvim',
        version = vim.version.range("*") -- stable version
        -- version = "nightly"
    },
})
```

### lazy.nvim

```lua
{
    'black-atom-industries/iter.nvim',
    cmd = { 'Iter' },
    dependencies = { 'barrettruth/diffs.nvim' },
}
```

### diffs.nvim

iter hands its diff preview buffers to diffs.nvim for highlighting, so its
rendering options (highlight blend, intra-line algorithm, …) apply to iter's
previews too. Configure them via `vim.g.diffs` — see `:help diffs.nvim`.

### Configuration

All options, keymaps, their defaults, and inline documentation can be found in
**[`lua/iter/config/defaults.lua`](lua/iter/config/defaults.lua)**.

### Highlight Groups

Iter defines its own highlight groups (all prefixed `Iter*`). Each one falls
back to a standard Neovim group when available, then to a hardcoded hex color.
See **[`lua/iter/config/defaults.lua`](lua/iter/config/defaults.lua)** for the
full list and their fallback sources.

## Usage

Open the status window:

```vim
:Iter
```

```lua
require('iter').status()
```

## Tooling

### mise (recommended)

The project pins tool versions in `mise.toml`. Install [mise](https://mise.jdx.dev/), then run:

```bash
mise install
```

This installs pinned versions of:

- `lua-language-server` — for linting diagnostics
- `stylua` — Lua formatter
- `just` — task runner

### Checks

```bash
just checks    # lint + format-check + test
```

Runs all quality checks:

- **lint** — `lua-language-server --check` with project `.luarc.json`
- **format-check** — `stylua --check` (auto-fix with `just format`)
- **test** — mini.test suite

Individual recipes:

```bash
just lint        # lint diagnostics
just format      # auto-format all Lua files
just format-check # check formatting (for CI/pre-commit)
just test        # run test suite
```

A `.luarc.json` at the project root configures the diagnostics (Neovim globals,
LuaJIT runtime, third-party checks off).

#### Pre-commit hook

```bash
git config core.hooksPath .githooks
```

The `.githooks/pre-commit` hook runs lint and tests on every commit (`just
checks`). Commits are blocked on any failure.

## Testing

Tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md).
`just test` clones mini.nvim and diffs.nvim into the gitignored `deps/` folder at
pinned commits and runs the whole suite headless. It exits non-zero on any
failure.

```bash
just test                           # whole suite
just test-file tests/test_git.lua   # one file
```

Test files are `tests/test_*.lua`. `tests/helpers.lua` creates temporary git
repositories with fixtures and starts a child Neovim with the plugin loaded.
UI tests drive that child and compare screenshots against the references in
`tests/screenshots/`. A missing reference is created on the next run; delete
the file to regenerate it after an intended UI change.

## Credits

iter.nvim is a fork of [minifugit.nvim](https://github.com/vieitesss/minifugit.nvim)
by [vieitesss](https://github.com/vieitesss). The original plugin provided the
foundation for this lightweight Git status UI — iter.nvim builds on it with a
fresh name and continued development.
