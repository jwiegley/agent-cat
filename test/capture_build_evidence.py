#!/usr/bin/env python3
"""Exercise only the exact capture owner body with explicitly inert compiler/checker fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import sys
import tempfile

from policy_refusal_evidence import run, save


FLAGS = '-Wall -Werror -O1 -threaded -rtsopts -optc-Wall -optc-Wextra -optc-Werror -iruntime/src -iruntime/test -iplan/src -idsl/src -icost/src -iengine/api/src'.split()
INPUTS = {
    'capture-tests': ['runtime/test/CaptureTests.hs', 'runtime/cbits/private_directory.c', 'runtime/cbits/private_sync.c', 'runtime/cbits/process_group.c', '-main-is', 'CaptureTests.captureTests'],
    'root-role-tests': ['runtime/test/RootRoleTests.hs', 'runtime/cbits/private_directory.c', 'runtime/cbits/private_sync.c', 'runtime/cbits/process_group.c', '-main-is', 'RootRoleTests.rootRoleTests'],
    'capture-fault-tests': ['runtime/test/CaptureFaultTests.hs', 'runtime/cbits/private_directory.c', 'runtime/test/capture_sync_fault.c'],
}
NAMES = list(INPUTS)
CHECKER = '''import hashlib,json,os,sys
from pathlib import Path
path=Path(sys.argv[0]).resolve()
name=path.name
assert sys.argv[1:] in [['+RTS','-N1','-RTS'],['+RTS','-N8','-RTS']]
assert os.environ['TMPDIR']==str(path.parent/'tmp') and 'GHCRTS' not in os.environ
failure=os.environ['FAIL_CHECKER']==name+':'+sys.argv[2]
with open(os.environ['EVENTS'],'a') as f:
 f.write(json.dumps({'kind':'checker','name':name,'argv':sys.argv[1:],'TMPDIR':os.environ['TMPDIR'],'GHCRTSPresent':False,'environmentNames':sorted(os.environ),'environmentSha256':hashlib.sha256(json.dumps(dict(os.environ),sort_keys=True).encode()).hexdigest()})+'\\n')
if failure:
 os.write(2,('INERT_CHECKER_FAILURE '+name+' '+sys.argv[2]+'\\n').encode())
 raise SystemExit(9)
'''


def checker_bytes(token):
    return ('#!' + sys.executable + '\n# INERT fixture token: ' + token + '\n' + CHECKER).encode()


def snapshot(work):
    result = {}
    for path in [work, *sorted(work.rglob('*'))]:
        st = path.lstat()
        assert not path.is_symlink()
        result[str(path.relative_to(work))] = {
            'mode': stat.S_IMODE(st.st_mode), 'inode': st.st_ino, 'mtimeNs': st.st_mtime_ns, 'ctimeNs': st.st_ctime_ns,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None,
        }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, help='new private evidence directory')
    parser.add_argument('--baseline', type=Path, help='old owner, expected deletion red only')
    args = parser.parse_args()
    source = args.baseline or Path(__file__).resolve().parents[1] / 'runtime/ci/capture.sh'
    text = source.read_text()
    first = 'work=$(mktemp -d "$CABAL_BUILDDIR/capture.XXXXXX")\n'
    assert text.count(first) == 1
    start = text.index(first)
    body = text[start:]
    assert body.endswith("PY\n") and 'set -euo pipefail\n' in text[:start]
    assert 'subprocess.run([str(Path(sys.argv[1]) / name), "+RTS", capabilities, "-RTS"], check=True, timeout=60)' in body
    if args.work:
        args.work.mkdir(mode=0o700)
        root = args.work.resolve()
    else:
        root = Path(tempfile.mkdtemp(prefix='capture-build-data-', dir=os.environ['CABAL_BUILDDIR'])).resolve()
    (root / 'extracted-owner.sh').write_text(body)
    save(root / 'source-binding.json', {'source': str(source.resolve()), 'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                                      'ownerSha256': hashlib.sha256(body.encode()).hexdigest(), 'startLine': text[:start].count('\n') + 1,
                                      'realPythonRunnerUnchanged': True, 'timeoutSeconds': 60, 'realCompilerOrNativeChecker': False})
    bash, mktemp = shutil.which('bash'), shutil.which('mktemp')
    assert bash and mktemp
    results = []
    earlier = []

    def case(name, repeat=False, fail_build=False, fail_checker=False, allocation_failure=False):
        sandbox = root / ('repeated' if repeat else name)
        if not sandbox.exists():
            sandbox.mkdir(mode=0o700)
            (sandbox / 'bin').mkdir()
            if not allocation_failure:
                (sandbox / 'build').mkdir(mode=0o700)
            allocator = sandbox / 'bin/mktemp'
            allocator.write_text('#!' + bash + '\nset -e\nallocated=$(' + shlex.quote(mktemp) + ' "$@")\nprintf "%s\\n" "$allocated" > "$ALLOCATION_RECORD"\nprintf "%s\\n" "$allocated"\n')
            allocator.chmod(0o700)
            fake = sandbox / 'bin/ghc'
            fake.write_text('#!' + sys.executable + '\n' + '''import hashlib,json,os,sys
from pathlib import Path
args=sys.argv[1:]
output=Path(args[-1])
name=output.name
work=output.parent
assert work.parent==Path(os.environ['CABAL_BUILDDIR']) and work.name.startswith('capture.')
assert os.environ['TMPDIR']==str(work/'tmp') and 'GHCRTS' not in os.environ
assert all((work/p).is_dir() for p in ['normal','fault','tmp'])
config=json.loads(Path(os.environ['FIXTURE_CONFIG']).read_text())
folder='fault' if name=='capture-fault-tests' else 'normal'
expected=['--make']+config['flags']+['-outputdir',str(work/folder)]+config['inputs'][name]+['-o',str(output)]
assert args==expected,(args,expected)
with open(os.environ['EVENTS'],'a') as f:
 f.write(json.dumps({'kind':'ghc','name':name,'argv':args,'TMPDIR':os.environ['TMPDIR'],'GHCRTSPresent':False,'environmentNames':sorted(os.environ),'environmentSha256':hashlib.sha256(json.dumps(dict(os.environ),sort_keys=True).encode()).hexdigest()})+'\\n')
token=os.environ['CASE_TOKEN']
if os.environ['FAIL_BUILD']==name:
 (work/folder/(name+'.partial')).write_bytes(('INERT PARTIAL '+token+' '+name+'\\n').encode())
 os.write(2,('INERT_GHC_FAILURE '+name+'\\n').encode())
 raise SystemExit(7)
(work/folder/(name+'.o')).write_bytes(('INERT OBJECT '+token+' '+name+'\\n').encode()+bytes([0,255]))
output.write_bytes(Path(os.environ['CHECKER_BYTES']).read_bytes())
output.chmod(0o700)
''')
            fake.chmod(0o700)
        fake = sandbox / 'bin/ghc'
        config = sandbox / (name + '.fixture.json')
        save(config, {'flags': FLAGS, 'inputs': INPUTS})
        template = sandbox / (name + '.checker-template')
        template.write_bytes(checker_bytes(name))
        events_path = sandbox / (name + '.events.jsonl')
        allocation_path = sandbox / (name + '.allocation')
        env = dict(os.environ, CABAL_BUILDDIR=str(sandbox / 'build'), PATH=str(sandbox / 'bin') + os.pathsep + os.environ['PATH'],
                   ALLOCATION_RECORD=str(allocation_path), FIXTURE_CONFIG=str(config), CHECKER_BYTES=str(template), EVENTS=str(events_path),
                   CASE_TOKEN=name, FAIL_BUILD='root-role-tests' if fail_build else '', FAIL_CHECKER='root-role-tests:-N8' if fail_checker else '',
                   GHCRTS='PUBLIC_INERT_UNSET_CHECK', PYTHONDONTWRITEBYTECODE='1')
        assert shutil.which('ghc', path=env['PATH']) == str(fake)
        fake_hash = hashlib.sha256(fake.read_bytes()).hexdigest()
        driver = sandbox / (name + '.sh')
        driver.write_text('set -euo pipefail\n[ "$(command -v ghc)" = ' + shlex.quote(str(fake)) + ' ]\n'
                          + '[ "$GHCRTS" = PUBLIC_INERT_UNSET_CHECK ]\n' + body)
        code, output, errors = run([bash, str(driver)], sandbox, env, sandbox / name)
        assert hashlib.sha256(fake.read_bytes()).hexdigest() == fake_hash
        events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
        work = Path(allocation_path.read_text().strip()) if allocation_path.exists() else None
        if allocation_failure:
            assert code == 1 and work is None and not events and output == b''
            assert b'no such file or directory' in errors.lower()
        else:
            builds = [event for event in events if event['kind'] == 'ghc']
            checks = [event for event in events if event['kind'] == 'checker']
            assert [event['name'] for event in builds] == (NAMES[:2] if fail_build else NAMES)
            expected_checks = [(n, cap) for n in NAMES for cap in ['-N1', '-N8']]
            if fail_build:
                expected_checks = []
            elif fail_checker:
                expected_checks = expected_checks[:4]
            assert [(event['name'], event['argv'][1]) for event in checks] == expected_checks
            assert [event['kind'] for event in events] == ['ghc'] * len(builds) + ['checker'] * len(checks)
            for event in events:
                assert event['TMPDIR'] == str(work / 'tmp') and event['GHCRTSPresent'] is False
            if args.baseline:
                assert code == 0 and errors == b'' and len(checks) == 6
                save(sandbox / 'old-owner-passed.json', {'shellExit': code, 'work': str(work), 'builds': 3, 'checks': 6, 'deletedByOriginalTrap': not work.exists()})
                assert work.is_dir(), 'OLD RED: capture EXIT trap deleted successfully consumed inert build artifacts'
            assert work.stat().st_mode & 0o777 == 0o700
            successful_names = NAMES[:1] if fail_build else NAMES
            expected_files = set()
            for exe in successful_names:
                folder = 'fault' if exe == 'capture-fault-tests' else 'normal'
                assert (work / exe).read_bytes() == checker_bytes(name)
                assert stat.S_IMODE((work / exe).stat().st_mode) == 0o700
                obj = work / folder / (exe + '.o')
                assert obj.read_bytes() == ('INERT OBJECT ' + name + ' ' + exe + '\n').encode() + bytes([0, 255])
                expected_files.update([exe, folder + '/' + exe + '.o'])
            if fail_build:
                assert code == 7 and output == b'' and errors == b'INERT_GHC_FAILURE root-role-tests\n'
                partial = work / 'normal/root-role-tests.partial'
                assert partial.read_bytes() == ('INERT PARTIAL ' + name + ' root-role-tests\n').encode()
                expected_files.add('normal/root-role-tests.partial')
            elif fail_checker:
                assert code == 1 and b'INERT_CHECKER_FAILURE root-role-tests -N8\n' in errors
                argv = [str(work / 'root-role-tests'), '+RTS', '-N8', '-RTS']
                assert b'subprocess.CalledProcessError' in errors and repr(argv).encode() in errors and b'returned non-zero exit status 9' in errors
            else:
                assert code == 0 and errors == b''
                assert output == b''.join(f'{n} {cap}\n'.encode() for n, cap in expected_checks)
            assert {str(p.relative_to(work)) for p in work.rglob('*') if p.is_file()} == expected_files
            if repeat:
                for previous, identity in earlier:
                    assert previous != work and snapshot(previous) == identity
                    assert (previous / 'capture-tests').read_bytes() != (work / 'capture-tests').read_bytes()
                earlier.append((work, snapshot(work)))
        results.append({'name': name, 'shellExit': code, 'work': str(work) if work else None, 'events': events,
                        'selectedGhc': str(fake), 'selectedGhcSha256': fake_hash, 'passed': True})

    if args.baseline:
        case('old-red')
        raise AssertionError('old trap unexpectedly retained compiler artifacts')
    case('normal-first', repeat=True)
    case('normal-second', repeat=True)
    case('build-failure', fail_build=True)
    case('checker-failure', fail_checker=True)
    case('allocation-failure', allocation_failure=True)
    save(root / 'results.json', {'cases': results, 'passed': True, 'realGhcExecuted': False, 'nativeCheckersExecuted': False,
                                'pythonTimeoutRunnerUnchanged': True, 'timeoutSeconds': 60})
    print(f'PASS capture-build evidence: {len(results)} inert owner cases; retained at {root}')


if __name__ == '__main__':
    main()
