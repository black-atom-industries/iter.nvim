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

### 6. Draft, inspect, plan

Draft the code, then inspect the existing codebase against the draft (modules, data flow, what to keep, what to
drop), then write the implementation plan.

## Collected findings

Items to fold into the scope and plan.

- radar.nvim's bottom panel is a float at zindex 20 and needs the configurable zindex option too.
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
