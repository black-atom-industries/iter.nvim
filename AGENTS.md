## About the plugin

This is a Neovim plugin, written in Lua, for Git staging and code review: a status drawer, and a review tab with comments, viewed marks and an export for agents.

## Working on a new issue

- Create a new branch for the issue following conventional naming (e.g. feat/new-feat, fix/fixing-this, etc.).
- Do not change to a new branch unless you are already in the main branch. If you are not in the main branch, ask what to do about the branch before anything else.
- Plan the implementation regarding the issue motivation.
- Follow the code structure:
    - Create a new file if the implementation does not fit in any of the current files or if splitting into more files is necessary because the code handles a very specific functionality.
    - Do not over-split code. Long files are okay. Long files that handle more functionalities than what it should, no.
- Write the code.
- Format the code.
- Commit only when indicated. Never push.

Open work lives in GitHub issues, milestone `v1`. Scope and architecture rules live in `docs/CONVENTIONS.md`.

## Tests

- Use `mini.test` (from mini.nvim) for creating/managing tests: https://github.com/echasnovski/mini.nvim/blob/main/TESTING.md
- There should be:
    - Functional tests: only for functions that are part of each module's API. Do NOT create tests for local functions
    - UI tests: drive a child Neovim and check windows, buffers and screenshots, ensuring the UI is shown as expected during and after the execution of the plugin.
- Use temporary directories as git repositories for testing, do not use real repositories.

## Formatting

Use `stylua` for formatting.

---

For coding conventions, structure, and project practices, see `docs/CONVENTIONS.md`.

All UI designs live in the "iter.nvim" Design canvas artifact
(https://claude.ai/artifact/N3QkZ8nf9AuZvRTnR3geRQ), one page per milestone. Create and iterate designs there.
