# LOG

- [x] fix: make `=` toggle diff preview instead of always re-opening
- [x] docs: fix key references in help and README to match actual mappings
- [x] feat: make `o` open entry and close status window
- [x] feat: add `status.layout = 'replace'` option (Oil-like layout)
- [x] feat: use vsplit for commit editor in replace mode
- [x] fix: use bufadd/bufload instead of `:edit` in replace mode

### Planned

- [ ] feat: add keybinding to quick add to gitignore
- [x] feat: customizable keybindings (data-driven keymap tables + keymaps option in setup)
- [ ] feat: auto-refresh status pane on git events (autocmd)
- [ ] fix: suppress or debounce "Diff preview not available for untracked directories" notification
- [x] chore: rename plugin to flux.nvim (with credit to original)
- [x] test: add test suite (diff parser, diff position, status formatting, keymaps survival, CI workflow)
- [x] fix: harden keymap lifecycle (CursorMoved group, BufEnter diff remaps, close_diff cleanup)
- [ ] chore: replace vendored plenary.nvim with mini.test (plenary is deprecated, vendored 20MB is wasteful)
- [ ] chore: consider rebasing on [base.nvim](https://github.com/S1M0N38/base.nvim) template
