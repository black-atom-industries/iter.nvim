# Roadmap

Open and finished work. The scope and the slice plan live in
[`docs/renovation.md`](docs/renovation.md).

## M2

- [ ] Stage selected lines in the diff pane.
- [ ] Branch diff against the base branch in the review tab.
- [ ] Unpushed column: the unpushed commits, or the last few when there is no
      upstream. A commit shows its diff and takes comments.
- [ ] Side-by-side diff view.
- [ ] Continuous scroll through all changed files, toggled with `m` (slice S15
      in `docs/renovation.md`). The `mode` action exists in the key config but
      has no handler yet.

## Later

- [ ] Show a rename as one row with both paths, like `old.lua → new.lua`.
- [ ] User events such as `User IterRefresh` and `User IterStage`.
- [ ] A statusline part with the branch and the number of changed files.
      `statusline()` covers the review tab and comment drafts only.
- [ ] Move the config `---@class` types out of `config/defaults.lua` into a
      file of their own.
- [ ] A key that adds the file under the cursor to `.gitignore`.
- [ ] Configurable flags for `git diff`, as long as hunks still apply.
- [ ] Moved-code detection and finer word diff on long lines through a binary
      such as libvscode-diff. Needs a decision first.
- [ ] A `zindex` option for radar.nvim's panel (in the radar.nvim repo).
- [ ] Repo setup with `nbr-repo-setup`: release-please, `CHANGELOG.md`, agent
      tooling, release clips recorded with `nbr-record-clip`.
- [ ] Screenshots or clips of the drawer and the review tab in the README.
- [ ] Test files next to the modules they test.
- [ ] A better home for `docs/CONVENTIONS.md`: real docs, `CONTRIBUTING.md` or
      `AGENTS.md`.
- [ ] A Markdown formatter.
- [ ] Evaluate the [base.nvim](https://github.com/S1M0N38/base.nvim) template.

## Done

- [x] Status drawer: a float at the bottom of the current window with
      Unstaged and Staged columns, a live diff preview above, file staging,
      unstaging and discard with confirmation.
- [x] Untracked directories expand to their files.
- [x] Unified diff renderer in Lua: treesitter syntax, word emphasis, an old
      and new line number rail, hidden context that expands on demand.
- [x] Review tab with hunk staging, file and hunk jumps and `gf`.
- [x] Auto-refresh from git index and HEAD changes, focus, writes and a poll,
      also in linked worktrees.
- [x] Comments on lines, ranges, deleted lines, files and the whole review, in
      diffs and in normal buffers, saved per repository and branch and
      re-anchored when the code moves.
- [x] Comment float with a hideable draft, and a comment picker.
- [x] Viewed marks that drop back when the file changes.
- [x] Export of the review as a prompt for an agent.
- [x] Keys per view, each one remappable or disabled, and a `?` help float.
- [x] mini.test suite with child Neovim screenshot tests.
- [x] `:checkhealth iter` for Neovim 0.12 and `git`.
