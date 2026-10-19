---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@class GitStatusSnapshot
---@field branch string
---@field entries GitStatusEntry[]
---@field ahead integer? commits ahead of the upstream, nil without one
---@field detached boolean? HEAD is not on a branch
---@field root string
---@field error string?

local git = {}

local log = require('iter.log')
local patch = require('iter.diff.patch')

---@param output string
---@param start integer
---@return string?, integer?
local function read_nul_field(output, start)
    local stop = output:find('\0', start, true)

    if stop == nil then
        return nil, nil
    end

    return output:sub(start, stop - 1), stop + 1
end

---@param staged string
---@param unstaged string
---@return boolean
local function is_rename_or_copy(staged, unstaged)
    return staged == 'R' or staged == 'C' or unstaged == 'R' or unstaged == 'C'
end

---@param output string
---@return GitStatusEntry[]
local function parse_status(output)
    local entries = {}
    local index
    index = 1

    while index <= #output do
        local record
        record, index = read_nul_field(output, index)

        if record == nil or index == nil then
            break
        end

        if record ~= '' then
            local staged = record:sub(1, 1)
            local unstaged = record:sub(2, 2)

            ---@type GitStatusEntry
            local entry = {
                staged = staged,
                unstaged = unstaged,
                path = record:sub(4),
            }

            if is_rename_or_copy(staged, unstaged) then
                entry.orig_path, index = read_nul_field(output, index)
            end

            table.insert(entries, entry)
        end
    end

    return entries
end

---@return boolean
local function ensure_git()
    local ok = vim.fn.executable('git')

    if ok == 0 then
        log.error('`git` is not executable')
        vim.print('[iter] `git` is not executable')
        return false
    end

    return true
end

---@alias GitResult {
---output: string,
---exit_code: number,
---stderr: string,
---}

local return_result

---Executes a git command and returns the result
---@param args string[] List of git arguments (e.g., {"status", "--porcelain"})
---@param opts? table Options { cwd = string?, ignore_error = boolean?, stdin = string?, bytes = boolean? }; `bytes` keeps carriage returns in the output
---@return GitResult
function git.run(args, opts)
    opts = opts or {}

    if not ensure_git() then
        return {
            output = '',
            exit_code = 127,
            stderr = '`git` is not executable',
        }
    end

    -- --no-optional-locks keeps read-only commands (status, diff) from
    -- opportunistically rewriting .git/index, which would re-trigger the
    -- fs-event watchers and loop the auto-refresh.
    local cmd = { 'git', '--no-optional-locks' }
    vim.list_extend(cmd, args)

    local cwd = opts.cwd or vim.fn.getcwd()

    local job = vim.system(
        cmd,
        { text = not opts.bytes, cwd = cwd, stdin = opts.stdin }
    )
    local result = job:wait()

    local output = result.stdout or ''
    local stderr = result.stderr or ''
    local exit_code = result.code or 1

    if exit_code ~= 0 and not opts.ignore_error then
        log.error(
            string.format(
                'git command failed (%d): %s\n%s',
                exit_code,
                table.concat(cmd, ' '),
                stderr
            )
        )
    end

    log.debug(string.format('%s (%d)', table.concat(cmd, ' '), exit_code))

    return {
        output = output,
        exit_code = exit_code,
        stderr = stderr,
    }
end

---@param res GitResult
---@return string
function return_result(res)
    local value = res.exit_code == 0 and res.output or res.stderr

    -- Preserve meaningful leading spaces in outputs like `git status --short`.
    local v, _ = value:gsub('[\r\n]+$', '')
    return v
end

---@return string
function git.root()
    ensure_git()

    local out = git.run(
        { 'rev-parse', '--show-toplevel' },
        { ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return ''
    end

    return return_result(out)
end

---@param root? string worktree root, the one of the cwd when nil
---@return GitStatusSnapshot
function git.status_snapshot(root)
    if not ensure_git() then
        return {
            branch = '',
            entries = {},
            root = '',
            error = '`git` is not executable',
        }
    end

    root = root or git.root()

    if root == '' then
        return {
            branch = '',
            entries = {},
            root = '',
            error = 'Not inside a git repository',
        }
    end

    local branch_out = git.run(
        { 'branch', '--show-current' },
        { cwd = root, ignore_error = true }
    )
    local branch = return_result(branch_out)
    local detached = branch == ''

    if branch == '' then
        local head_out = git.run(
            { 'rev-parse', '--short', 'HEAD' },
            { cwd = root, ignore_error = true }
        )

        branch = head_out.exit_code == 0 and return_result(head_out)
            or '(unknown)'
    end

    local status_out = git.run(
        { 'status', '--porcelain=v1', '-z', '--untracked-files=all' },
        { cwd = root }
    )

    if status_out.exit_code ~= 0 then
        return {
            branch = branch,
            entries = {},
            root = root,
            error = return_result(status_out),
        }
    end

    return {
        branch = branch,
        entries = parse_status(status_out.output),
        ahead = git.ahead(root),
        detached = detached,
        root = root,
    }
end

---Number of commits HEAD is ahead of its upstream.
---@param root string
---@return integer? ahead nil when there is no upstream
function git.ahead(root)
    local out = git.run(
        { 'rev-list', '--count', '@{upstream}..HEAD' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil
    end

    return tonumber(return_result(out))
end

---Absolute paths of files in the git dir, e.g. `index` and `HEAD`. In a
---linked worktree they live under the common dir's `worktrees/<name>/`.
---@param root string
---@param names string[]
---@return string[]? paths nil outside a repository
function git.git_paths(root, names)
    local args = { 'rev-parse', '--path-format=absolute' }

    for _, name in ipairs(names) do
        vim.list_extend(args, { '--git-path', name })
    end

    local out = git.run(args, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil
    end

    return vim.split(return_result(out), '\n', { plain = true })
end

---The identity of the repository `root` belongs to, the same for all of its
---linked worktrees: `<name>-<sha8>`, where name is the main worktree's
---directory and sha8 the first 8 hex of the sha256 of the resolved common
---git dir.
---@param root string
---@return string? id nil outside a repository
---@return string? error
function git.repo_id(root)
    local out = git.run(
        { 'rev-parse', '--path-format=absolute', '--git-common-dir' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    local common = return_result(out)
    common = vim.uv.fs_realpath(common) or common

    local name = vim.fs.basename(common)

    if name == '.git' then
        name = vim.fs.basename(vim.fs.dirname(common))
    else
        name = name:gsub('%.git$', '')
    end

    return name .. '-' .. vim.fn.sha256(common):sub(1, 8)
end

---The branch HEAD of `root` is on, also when it has no commit yet.
---@param root string
---@return string? branch nil when HEAD is detached or outside a repository
function git.head_branch(root)
    local out = git.run(
        { 'symbolic-ref', '--quiet', 'HEAD' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil
    end

    local ref = return_result(out)

    if not vim.startswith(ref, 'refs/heads/') then
        return nil
    end

    return ref:sub(#'refs/heads/' + 1)
end

--- Run `args -- <paths>` in `root`, every path a literal pathspec so glob
--- characters in file names never widen the action.
---@param root string
---@param args string[]
---@param paths string[]
---@return boolean
---@return string?
local function run_on_paths(root, args, paths)
    ensure_git()

    if #paths == 0 then
        return true
    end

    local cmd = vim.list_extend(vim.deepcopy(args), { '--' })

    for _, path in ipairs(paths) do
        table.insert(cmd, ':(literal)' .. path)
    end

    local out = git.run(cmd, { cwd = root, ignore_error = true })

    return out.exit_code == 0, return_result(out)
end

---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.stage(root, paths)
    return run_on_paths(root, { 'add' }, paths)
end

---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.unstage(root, paths)
    return run_on_paths(root, { 'restore', '--staged' }, paths)
end

--- Restore the worktree from the index; staged changes stay.
---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.discard(root, paths)
    return run_on_paths(root, { 'restore', '--worktree' }, paths)
end

--- Delete untracked files. Tracked and ignored paths are left alone, and
--- directories are not recursed into.
---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.delete_untracked(root, paths)
    return run_on_paths(root, { 'clean', '--force' }, paths)
end

--- Apply `patch` (lines, carriage returns kept) to the index for `stage`,
--- reversed for `unstage`. With `opts.check` git only checks that it
--- applies. The whitespace flags pin what lands to the patch text, whatever
--- the config.
---@param root string
---@param patch string[]
---@param kind 'stage'|'unstage'
---@param opts? { check?: boolean }
---@return boolean
---@return string
function git.apply_patch(root, patch, kind, opts)
    ensure_git()

    if #patch == 0 then
        return false, 'No patch to apply'
    end

    if kind ~= 'stage' and kind ~= 'unstage' then
        return false, 'Unknown hunk action: ' .. kind
    end

    local args = {
        'apply',
        '--cached',
        '--whitespace=nowarn',
        '--no-ignore-whitespace',
    }

    if kind == 'unstage' then
        table.insert(args, '--reverse')
    end

    if opts ~= nil and opts.check then
        table.insert(args, '--check')
    end

    table.insert(args, '-')

    local out = git.run(args, {
        cwd = root,
        ignore_error = true,
        stdin = table.concat(patch, '\n') .. '\n',
    })

    return out.exit_code == 0, return_result(out)
end

---@param path string
---@param root string?
---@return string[]
---@return string?
local function read_worktree_lines(path, root)
    root = root or git.root()

    local full_path = root ~= '' and vim.fs.joinpath(root, path) or path
    local stat = vim.uv.fs_stat(full_path)

    if stat == nil then
        return {}, 'Cannot stat file: ' .. full_path
    end

    if stat.type == 'directory' then
        return {}, 'Diff preview is not available for directories'
    end

    local ok, lines = pcall(vim.fn.readfile, full_path)

    if not ok then
        return {}, 'Cannot read file: ' .. tostring(lines)
    end

    return lines, nil
end

---@class IterFileSource
---@field raw string[] git diff text
---@field old_lines? string[] nil for binary files
---@field new_lines? string[] nil for binary files
---@field binary boolean

-- Flags that keep the diff text parseable, and applicable with `-p1`,
-- whatever the user's git config.
local DIFF_FLAGS = {
    '--no-color',
    '--no-ext-diff',
    '--no-textconv',
    '--src-prefix=a/',
    '--dst-prefix=b/',
}

---@param output string
---@return string[]
local function split_output(output)
    if output == '' then
        return {}
    end

    local lines = vim.split(output, '\n', { plain = true })

    if lines[#lines] == '' then
        table.remove(lines)
    end

    return lines
end

---@param root string
---@param spec string blob spec such as `:path` or `HEAD:path`
---@return string[]?
local function blob_lines(root, spec)
    local out = git.run({ 'show', spec }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil
    end

    return split_output(out.output)
end

---@param raw string[]
---@return boolean
local function is_binary_diff(raw)
    for _, line in ipairs(raw) do
        if
            vim.startswith(line, 'Binary files ')
            or line == 'GIT binary patch'
        then
            return true
        end
    end

    return false
end

--- The diff text of one file, see `git.file_diff`. With `bytes` the lines
--- keep their carriage returns.
---@param root string
---@param change { path: string, orig_path?: string, side: IterSide, code: string }
---@param bytes boolean
---@return string[]?
---@return string? error
local function diff_text(root, change, bytes)
    local untracked = change.code == '?'
    local args

    if untracked then
        args = { 'diff', '--no-index' }
    elseif change.side == 'staged' then
        args = { 'diff', '--cached', '-M' }
    else
        args = { 'diff' }
    end

    vim.list_extend(args, DIFF_FLAGS)
    table.insert(args, '--')

    if untracked then
        vim.list_extend(args, { '/dev/null', change.path })
    else
        if change.orig_path ~= nil then
            table.insert(args, change.orig_path)
        end
        table.insert(args, change.path)
    end

    local out =
        git.run(args, { cwd = root, ignore_error = true, bytes = bytes })

    -- `--no-index` exits 1 when the files differ.
    if out.exit_code > 1 or (out.exit_code == 1 and not untracked) then
        return nil, return_result(out)
    end

    return split_output(out.output)
end

--- The diff text of `git.file_diff` byte for byte: lines of a CRLF file
--- keep their carriage returns, as a patch for `git apply` needs them.
---@param root string
---@param change { path: string, orig_path?: string, side: IterSide, code: string }
---@return string[]?
---@return string? error
function git.file_diff_bytes(root, change)
    ensure_git()

    return diff_text(root, change, true)
end

--- Diff text and both full versions of one file. Unstaged compares the index
--- with the worktree, staged compares HEAD with the index. Untracked and
--- added files have an empty old side, deleted files an empty new side.
---@param root string
---@param change { path: string, orig_path?: string, side: IterSide, code: string }
---@return IterFileSource?
---@return string? error
function git.file_diff(root, change)
    ensure_git()

    -- Read as bytes and normalized here: text mode drops CRs per output
    -- chunk, so a CRLF split across two chunks would keep its CR.
    local bytes, err = diff_text(root, change, true)

    if bytes == nil then
        return nil, err
    end

    local raw = patch.text(bytes)

    local untracked = change.code == '?'

    if is_binary_diff(raw) then
        return { raw = raw, binary = true }
    end

    local old_path = change.orig_path or change.path
    local old_lines, new_lines

    if untracked or change.code == 'A' then
        old_lines = {}
    elseif change.side == 'staged' then
        old_lines = blob_lines(root, 'HEAD:' .. old_path)
    else
        old_lines = blob_lines(root, ':' .. old_path)
    end

    if change.code == 'D' then
        new_lines = {}
    elseif change.side == 'staged' then
        new_lines = blob_lines(root, ':' .. change.path)
    else
        new_lines = read_worktree_lines(change.path, root)
    end

    return {
        raw = raw,
        old_lines = old_lines,
        new_lines = new_lines,
        binary = false,
    }
end

return git
