plenary_ref := "74b06c6c75e4eeb3108ec01852001636d85a932b"
plenary_url := "https://github.com/nvim-lua/plenary.nvim"
diffs_ref := "ef4db615efb4bdecfd54225dee137d703e422503"
diffs_url := "https://github.com/barrettruth/diffs.nvim"

_default:
	just -l

lint:
	lua-language-server --configpath={{ justfile_directory() }}/.luarc.json --check={{ justfile_directory() }}

format:
	stylua {{ justfile_directory() }}

format-check:
	stylua --check {{ justfile_directory() }}

checks: lint format-check test

test:
	#!/usr/bin/env bash
	# Some comment
	plenary_path="{{ justfile_directory() }}/plenary.nvim"

	if ! test -d "${plenary_path}"; then
		git clone {{ plenary_url }} "${plenary_path}"
	fi

	git -C "${plenary_path}" checkout "{{ plenary_ref }}"

	diffs_path="{{ justfile_directory() }}/diffs.nvim"

	if ! test -d "${diffs_path}"; then
		git clone {{ diffs_url }} "${diffs_path}"
	fi

	git -C "${diffs_path}" checkout "{{ diffs_ref }}"

	minimal_init="{{ justfile_directory() }}/tests/minimal_init.lua"
	nvim --headless --noplugin \
		-u "${minimal_init}" \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '${minimal_init}' })"
