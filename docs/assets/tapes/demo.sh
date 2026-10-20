#!/bin/sh
# Creates the throwaway repository the clips record: `demo.sh <dir>`.
# <dir> must not exist. A bare `origin` sits beside it, one commit behind.
set -eu

dir=$1
test ! -e "$dir" || { echo "demo.sh: $dir exists" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Iter Demo' GIT_AUTHOR_EMAIL='demo@example.test'
export GIT_COMMITTER_NAME='Iter Demo' GIT_COMMITTER_EMAIL='demo@example.test'

now=$(date +%s)
commit() {
	GIT_AUTHOR_DATE="$(($now - $1)) +0000" GIT_COMMITTER_DATE="$(($now - $1)) +0000" \
		git commit --quiet -m "$2"
}

git init --quiet --initial-branch=main "$dir"
cd "$dir"

mkdir -p lua/kettle
cat > lua/kettle/init.lua <<'LUA'
local M = {}

M.config = {
    temperature = 95,
    steep_minutes = 3,
}

function M.setup(opts)
    M.config = vim.tbl_extend('force', M.config, opts or {})
end

function M.brew(tea)
    local minutes = tea.minutes or M.config.steep_minutes
    vim.notify(('Steeping %s for %d minutes'):format(tea.name, minutes))
end

return M
LUA
cat > lua/kettle/teas.lua <<'LUA'
return {
    { name = 'sencha', minutes = 2 },
    { name = 'assam', minutes = 4 },
    { name = 'rooibos', minutes = 6 },
}
LUA
printf '# kettle.nvim\n\nBrew tea without leaving Neovim.\n' > README.md
git add -A
commit 259200 'feat: brew tea'

cat > lua/kettle/timer.lua <<'LUA'
local M = {}

function M.start(minutes, done)
    local timer = vim.uv.new_timer()
    timer:start(minutes * 60 * 1000, 0, vim.schedule_wrap(done))
    return timer
end

return M
LUA
git add -A
commit 18000 'feat: steep timer'

git clone --quiet --bare . ../origin.git
git remote add origin ../origin.git
git fetch --quiet origin
git branch --quiet --set-upstream-to=origin/main

printf '# kettle.nvim\n\nBrew tea without leaving Neovim.\n\n```lua\nrequire("kettle").setup()\n```\n' > README.md
git add README.md
commit 1200 'docs: setup snippet'

# Unstaged edits, one staged edit, one untracked file.
cat > lua/kettle/init.lua <<'LUA'
local timer = require('kettle.timer')

local M = {}

M.config = {
    temperature = 90,
    steep_minutes = 3,
}

function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

function M.brew(tea)
    local minutes = tea.minutes or M.config.steep_minutes
    vim.notify(('Steeping %s for %d minutes'):format(tea.name, minutes))
    timer.start(minutes, function()
        vim.notify(tea.name .. ' is ready')
    end)
end

return M
LUA
cat > lua/kettle/teas.lua <<'LUA'
return {
    { name = 'sencha', minutes = 2 },
    { name = 'assam', minutes = 4 },
    { name = 'oolong', minutes = 3 },
    { name = 'rooibos', minutes = 6 },
}
LUA
sed -i.bak 's/vim.uv.new_timer()/assert(vim.uv.new_timer())/' lua/kettle/timer.lua
rm lua/kettle/timer.lua.bak
git add lua/kettle/timer.lua
cat > lua/kettle/health.lua <<'LUA'
local M = {}

function M.check()
    vim.health.start('kettle')
    vim.health.ok('water is hot')
end

return M
LUA
