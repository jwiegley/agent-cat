set -euo pipefail
source /Users/johnw/Products/k.M0a5ItPm/environment.sh
cd /Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/broker-source
git diff --check
make -C doc check
python3 -B - <<'PY'
from pathlib import Path, PurePosixPath
import re, subprocess, tarfile

root = Path.cwd()
bundle = root / 'doc/checkpoints/wm023-20260923'
authority = Path('/Users/johnw/src/agent-cat/doc/PLAN.org')

def records(path):
    result = {}
    for block in re.split(r'(?m)(?=^\* )', path.read_text()):
        found = re.search(r'(?m)^:ID:\s+(\S+)', block)
        if found:
            ident = found.group(1)
            assert ident not in result, ident
            result[ident] = re.sub(r'^,(?=\*|#\+)', '', block, flags=re.M)
    return result

expected, actual = records(authority), records(root / 'doc/PLAN.org')
assert set(actual) <= set(expected)
assert set(expected) - set(actual) == {'acat-lijk', 'acat-3ajx', 'acat-3sq1', 'acat-jg00'}
assert len(actual) == 230
for ident, block in actual.items():
    assert block == expected[ident], ident
print('PASS 230 shared tracker records match. Four authority-only records remain intact.')

report = Path('/Users/johnw/dl/agent-cat-workflow-manager-remaining-2026-09-23.md').read_text()
for n in range(23, 45):
    assert f'WM{n:03}' in report, n
for n in range(2, 6):
    assert f'G{n}' in report, n
assert 'fess' in report and 'at the end of every subtask' in report
print('PASS all remaining package/gate identifiers and mandatory per-subtask fess appear in the report.')

for code in re.findall(r'```bash\n(.*?)\n```', (bundle / 'README.md').read_text(), re.S):
    subprocess.run(['bash', '-n'], input=code.encode(), check=True)
for link in ['../../research/workflow-manager-implementation-plan.md', '../../workflow-manager-handoff.md']:
    assert (bundle / link).resolve().is_file(), link
print('PASS portable resume shell fragments parse and primary local links exist. Fresh-clone execution is not claimed.')

entries = [(str(p.relative_to(bundle)), p.read_bytes()) for p in bundle.rglob('*') if p.is_file() and p.suffix != '.gz']
with tarfile.open(bundle / 'validation-history.tar.gz') as archive:
    members = archive.getmembers()
    assert len(members) == 343, len(members)
    for member in members:
        name = PurePosixPath(member.name)
        assert member.isfile() and not name.is_absolute() and '..' not in name.parts, member.name
        assert name.suffix in {'.command', '.log', '.start', '.end', '.exit', '.timeout'}, member.name
        entries.append((member.name, archive.extractfile(member).read()))
    for prefix in ['contract', 'service-commit', 'client-commit', 'tui-commit', 'archive-build']:
        matches = [data for name, data in entries if name.endswith('/' + prefix + '.exit')]
        assert matches == [b'0\n'], (prefix, matches)
        for suffix in ['.command', '.start', '.end', '.log']:
            assert any(name.endswith('/' + prefix + suffix) for name, _ in entries), (prefix, suffix)
patterns = [rb'-----BEGIN [A-Z ]*PRIVATE KEY-----', rb'SQLite format 3\x00', rb'(?i)Authorization:\s*Bearer\s+[A-Za-z0-9_./+-]{20,}']
for name, data in entries:
    for pattern in patterns:
        assert not re.search(pattern, data), (name, pattern)
print('PASS allowlisted archive structure, 343 records, commit-boundary outcome receipts, and private-key/database/literal-bearer scans. This is not a general secret-detection proof.')

changed = subprocess.check_output(['git', 'diff', '--name-only', 'd8c0609a7ea1b22dc70e863a288a1fa15fc46325'], text=True).splitlines()
assert all(name.startswith('doc/') for name in changed), changed
print('PASS tracked changes since tested application tip are documentation only.')
PY
