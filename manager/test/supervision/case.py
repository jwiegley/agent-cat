"""One live regression case, observing real handles without replacing wait outcomes."""
from pathlib import Path
import ast,datetime,hashlib,json,os,signal,subprocess,sys,threading,time,types
scripts=Path(__file__).resolve().parent
mode=sys.argv[1]
work=Path(sys.argv[2]).resolve()
root=work.parent.parent
assert mode in {'success','timeout','interruption'} and work==root/'cases'/mode
private={'HOME':str(root/'home'),'TMPDIR':str(root/'tmp'),'XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'home/cache'),'PYTHONDONTWRITEBYTECODE':'1'}
environment={key:os.environ[key] for key in ['PATH','LANG','LC_ALL','LC_CTYPE'] if key in os.environ}
environment.update(private)
with (work/'case-started.json').open('x') as out:json.dump({'case':mode,'argv':sys.argv,'start':datetime.datetime.now(datetime.timezone.utc).isoformat()},out)
inputs=json.loads((root/'input.json').read_text())
helper=Path(inputs['helper'])
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
assert digest(helper)==inputs['helperSha256']
text=helper.read_text();tree=ast.parse(text)
nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='run']
assert len(nodes)==1 and nodes[0].args.defaults[0].value==1200
signal.signal(signal.SIGINT,signal.default_int_handler)
assert signal.SIGINT not in signal.pthread_sigmask(signal.SIG_BLOCK,[])
main_thread=threading.main_thread()
created=threading.Event();ready=threading.Event();finished=threading.Event()
originals=[];coordination_failures=[];observed_exceptions=[];wait_calls=[]
lock=threading.Lock()
def event(name,**values):
    with lock:
        with (work/'supervisor.events.jsonl').open('a') as out:
            out.write(json.dumps(dict(event=name,wall=datetime.datetime.now(datetime.timezone.utc).isoformat(),monotonic_ns=time.monotonic_ns(),**values))+'\n')
def release(abort=False):
    if abort:(work/'abort.release').touch(exist_ok=True)
    (work/('success.release' if mode=='success' else 'cleanup.release')).touch(exist_ok=True)
def await_condition(predicate,label):
    while not predicate():
        if finished.is_set():raise AssertionError('supervisor completed before '+label)
        time.sleep(0.001)
    event(label)
real_popen=subprocess.Popen
real_wait_code=subprocess.Popen.wait.__code__
def create_original(command,**kwargs):
    process=real_popen(command,**kwargs)
    originals.append(process)
    assert type(process) is real_popen
    event('original-child-created',command=command,cwd=str(kwargs['cwd']),privateOverrides=private,environmentNames=sorted(kwargs['env']),environmentSha256=hashlib.sha256(json.dumps(kwargs['env'],sort_keys=True).encode()).hexdigest(),handleIdentity=hex(id(process)))
    created.set()
    while not (work/'child.ready').exists():
        if process.poll() is not None:raise AssertionError('child exited before readiness')
        time.sleep(0.001)
    event('readiness-observed-before-constructor-hook-return',handleIdentity=hex(id(process)))
    ready.set()
    return process
namespace={'work':work,'copy':work,'environment':environment,'results':[], 'json':json,'signal':signal,'time':time,
           'subprocess':types.SimpleNamespace(Popen=create_original,STDOUT=subprocess.STDOUT,TimeoutExpired=subprocess.TimeoutExpired)}
exec(compile(ast.Module(body=nodes,type_ignores=[]),str(helper),'exec'),namespace)
actual_run=namespace['run'];run_code=actual_run.__code__
def in_original_wait(timed):
    if not originals:return False
    frame=sys._current_frames().get(main_thread.ident)
    # Require execution inside stdlib wait body, not inside the observational trace callback.
    if frame is None or frame.f_code.co_filename!=real_wait_code.co_filename:return False
    found_wait=False;found_run=False
    while frame is not None:
        if frame.f_code is real_wait_code and frame.f_locals.get('self') is originals[0]:
            found_wait=(frame.f_locals.get('timeout') is not None)==timed
        if frame.f_code is run_code and frame.f_locals.get('process') is originals[0]:found_run=True
        frame=frame.f_back
    return found_wait and found_run
def observe(frame,kind,value):
    if frame.f_code is real_wait_code and kind=='call' and originals and frame.f_locals.get('self') is originals[0]:
        wait_calls.append({'timeout':frame.f_locals.get('timeout'),'handleIdentity':hex(id(originals[0])),'monotonic_ns':time.monotonic_ns()})
    if frame.f_code is run_code:
        if kind=='exception' and isinstance(value[1],(subprocess.TimeoutExpired,KeyboardInterrupt)):
            exception=value[1]
            if not any(item['exception'] is exception for item in observed_exceptions):
                observed_exceptions.append({'exception':exception,'type':type(exception).__name__,'identity':hex(id(exception)),'line':frame.f_lineno,'monotonic_ns':time.monotonic_ns()})
        return observe
    return None
def held_assertion(label):
    assert not finished.is_set(), 'helper returned during held cleanup'
    assert originals[0].returncode is None, 'original child ended during held cleanup'
    assert not (work/'child.done').exists() and not (work/'descendant.done').exists()
    assert not (work/'cleanup.release').exists() and not (work/'descendant.release').exists()
    event(label,helperPending=True,originalChildPending=True,descendantReleaseWithheld=True)
def coordinate():
    try:
        await_condition(created.is_set,'original-handle-retained')
        await_condition(ready.is_set,'ready-rendezvous')
        if mode=='success':
            await_condition(lambda:in_original_wait(True),'actual-initial-wait-observed')
            assert not finished.is_set() and originals[0].returncode is None
            event('success-release')
            release()
            return
        if mode=='interruption':
            await_condition(lambda:in_original_wait(True),'actual-initial-wait-observed')
            event('first-caller-SIGINT-requested',target='live supervising main thread')
            signal.pthread_kill(main_thread.ident,signal.SIGINT)
        await_condition(lambda:(work/'child.cleanup-held').exists(),'real-child-SIGINT-cleanup-held')
        await_condition(lambda:in_original_wait(False),'actual-original-cleanup-wait-observed')
        held_assertion('cannot-complete-before-cleanup-release')
        if mode=='interruption':
            assert observed_exceptions and isinstance(observed_exceptions[0]['exception'],KeyboardInterrupt)
            event('additional-caller-SIGINT-requested',target='same live supervising main thread')
            signal.pthread_kill(main_thread.ident,signal.SIGINT)
            await_condition(lambda:namespace['results'] and namespace['results'][0]['joinInterruptions']==1 and in_original_wait(False),'additional-interruption-deferred-and-original-wait-reentered')
            held_assertion('still-pending-after-additional-interruption')
        event('explicit-cleanup-release')
        release()
    except BaseException as failure:
        coordination_failures.append(failure)
        event('coordination-failure',type=type(failure).__name__,message=str(failure))
    finally:
        release(abort=bool(coordination_failures))
coordinator=threading.Thread(target=coordinate,name='live-case-coordinator')
command=[sys.executable,'-u',str(scripts/'fixture.py'),'success' if mode=='success' else 'held',str(work)]
budget=1.0 if mode=='timeout' else 1200
before_trace=sys.gettrace();returned=None;primary=None;cleanup_failures=[];outer_joins=[]
start=time.monotonic_ns()
event('helper-call',command=command,timeout=budget,helperSha256=digest(helper),processCreationTimingUnderTest=False)
coordinator.start()
try:
    sys.settrace(observe)
    try:returned=actual_run(command,'child.log',timeout=budget)
    except BaseException as failure:primary=failure
finally:
    sys.settrace(before_trace)
    finished.set()
    release_path=work/('success.release' if mode=='success' else 'cleanup.release')
    release(abort=not release_path.exists() or bool(coordination_failures))
    status=namespace['results'][-1] if namespace['results'] else {}
    for process in originals:
        if status.get('waitFailure') is not None:
            cleanup_failures.append(RuntimeError('original wait ownership UNPROVEN; no further wait or signal'))
            continue
        try:
            result=process.wait()
            outer_joins.append({'handleIdentity':hex(id(process)),'returncode':result,'reaped':process.returncode is not None})
        except BaseException as failure:cleanup_failures.append(failure)
    coordinator.join()
end=time.monotonic_ns()
failure=None
try:
    assert len(originals)==1 and type(originals[0]) is subprocess.Popen
    assert not coordination_failures and not cleanup_failures
    status=json.loads((work/'results.json').read_text())
    assert len(status)==1
    status=status[0]
    assert status['ownership']=='original-child-joined' and status['returncode']==0
    assert status['signalFailure'] is None and status['waitFailure'] is None
    assert outer_joins==[{'handleIdentity':hex(id(originals[0])),'returncode':0,'reaped':True}]
    child=json.loads((work/'child.report.json').read_text())
    assert child['primaryType'] is None and child['cleanupType'] is None and not child['aborted']
    if mode=='success':
        assert returned==0 and primary is None and status['primaryFailure'] is None
        assert child['sigintCount']==0 and not (work/'child.cleanup-held').exists()
        assert child['descendantHandleIdentity'] is None and status['joinInterruptions']==0
    else:
        expected=subprocess.TimeoutExpired if mode=='timeout' else KeyboardInterrupt
        assert isinstance(primary,expected) and observed_exceptions and primary is observed_exceptions[0]['exception']
        assert status['primaryFailure']==expected.__name__ and returned is None
        assert child['sigintCount']==1 and child['descendantJoinedReturncode']==0 and child['descendantReaped'] is True
        descendant=json.loads((work/'descendant.report.json').read_text())
        assert descendant['primaryType'] is None and descendant['cleanupType'] is None and descendant['sigintCount']==0 and not descendant['aborted']
        assert any(item['timeout'] is None for item in wait_calls)
        if mode=='interruption':
            assert status['joinInterruptions']==1 and len(observed_exceptions)==2 and primary is not observed_exceptions[1]['exception']
        else:assert status['joinInterruptions']==0
    assert digest(helper)==inputs['helperSha256']
except BaseException as error:failure=error
report={'case':mode,'passed':failure is None,'returned':returned,'primaryType':type(primary).__name__ if primary else None,'primaryIdentity':hex(id(primary)) if primary else None,'firstExceptionPreserved':bool(primary is not None and observed_exceptions and primary is observed_exceptions[0]['exception']),'observedExceptions':[{k:v for k,v in item.items() if k!='exception'} for item in observed_exceptions],'actualWaitCalls':wait_calls,'outerOriginalHandleJoins':outer_joins,'coordinationFailures':[{'type':type(e).__name__,'message':str(e)} for e in coordination_failures],'cleanupFailures':[{'type':type(e).__name__,'message':str(e)} for e in cleanup_failures],'assertionFailure':{'type':type(failure).__name__,'message':str(failure)} if failure else None,'durationSeconds':(end-start)/1e9,'helperSha256After':digest(helper),'testTimeoutArgument':budget,'processCreationTimingUnderTest':False}
with (work/'case-report.json').open('x') as out:json.dump(report,out,indent=2);out.write('\n')
event('case-finished',passed=report['passed'],primaryType=report['primaryType'],durationSeconds=report['durationSeconds'])
print(('PASS ' if report['passed'] else 'FAIL ')+mode,flush=True)
if failure is not None:raise failure
