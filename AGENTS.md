## About the plugin

This is a Neovim plugin, written in Lua, for Git staging and code review: a status drawer, and a review tab with
annotations, viewed marks and an export for agents.

Scope, architecture and Lua conventions live in `docs/CONVENTIONS.md`. Read it before changing code.

## Working on an issue

- Open work lives in GitHub issues, milestone `v1`.
- Plan the implementation from the issue's motivation before writing code.
- Start a conventional branch (`feat/...`, `fix/...`) only from `main`. On any other branch, ask what to do about the
  branch before anything else.
- Create a new file when the code fits no current file or handles one very specific job. Long files are fine; a file
  that handles more than its job is not.
- Commit only when told, through the `repo-commit` skill. Never push.

## Tests

- Tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md).
- New behavior gets both kinds of test: functional tests and UI tests.
- Functional tests cover only the functions in a module's API, never local functions.
- UI tests drive a child Neovim and check windows, buffers and screenshots during and after the plugin runs.
- Git repositories in tests are temporary directories, never real repositories.
- Run the suite as `CI=1 just test`. Without `CI`, a missing screenshot reference is written instead of failing.

## Skills

- `repo-commit`: any commit.
- `repo-release` and `repo-changelog`: preparing or merging the release-please PR.
- `repo-dep-upgrades`: bumping the pinned mini.nvim or the npm devDependencies.

## Designs

All UI designs live in the "iter.nvim" Design canvas artifact (https://claude.ai/artifact/N3QkZ8nf9AuZvRTnR3geRQ), one
page per milestone. Create and iterate designs there.
