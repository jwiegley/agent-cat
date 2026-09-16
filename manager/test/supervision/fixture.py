"""Disposable local fixtures. The owning child alone joins its original descendant."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,sys,time
mode=sys.argv[1]
work=Path(sys.argv[2])
role='descendant' if mode=='descendant' else 'child'
sigints=0
def interrupted(_signal,_frame):
    global sigints
    sigints+=1
signal.signal(signal.SIGINT,interrupted)
def event(name,**values):
    with (work/(role+'.events.jsonl')).open('a') as out:
        out.write(json.dumps(dict(event=name,wall=datetime.datetime.now(datetime.timezone.utc).isoformat(),monotonic_ns=time.monotonic_ns(),**values))+'\n')
def mark(name):
    (work/name).touch(exist_ok=True)
def await_marker(name,owner=None):
    while not (work/name).exists() and not (work/'abort.release').exists():
        if owner is not None and owner.poll() is not None:
            raise RuntimeError('original descendant exited before readiness')
        time.sleep(0.001)
original=None
primary=None
cleanup=None
joined=None
try:
    event('started',argv=sys.argv,cwd=str(Path.cwd()))
    if mode=='descendant':
        event('ready')
        mark('descendant.ready')
        await_marker('descendant.release')
        if sigints:raise RuntimeError('unexpected descendant SIGINT')
        event('released')
    elif mode=='success':
        event('ready')
        mark('child.ready')
        await_marker('success.release')
        if sigints:raise RuntimeError('success child received cleanup signal')
        event('normal-success')
    elif mode=='held':
        command=[sys.executable,'-u',str(Path(__file__).resolve()),'descendant',str(work)]
        environment={key:os.environ[key] for key in ['PATH','LANG','LC_ALL','LC_CTYPE','HOME','TMPDIR','XDG_CONFIG_HOME','XDG_CACHE_HOME','PYTHONDONTWRITEBYTECODE'] if key in os.environ}
        original=subprocess.Popen(command,cwd=work,env=environment,stdin=subprocess.DEVNULL)
        event('descendant-created',command=command,environmentNames=sorted(environment),environmentSha256=hashlib.sha256(json.dumps(environment,sort_keys=True).encode()).hexdigest(),handleIdentity=hex(id(original)),actualPopen=type(original) is subprocess.Popen)
        await_marker('descendant.ready',original)
        if original.poll() is not None:raise RuntimeError('descendant ended before child readiness')
        event('ready')
        mark('child.ready')
        while not sigints and not (work/'abort.release').exists():time.sleep(0.001)
        if not (work/'abort.release').exists() and sigints!=1:raise RuntimeError('expected exactly one original-child SIGINT')
        if original.poll() is not None:raise RuntimeError('descendant ended before held cleanup')
        event('cleanup-entry',sigintCount=sigints,descendantStillOwned=True)
        mark('child.cleanup-held')
        await_marker('cleanup.release')
        event('cleanup-released',aborted=(work/'abort.release').exists())
    else:raise RuntimeError('unknown disposable mode')
except BaseException as failure:
    primary=failure
finally:
    if original is not None:
        try:
            try:
                mark('descendant.release')
                event('original-descendant-join-entry',handleIdentity=hex(id(original)))
            finally:
                joined=original.wait()
            event('original-descendant-joined',handleIdentity=hex(id(original)),returncode=joined,reaped=original.returncode is not None)
            if joined!=0:raise RuntimeError('original descendant did not exit zero')
        except BaseException as failure:
            cleanup=failure
    report=dict(role=role,mode=mode,sigintCount=sigints,aborted=(work/'abort.release').exists(),primaryType=type(primary).__name__ if primary else None,cleanupType=type(cleanup).__name__ if cleanup else None,descendantJoinedReturncode=joined,descendantHandleIdentity=hex(id(original)) if original else None,descendantReaped=original.returncode is not None if original else None)
    with (work/(role+'.report.json')).open('x') as out:json.dump(report,out,indent=2);out.write('\n')
    event('finished',primaryType=report['primaryType'],cleanupType=report['cleanupType'])
    mark(role+'.done')
if primary is not None:raise primary
if cleanup is not None:raise cleanup
