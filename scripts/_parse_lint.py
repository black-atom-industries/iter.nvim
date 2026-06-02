import json, sys

outfile = sys.argv[1]
project_dir = sys.argv[2]

with open(outfile) as f:
    data = json.load(f)

if not isinstance(data, dict):
    # Empty result — no diagnostics
    print('No diagnostics found.', file=sys.stderr)
    sys.exit(0)

severity_map = {1: 'error', 2: 'warning'}
total = 0

for file_path, diagnostics in data.items():
    short_path = file_path.removeprefix('file://' + project_dir + '/')
    for d in diagnostics:
        sev = d.get('severity', 2)
        if sev > 2:
            continue
        code = d['code']
        line_num = d.get('range', {}).get('start', {}).get('line', 0) + 1
        msg = d['message']
        label = severity_map.get(sev, 'warn')
        print(f'{label}: {short_path}:{line_num}: {msg} [{code}]')
        total += 1

if total == 0:
    print('No diagnostics found.', file=sys.stderr)
    sys.exit(0)
else:
    print(f'\n{total} problem(s)', file=sys.stderr)
    sys.exit(1)
