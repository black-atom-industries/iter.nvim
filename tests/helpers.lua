---@class IterTestHelpers
local M = {}

local project_root = vim.fs.dirname(
    vim.fs.dirname(
        vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
    )
)

M.minimal_init = vim.fs.joinpath(project_root, 'tests', 'minimal_init.lua')

--- Run git in `repo` and return stdout. Raises on a non-zero exit.
---@param repo string
---@param args string[]
---@return string
function M.git(repo, args)
    local result = vim.system(vim.list_extend({ 'git' }, args), {
        text = true,
        cwd = repo,
    }):wait()

    if result.code ~= 0 then
        error(
            string.format(
                'git %s failed (%d): %s',
                table.concat(args, ' '),
                result.code,
                result.stderr or ''
            ),
            2
        )
    end

    return result.stdout or ''
end

---@param path string
---@param lines string[]
function M.write_file(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile(lines, path)
end

--- Create a git repository in a fresh temporary directory on branch `main`
--- with `files` (relative path -> lines) committed as the initial commit.
---@param files table<string, string[]>
---@return string repo
function M.create_repo(files)
    local repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')

    M.git(repo, { 'init', '--quiet', '-b', 'main' })

    for path, lines in pairs(files) do
        M.write_file(vim.fs.joinpath(repo, path), lines)
    end

    M.git(repo, { 'add', '--all' })
    M.git(repo, { 'commit', '--quiet', '--allow-empty', '-m', 'initial' })

    return repo
end

--- Create a repository whose working tree holds one entry of each kind:
--- `modified.txt` (unstaged change), `staged.txt` (staged change),
--- `deleted.txt` (deleted in the working tree), `untracked.txt` and
--- `untracked_dir/` with two files.
---@return string repo
function M.create_fixture_repo()
    local repo = M.create_repo({
        ['modified.txt'] = { 'one', 'two', 'three' },
        ['staged.txt'] = { 'alpha' },
        ['deleted.txt'] = { 'gone soon' },
    })

    M.write_file(
        vim.fs.joinpath(repo, 'modified.txt'),
        { 'one', 'two changed', 'three' }
    )
    M.write_file(vim.fs.joinpath(repo, 'staged.txt'), { 'alpha', 'beta' })
    M.git(repo, { 'add', 'staged.txt' })
    vim.fn.delete(vim.fs.joinpath(repo, 'deleted.txt'))
    M.write_file(vim.fs.joinpath(repo, 'untracked.txt'), { 'new' })
    M.write_file(vim.fs.joinpath(repo, 'untracked_dir', 'a.txt'), { 'a' })
    M.write_file(vim.fs.joinpath(repo, 'untracked_dir', 'b.txt'), { 'b' })

    return repo
end

--- Create a repository whose paths hold spaces and non-ASCII characters:
--- `sp ace/ü.txt` (unstaged change) and the untracked directory `ne w/`
--- with `ö ä.txt`.
---@return string repo
function M.create_odd_paths_repo()
    local repo = M.create_repo({ ['sp ace/ü.txt'] = { 'one', 'two' } })

    M.write_file(
        vim.fs.joinpath(repo, 'sp ace', 'ü.txt'),
        { 'one', 'two changed' }
    )
    M.write_file(vim.fs.joinpath(repo, 'ne w', 'ö ä.txt'), { 'neu' })

    return repo
end

--- Give `repo` a bare repository in a fresh temporary directory as its
--- `origin` and push its branch `main` there as the upstream.
---@param repo string
---@return string remote
function M.create_remote(repo)
    local remote = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(remote, 'p')

    M.git(remote, { 'init', '--quiet', '--bare', '-b', 'main' })
    M.git(repo, { 'remote', 'add', 'origin', remote })
    M.git(repo, { 'push', '--quiet', '-u', 'origin', 'main' })

    return remote
end

--- Push a commit with `message` to `remote`'s `main` from a second clone,
--- so a repository tracking it falls behind once it fetches.
---@param remote string
---@param message string
function M.push_from_clone(remote, message)
    local clone = vim.fn.resolve(vim.fn.tempname())

    M.git(vim.fs.dirname(clone), { 'clone', '--quiet', remote, clone })
    M.git(clone, { 'commit', '--quiet', '--allow-empty', '-m', message })
    M.git(clone, { 'push', '--quiet', 'origin', 'main' })
    M.cleanup(clone)
end

---@param repo string?
function M.cleanup(repo)
    if repo ~= nil and repo ~= '' then
        vim.fn.delete(repo, 'rf')
    end
end

--- Start `child` with the plugin loaded, cwd in `repo` and a screen setup
--- that renders the same on every machine: fixed size, no statusline,
--- ruler or showmode, and a cmdheight that never triggers hit-enter.
---@param child table MiniTest child Neovim
---@param repo string
---@param opts? { lines?: integer, columns?: integer }
function M.start_child(child, repo, opts)
    opts = opts or {}
    child.start({ '-u', M.minimal_init })
    -- Copies stay in the child instead of reaching the system clipboard.
    child.lua([[
        local clip = { {}, 'v' }
        local function copy(lines, regtype)
            clip = { lines, regtype }
        end
        local function paste()
            return clip
        end
        vim.g.clipboard = {
            name = 'iter-test',
            copy = { ['+'] = copy, ['*'] = copy },
            paste = { ['+'] = paste, ['*'] = paste },
        }
    ]])
    child.o.lines = opts.lines or 24
    child.o.columns = opts.columns or 80
    child.o.laststatus = 0
    child.o.ruler = false
    child.o.showmode = false
    child.o.showcmd = false
    child.o.cmdheight = 1
    child.o.shortmess = child.o.shortmess .. 'IFW'
    child.cmd('cd ' .. vim.fn.fnameescape(repo))
end

--- Compare the child's screen with `tests/screenshots/<name>`. A missing
--- reference is created locally but fails when `CI` is set, so CI never
--- passes by writing its own reference.
---@param child table MiniTest child Neovim
---@param name string
function M.expect_screenshot(child, name)
    local path = vim.fs.joinpath(project_root, 'tests', 'screenshots', name)

    if vim.env.CI ~= nil and vim.fn.filereadable(path) == 0 then
        error('Missing reference screenshot: ' .. path, 2)
    end

    MiniTest.expect.reference_screenshot(child.get_screenshot(), path)
end

--- Wait in the child until the Lua expression `condition` is truthy.
---@param child table MiniTest child Neovim
---@param condition string Lua expression evaluated in the child
---@param timeout? integer milliseconds, default 2000
function M.wait_until(child, condition, timeout)
    local ok = child.lua_get(
        string.format(
            'vim.wait(%d, function() return (%s) and true or false end, 10)',
            timeout or 2000,
            condition
        )
    )

    if not ok then
        error('Timed out waiting for: ' .. condition, 2)
    end
end

return M
