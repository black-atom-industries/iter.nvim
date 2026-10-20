---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@class GitStatusSnapshot
---@field branch string
---@field entries GitStatusEntry[]
---@field detached boolean? HEAD is not on a branch
---@field root string
---@field error string?

local git = {}

local log = require('iter.log')
local patch = require('iter.diff.patch')
local util = require('iter.util')

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

---@type boolean?
local has_git

--- Whether `git` is executable, checked once; the first miss tells the user.
---@return boolean
local function ensure_git()
    if has_git == nil then
        has_git = vim.fn.executable('git') == 1

        if not has_git then
            util.error('`git` is not executable')
        end
    end

    return has_git
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
        detached = detached,
        root = root,
    }
end

--- `git.status_snapshot` without waiting: the branch and the entries of
--- `root`, read in the background, then `on_done` on the main loop.
---@param root string
---@param on_done fun(snapshot: GitStatusSnapshot)
function git.status_async(root, on_done)
    local done = vim.schedule_wrap(on_done)

    if vim.fn.executable('git') == 0 then
        done({
            branch = '',
            entries = {},
            root = root,
            error = '`git` is not executable',
        })
        return
    end

    -- A spawn that fails, such as on a root removed meanwhile, reads as a
    -- failed command.
    local function run(args, on_exit)
        local cmd = vim.list_extend({ 'git', '--no-optional-locks' }, args)
        local ok, err =
            pcall(vim.system, cmd, { text = true, cwd = root }, on_exit)

        if not ok then
            on_exit({ code = -1, stdout = '', stderr = tostring(err) })
        end
    end

    run({ 'branch', '--show-current' }, function(branch_out)
        run(
            { 'status', '--porcelain=v1', '-z', '--untracked-files=all' },
            function(status_out)
                local branch = vim.trim(branch_out.stdout or '')
                local failed = branch_out.code ~= 0 and branch_out
                    or status_out.code ~= 0 and status_out
                    or nil

                if failed ~= nil then
                    done({
                        branch = branch,
                        entries = {},
                        root = root,
                        error = vim.trim(failed.stderr or ''),
                    })
                    return
                end

                done({
                    branch = branch,
                    entries = parse_status(status_out.stdout or ''),
                    detached = branch == '',
                    root = root,
                })
            end
        )
    end)
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

--- On an unborn HEAD, `rm --cached` takes the paths out of the index and
--- leaves the worktree files; `--force` lets it drop staged content that
--- differs from the worktree too.
---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.unstage(root, paths)
    local head = git.run(
        { 'rev-parse', '--verify', '--quiet', 'HEAD' },
        { cwd = root, ignore_error = true }
    )

    if head.exit_code ~= 0 then
        return run_on_paths(
            root,
            { 'rm', '--cached', '--force', '--quiet' },
            paths
        )
    end

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

--- Append `path`, a path of `root`, to the `.gitignore` at `root` as a
--- pattern anchored to the root: `/path`, or `/dir/` for a directory given
--- as `dir/`. Glob characters and trailing spaces are escaped, so the
--- pattern matches the path alone. The file is created when missing; a last
--- line without a newline gets one first. No other file is touched.
---@param root string
---@param path string
---@return boolean
---@return string? error
function git.ignore(root, path)
    local file = vim.fs.joinpath(root, '.gitignore')
    local pattern = path:gsub('[\\*?%[]', '\\%0')
    local body, spaces = pattern:match('^(.-)( *)$')
    pattern = '/' .. body .. spaces:gsub(' ', '\\ ')

    local content = ''
    local reader = io.open(file, 'rb')

    if reader ~= nil then
        content = reader:read('*a') or ''
        reader:close()
    end

    local writer, err = io.open(file, 'ab')

    if writer == nil then
        return false, err
    end

    local lead = (content ~= '' and content:sub(-1) ~= '\n') and '\n' or ''
    local ok, write_err = writer:write(lead .. pattern .. '\n')

    writer:close()

    if not ok then
        return false, write_err
    end

    return true
end

--- Apply the patch `lines` (carriage returns kept) to the index for
--- `stage`, reversed for `unstage`. With `opts.check` git only checks that it
--- applies. The whitespace flags pin what lands to the patch text, whatever
--- the config.
---@param root string
---@param lines string[]
---@param kind 'stage'|'unstage'
---@param opts? { check?: boolean }
---@return boolean
---@return string
function git.apply_patch(root, lines, kind, opts)
    if #lines == 0 then
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
        stdin = table.concat(lines, '\n') .. '\n',
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

--- The lines of a blob, nil when it doesn't exist.
---@param root string
---@param spec string blob spec such as `:path` or `HEAD:path`
---@return string[]?
function git.blob_lines(root, spec)
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
---@param args string[] extra flags for `git diff`, the `diff.args` option
---@param bytes boolean
---@return string[]?
---@return string? error
local function diff_text(root, change, args, bytes)
    vim.validate('args', args, 'table')

    local untracked = change.code == '?'
    local cmd

    if untracked then
        cmd = { 'diff', '--no-index' }
    elseif change.side == 'staged' then
        cmd = { 'diff', '--cached', '-M' }
    else
        cmd = { 'diff' }
    end

    vim.list_extend(cmd, args)
    vim.list_extend(cmd, DIFF_FLAGS)
    table.insert(cmd, '--')

    if untracked then
        vim.list_extend(cmd, { '/dev/null', change.path })
    else
        if change.orig_path ~= nil then
            table.insert(cmd, change.orig_path)
        end
        table.insert(cmd, change.path)
    end

    local out = git.run(cmd, { cwd = root, ignore_error = true, bytes = bytes })

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
---@param args string[] extra flags for `git diff`, the same as for `git.file_diff`
---@return string[]?
---@return string? error
function git.file_diff_bytes(root, change, args)
    return diff_text(root, change, args, true)
end

--- Diff text and both full versions of one file. Unstaged compares the index
--- with the worktree, staged compares HEAD with the index. Untracked and
--- added files have an empty old side, deleted files an empty new side.
---@param root string
---@param change IterDiffChange
---@param args string[] extra flags for `git diff`, the `diff.args` option
---@return IterFileSource?
---@return string? error
function git.file_diff(root, change, args)
    -- Read as bytes and normalized here: text mode drops CRs per output
    -- chunk, so a CRLF split across two chunks would keep its CR.
    local bytes, err = diff_text(root, change, args, true)

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
        old_lines = git.blob_lines(root, 'HEAD:' .. old_path)
    else
        old_lines = git.blob_lines(root, ':' .. old_path)
    end

    if change.code == 'D' then
        new_lines = {}
    elseif change.side == 'staged' then
        new_lines = git.blob_lines(root, ':' .. change.path)
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

--- The modes and blob ids each changed file's diff compares, by
--- `side \0 path`: the index against the worktree for unstaged files (the
--- worktree's id stays zero), HEAD against the index for staged ones. Two
--- reads with the same entry, and for an unstaged file the same worktree
--- stat, give the same diff text. Untracked files are left out.
---@param root string
---@return table<string, string>?
function git.diff_ids(root)
    local ids = {}
    local reads = {
        unstaged = { 'diff', '--no-renames' },
        staged = { 'diff', '--cached', '-M' },
    }

    for side, args in pairs(reads) do
        vim.list_extend(args, { '--raw', '-z', '--no-abbrev', '--no-color' })

        local out = git.run(args, { cwd = root, ignore_error = true })

        if out.exit_code ~= 0 then
            return nil
        end

        local fields = vim.split(out.output, '\0', { plain = true })
        local index = 1

        while fields[index] ~= nil and fields[index] ~= '' do
            local info, path = fields[index], fields[index + 1]
            local status = info:match('(%a)%d*$')

            index = index + 2

            if status == 'R' or status == 'C' then
                info = info .. '\0' .. path
                path = fields[index]
                index = index + 1
            end

            if path ~= nil then
                ids[side .. '\0' .. path] = info
            end
        end
    end

    return ids
end

---@class GitCommit
---@field sha string abbreviated
---@field subject string
---@field time integer committer date, seconds since the epoch
---@field unpushed boolean not on the upstream

---@class GitRecent where HEAD stands against its upstream
---@field key string HEAD, the upstream and the count it was read for
---@field upstream? string short name such as `origin/main`, nil without one
---@field ahead integer commits on HEAD and not on the upstream
---@field behind integer commits on the upstream and not on HEAD
---@field commits GitCommit[] newest first

local SEP = '\31'

---@param line string?
---@return boolean
local function is_sha(line)
    return line ~= nil
        and (#line == 40 or #line == 64)
        and line:match('^%x+$') ~= nil
end

--- The last `count` commits of HEAD and how far it is ahead of and behind
--- its upstream, as last fetched. One `rev-parse` reads HEAD and the
--- upstream; when they and `count` match `prev`, `prev` comes back as it is
--- and nothing else runs. A detached HEAD has no upstream.
---@param root string
---@param count integer
---@param prev? GitRecent
---@return GitRecent? recent nil when HEAD has no commit
function git.recent(root, count, prev)
    local out = git.run({
        'rev-parse',
        'HEAD',
        '@{upstream}',
        '--abbrev-ref',
        '@{upstream}',
    }, { cwd = root, ignore_error = true })
    local lines = split_output(out.output)
    local head = lines[1]

    if not is_sha(head) then
        return nil
    end

    local upstream_sha, upstream

    if out.exit_code == 0 and is_sha(lines[2]) and lines[3] ~= nil then
        upstream_sha, upstream = lines[2], lines[3]
    end

    local key = table.concat(
        { tostring(count), head, upstream_sha or '', upstream or '' },
        SEP
    )

    if prev ~= nil and prev.key == key then
        return prev
    end

    ---@type GitRecent
    local recent = {
        key = key,
        upstream = upstream,
        ahead = 0,
        behind = 0,
        commits = {},
    }
    local unpushed = {}

    if upstream_sha ~= nil then
        local sides = git.run(
            { 'rev-list', '--left-right', head .. '...' .. upstream_sha },
            { cwd = root, ignore_error = true }
        )

        for _, line in ipairs(split_output(sides.output)) do
            if vim.startswith(line, '<') then
                recent.ahead = recent.ahead + 1
                unpushed[line:sub(2)] = true
            elseif vim.startswith(line, '>') then
                recent.behind = recent.behind + 1
            end
        end
    end

    if count == 0 then
        return recent
    end

    local commits = git.run({
        'log',
        '--no-color',
        '--no-show-signature',
        '--max-count=' .. count,
        '--format=%H%x1f%h%x1f%ct%x1f%s',
        head,
        '--',
    }, { cwd = root, ignore_error = true })

    for _, line in ipairs(split_output(commits.output)) do
        local fields = vim.split(line, SEP, { plain = true })

        if #fields >= 4 then
            table.insert(recent.commits, {
                sha = fields[2],
                subject = table.concat(fields, SEP, 4),
                time = tonumber(fields[3]) or 0,
                unpushed = unpushed[fields[1]] == true,
            })
        end
    end

    return recent
end

return git
