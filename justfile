mini_ref := "66b9e643b6dabe15079be7197ee4b4d59ff98c61"
mini_url := "https://github.com/echasnovski/mini.nvim"
minimal_init := justfile_directory() / "tests/minimal_init.lua"
vp := justfile_directory() / "node_modules/.bin/vp"

_default:
	just -l

# .luarc.json reads Neovim's Lua API from $VIMRUNTIME, which only nvim knows.
# Hint is the lowest level, so lint reports what the editor shows.
lint:
	VIMRUNTIME="$(nvim --clean --headless --cmd 'lua io.write(vim.env.VIMRUNTIME)' --cmd 'qa!')" lua-language-server --configpath={{ justfile_directory() }}/.luarc.json --check={{ justfile_directory() }} --checklevel=Hint

# Lua through stylua, Markdown through Vite+ (`vp fmt`, config in vite.config.ts)
format: _node-modules
	stylua {{ justfile_directory() }}
	cd {{ justfile_directory() }} && {{ vp }} fmt '**/*.md'

format-check: _node-modules
	stylua --check {{ justfile_directory() }}
	cd {{ justfile_directory() }} && {{ vp }} fmt --check '**/*.md'

_node-modules:
	@test -x {{ quote(vp) }} || { echo 'vp is missing: run `npm ci`' >&2; exit 1; }

checks: lint format-check test

# Run the whole mini.test suite headless
test: deps
	@just _run-tests ""

# Run one test file, e.g. `just test-file tests/test_git.lua`
test-file FILE: deps
	@just _run-tests {{ quote(FILE) }}

# Runs ITER_TEST_FILE, or the whole suite when it is empty. A file that fails
# to load raises inside MiniTest.run, so the pcall turns it into exit 1.
_run-tests FILE:
	cd {{ justfile_directory() }} && ITER_TEST_FILE={{ quote(FILE) }} nvim --headless --noplugin -u {{ minimal_init }} -c "lua local f = vim.env.ITER_TEST_FILE or '' local ok, err = pcall(function() if f == '' then MiniTest.run() else MiniTest.run_file(f) end end) if not ok then io.stderr:write(tostring(err) .. '\\n') vim.cmd('cquit 1') end"

# Apply the repo's Git config (hooks in .githooks/), once per clone
git-config:
	git config core.hooksPath .githooks
	git config pull.rebase true
	git config merge.ff only

# Pin mini.nvim to REF (default: main's tip), then run the suite against it
bump-mini REF="":
	#!/usr/bin/env bash
	set -euo pipefail
	ref={{ quote(REF) }}
	if test -z "${ref}"; then
		ref="$(git ls-remote {{ mini_url }} refs/heads/main | cut -f1)"
	fi
	sed -i.bak "s/^mini_ref := \".*\"/mini_ref := \"${ref}\"/" {{ justfile_directory() }}/justfile
	rm {{ justfile_directory() }}/justfile.bak
	echo "mini_ref: {{ mini_ref }} -> ${ref}"
	just deps
	CI=1 just test

# Clone or update the pinned test dependencies into deps/
deps:
	#!/usr/bin/env bash
	set -euo pipefail

	pin() {
		local url="$1" ref="$2" path="{{ justfile_directory() }}/deps/$3"

		if ! test -d "${path}"; then
			git clone --quiet --filter=blob:none "${url}" "${path}"
		fi

		if ! git -C "${path}" cat-file -e "${ref}^{commit}" 2>/dev/null; then
			git -C "${path}" fetch --quiet origin
		fi

		git -C "${path}" -c advice.detachedHead=false checkout --quiet "${ref}"
	}

	pin {{ mini_url }} {{ mini_ref }} mini.nvim
