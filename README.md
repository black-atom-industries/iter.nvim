# flux.nvim

https://github.com/user-attachments/assets/54852a86-f04e-4eea-a432-700de08bb89f

A lightweight Git status UI for Neovim, inspired by
[vim-fugitive](https://github.com/tpope/vim-fugitive).

flux.nvim focuses on a compact status window for everyday Git operations
without leaving Neovim.

## Features

- Open a Git status window with `:Flux`.
- View your files' status.
- Discard unstaged changes or delete untracked paths, with confirmation by
  default.
- Stage and unstage files from the status window (visual mode as well).
- Preview diffs for the entry under the cursor in stacked or split view.
- Stage and unstage hunks from the diff window.
- Create commits.
- Animated loading spinner while pushing your commits.
- View unpushed commits in the status window and preview the diffs.
- Run `:checkhealth flux` to verify Neovim and Git requirements.

## Requirements

- Neovim 0.10+
- `git` executable on `PATH`

## Configuration

### vim.pack

```lua
vim.pack.add({
    'https://github.com/nikbrunner/flux.nvim',
    version = vim.version.range("*") -- stable version
    -- version = "nightly"
})
```

### lazy.nvim

```lua
{
    'nikbrunner/flux.nvim',
    cmd = { 'Flux' },
}
```

### Configuration

All options, keymaps, their defaults, and inline documentation can be found in
**[`lua/flux/config/defaults.lua`](lua/flux/config/defaults.lua)**.

### Highlight Groups

Flux defines its own highlight groups (all prefixed `Flux*`). Each one falls
back to a standard Neovim group when available, then to a hardcoded hex color.
See **[`lua/flux/config/defaults.lua`](lua/flux/config/defaults.lua)** for the
full list and their fallback sources.

## Usage

Open the status window:

```vim
:Flux
```

```lua
require('flux').status()
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
- **test** — plenary.nvim test suite

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

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-style
harness, vendored in the repo.

### Run with just (recommended)

```bash
just test
```

This clones plenary if needed, pins it to the expected commit, and runs the
full suite headlessly.

### Run without just

```bash
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua' })"
```

### Run a single test file

```bash
nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/functional/diff/parser_spec.lua', { minimal_init = 'tests/minimal_init.lua' })"
```

Test files live under `tests/functional/` (pure-Lua unit/integration) and
`tests/ui/` (end-to-end with real Neovim windows and a temporary git
repository).

## Credits

flux.nvim is a fork of [minifugit.nvim](https://github.com/vieitesss/minifugit.nvim)
by [vieitesss](https://github.com/vieitesss). The original plugin provided the
foundation for this lightweight Git status UI — flux.nvim builds on it with a
fresh name and continued development.
