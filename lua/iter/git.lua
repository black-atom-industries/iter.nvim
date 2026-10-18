---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@class GitCommit
---@field hash string
---@field short_hash string
---@field message string

---@class GitFileChangeCounts
---@field added integer
---@field modified integer
---@field deleted integer

---@class GitStatusSnapshot
---@field branch string
---@field entries GitStatusEntry[]
---@field unpushed_commits GitCommit[]
---@field ahead integer? commits ahead of the upstream, nil without one
---@field detached boolean? HEAD is not on a branch
---@field root string
---@field error string?

local git = {}

local log = require('iter.log')

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

---@alias GitAsyncCallback fun(ok: boolean, output: string)

local return_result

---Executes a git command and returns the result
---@param args string[] List of git arguments (e.g., {"status", "--porcelain"})
---@param opts? table Options { cwd = string?, ignore_error = boolean? }
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

    local job = vim.system(cmd, { text = true, cwd = cwd })
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

    log.info(
        string.format(
            'output=%s, exit_code=%d, stderr=%s',
            output,
            exit_code,
            stderr
        )
    )

    return {
        output = output,
        exit_code = exit_code,
        stderr = stderr,
    }
end

---Executes a git command asynchronously.
---@param args string[] List of git arguments (e.g., {"push"})
---@param opts? table Options { cwd = string?, ignore_error = boolean? }
---@param callback GitAsyncCallback
function git.run_async(args, opts, callback)
    opts = opts or {}

    if not ensure_git() then
        callback(false, '`git` is not executable')
        return
    end

    local cmd = { 'git', '--no-optional-locks' }
    vim.list_extend(cmd, args)

    local cwd = opts.cwd or vim.fn.getcwd()

    vim.system(cmd, { text = true, cwd = cwd }, function(result)
        vim.schedule(function()
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

            log.info(
                string.format(
                    'output=%s, exit_code=%d, stderr=%s',
                    output,
                    exit_code,
                    stderr
                )
            )

            callback(
                exit_code == 0,
                return_result({
                    output = output,
                    exit_code = exit_code,
                    stderr = stderr,
                })
            )
        end)
    end)
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
function git.branch()
    ensure_git()

    local out = git.run({ 'branch', '--show-current' })

    return return_result(out)
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

---@return GitStatusEntry[]
function git.status()
    ensure_git()

    local out = git.run({ 'status', '--porcelain=v1', '-z' })

    if out.exit_code ~= 0 then
        return {}
    end

    return parse_status(out.output)
end

---@return GitStatusSnapshot
function git.status_snapshot()
    if not ensure_git() then
        return {
            branch = '',
            entries = {},
            unpushed_commits = {},
            root = '',
            error = '`git` is not executable',
        }
    end

    local root = git.root()

    if root == '' then
        return {
            branch = '',
            entries = {},
            unpushed_commits = {},
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
        { 'status', '--porcelain=v1', '-z' },
        { cwd = root }
    )

    if status_out.exit_code ~= 0 then
        return {
            branch = branch,
            entries = {},
            unpushed_commits = {},
            root = root,
            error = return_result(status_out),
        }
    end

    return {
        branch = branch,
        entries = parse_status(status_out.output),
        unpushed_commits = git.unpushed_commits(root),
        ahead = git.ahead(root),
        detached = detached,
        root = root,
    }
end

local COMMIT_FIELD_SEPARATOR = '\31'
local NO_UPSTREAM_MESSAGE = function()
    return 'No upstream configured. Run git push -u origin ' .. git.branch()
end

---@param output string
---@return GitCommit[]
local function parse_commits(output)
    local commits = {}

    for _, line in ipairs(vim.split(output, '\n', { plain = true })) do
        if line ~= '' then
            local sep = line:find(COMMIT_FIELD_SEPARATOR, 1, true)

            if sep ~= nil then
                local hash = line:sub(1, sep - 1)
                local short_hash = hash:sub(1, 7)
                local message = line:sub(sep + 1)

                if message ~= '' then
                    table.insert(commits, {
                        hash = hash,
                        short_hash = short_hash,
                        message = message,
                    })
                end
            end
        end
    end

    return commits
end

---@param root string
---@return string?
---@return string?
function git.upstream(root)
    local out = git.run(
        { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil, NO_UPSTREAM_MESSAGE()
    end

    local upstream = return_result(out)

    if upstream == '' then
        return nil, NO_UPSTREAM_MESSAGE()
    end

    return upstream, nil
end

---@param root string
---@return GitCommit[]
function git.unpushed_commits(root)
    local upstream = git.upstream(root)
    local range = upstream ~= nil and upstream .. '..HEAD' or 'HEAD'
    local args = { 'log', '--format=%H%x1f%s', '-20', range }

    if upstream == nil then
        vim.list_extend(args, { '--not', '--remotes' })
    end

    local out = git.run(args, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 or out.output == '' then
        return {}
    end

    return parse_commits(out.output)
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

---Untracked files under `dir`, relative to `root`. Ignored files are left
---out. A nested repository is listed as its directory, with a trailing `/`.
---@param root string
---@param dir string
---@return string[]? files
---@return string? error
function git.untracked_files(root, dir)
    local out = git.run({
        'ls-files',
        '--others',
        '--exclude-standard',
        '-z',
        '--',
        ':(literal)' .. dir,
    }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    local files = {}

    for _, path in ipairs(vim.split(out.output, '\0', { plain = true })) do
        if path ~= '' then
            table.insert(files, path)
        end
    end

    return files
end

---@return table
local function root_opts()
    local root = git.root()
    local opts = { ignore_error = true }

    if root ~= '' then
        opts.cwd = root
    end

    return opts
end

---@param entry GitStatusEntry
---@return string[]
local function entry_pathspecs(entry)
    if entry.orig_path == nil then
        return { entry.path }
    end

    return { entry.orig_path, entry.path }
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

---@param patch string[]
---@param kind 'stage'|'unstage'|'discard'
---@return boolean
---@return string?
function git.apply_hunk(patch, kind)
    ensure_git()

    if #patch == 0 then
        return false, 'No hunk patch to apply'
    end

    if kind ~= 'stage' and kind ~= 'unstage' and kind ~= 'discard' then
        return false, 'Unknown hunk action: ' .. kind
    end

    local path = vim.fn.tempname() .. '.patch'
    vim.fn.writefile(patch, path)

    local args = { 'apply' }

    if kind == 'stage' then
        table.insert(args, '--cached')
    elseif kind == 'unstage' then
        table.insert(args, '--cached')
        table.insert(args, '--reverse')
    elseif kind == 'discard' then
        table.insert(args, '--reverse')
    end

    table.insert(args, path)

    local out = git.run(args, root_opts())
    vim.fn.delete(path)

    return out.exit_code == 0, return_result(out)
end

---@param diff string?
---@return string[]
local function parse_diff(diff)
    if diff == '' or diff == nil then
        return {}
    end

    return vim.split(diff, '\n', { plain = true })
end

---@return GitFileChangeCounts
local function empty_change_counts()
    return { added = 0, modified = 0, deleted = 0 }
end

---@param counts GitFileChangeCounts
---@param removed integer
---@param added integer
local function add_diff_block_counts(counts, removed, added)
    local modified = math.min(removed, added)

    counts.modified = counts.modified + modified
    counts.deleted = counts.deleted + removed - modified
    counts.added = counts.added + added - modified
end

---@param diff string
---@return GitFileChangeCounts
local function parse_change_counts(diff)
    local counts = empty_change_counts()
    local removed = 0
    local added = 0

    local function flush_block()
        if removed > 0 or added > 0 then
            add_diff_block_counts(counts, removed, added)
            removed = 0
            added = 0
        end
    end

    for _, line in ipairs(parse_diff(diff)) do
        local prefix = line:sub(1, 1)

        if line:sub(1, 3) == '+++' or line:sub(1, 3) == '---' then
            flush_block()
        elseif prefix == '-' then
            removed = removed + 1
        elseif prefix == '+' then
            added = added + 1
        else
            flush_block()
        end
    end

    flush_block()

    return counts
end

---@param path string
---@param root string
---@return string?
local function normalize_path(path, root)
    if path == '' then
        return nil
    end

    local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
    local normalized_root = vim.fs.normalize(root)

    if absolute == normalized_root then
        return '.'
    end

    local relative = vim.fs.relpath(normalized_root, absolute)

    if
        relative ~= nil
        and relative ~= '..'
        and relative:sub(1, 3) ~= '../'
        and relative:sub(1, 3) ~= '..\\'
    then
        return relative
    end

    return path
end

---@param path string
---@return boolean
local function is_absolute_path(path)
    return path:sub(1, 1) == '/'
        or path:sub(1, 1) == '\\'
        or path:match('^%a:[/\\]') ~= nil
end

---@param path string
---@param root string
---@return table?
local function fs_stat_path(path, root)
    local full_path = path

    if not is_absolute_path(path) then
        full_path = vim.fs.joinpath(root, path)
    end

    return vim.uv.fs_stat(vim.fs.normalize(full_path))
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

---@param commit GitCommit
---@return string[]
---@return string?
function git.show_commit(commit)
    ensure_git()

    local out =
        git.run({ 'show', '--stat', '--patch', commit.hash }, root_opts())

    if out.exit_code ~= 0 then
        return {}, return_result(out)
    end

    return parse_diff(out.output), nil
end

---@param path string?
---@return GitFileChangeCounts
---@return string?
function git.file_change_counts(path)
    if not ensure_git() then
        return empty_change_counts(), '`git` is not executable'
    end

    path = path or vim.api.nvim_buf_get_name(0)

    local root = git.root()

    if root == '' then
        return empty_change_counts(), 'Not inside a git repository'
    end

    local relative_path = normalize_path(path, root)

    if relative_path == nil then
        return empty_change_counts(), 'No file path provided'
    end

    local stat = fs_stat_path(relative_path, root)

    if stat ~= nil and stat.type == 'directory' then
        return empty_change_counts(),
            'File change counts are not available for directories'
    end

    local status_out = git.run(
        { 'status', '--porcelain=v1', '-z', '--', relative_path },
        { cwd = root, ignore_error = true }
    )

    if status_out.exit_code ~= 0 then
        return empty_change_counts(), return_result(status_out)
    end

    local status_entries = parse_status(status_out.output)

    if #status_entries > 1 then
        return empty_change_counts(), 'Expected a file path, got multiple files'
    end

    if #status_entries == 1 and status_entries[1].unstaged == '?' then
        local lines, err = read_worktree_lines(relative_path, root)

        if err ~= nil then
            return empty_change_counts(), err
        end

        return { added = #lines, modified = 0, deleted = 0 }, nil
    end

    local out = git.run(
        { 'diff', '--no-ext-diff', '--unified=0', '--', relative_path },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code > 1 or (out.exit_code ~= 0 and out.output == '') then
        return empty_change_counts(), return_result(out)
    end

    return parse_change_counts(out.output), nil
end

---@return GitFileChangeCounts
---@return string?
function git.current_file_change_counts()
    return git.file_change_counts(vim.api.nvim_buf_get_name(0))
end

---@param entry GitStatusEntry
---@param section string?
---@return string[]
---@return string?
function git.diff(entry, section)
    ensure_git()

    local args
    local opts = root_opts()
    local pathspecs = entry_pathspecs(entry)
    local full_path = opts.cwd ~= nil and vim.fs.joinpath(opts.cwd, entry.path)
        or entry.path
    local stat = vim.uv.fs_stat(full_path)

    if section == 'untracked' or entry.unstaged == '?' then
        if stat ~= nil and stat.type == 'directory' then
            return {}, 'Diff preview is not available for untracked directories'
        end

        args = { 'diff', '--no-index', '--', '/dev/null', entry.path }
    elseif section == 'staged' then
        args = { 'diff', '--cached', '--' }
        vim.list_extend(args, pathspecs)
    elseif section == 'unstaged' or section == 'conflicts' then
        args = { 'diff', '--' }
        vim.list_extend(args, pathspecs)
    elseif entry.staged ~= ' ' or entry.unstaged ~= ' ' then
        args = { 'diff', 'HEAD', '--' }
        vim.list_extend(args, pathspecs)
    else
        return {}
    end

    opts.ignore_error = true

    local out = git.run(args, opts)

    if out.exit_code > 1 or (out.exit_code ~= 0 and out.output == '') then
        return {}, return_result(out)
    end

    return parse_diff(out.output)
end

---@class IterFileSource
---@field raw string[] git diff text
---@field old_lines? string[] nil for binary files
---@field new_lines? string[] nil for binary files
---@field binary boolean

-- Flags that keep the diff text parseable whatever the user's git config.
local DIFF_FLAGS = { '--no-color', '--no-ext-diff' }

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

--- Diff text and both full versions of one file. Unstaged compares the index
--- with the worktree, staged compares HEAD with the index. Untracked and
--- added files have an empty old side, deleted files an empty new side.
---@param root string
---@param change { path: string, orig_path?: string, side: IterSide, code: string }
---@return IterFileSource?
---@return string? error
function git.file_diff(root, change)
    ensure_git()

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

    local out = git.run(args, { cwd = root, ignore_error = true })

    -- `--no-index` exits 1 when the files differ.
    if out.exit_code > 1 or (out.exit_code == 1 and not untracked) then
        return nil, return_result(out)
    end

    local raw = split_output(out.output)

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
