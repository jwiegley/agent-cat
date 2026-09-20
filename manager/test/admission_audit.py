#!/usr/bin/env python3
"""Exact project-owned source instrumentation and compiled audit mutants.

No production hook, database/syscall interposition or reconstructed worker authority.
All copies, compiler outputs, logs and failed fixtures remain below CABAL_BUILDDIR.
"""
from pathlib import Path, PurePosixPath
import difflib
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
if mode not in {"restore-interruption", "shutdown-races", "history-policy", "history-corrections", "history-observation", "interruption", "ticket-mutant", "retry-mutant", "deadline-mutant", "watchdog-mutant", "policy-mutant", "package-boundary", "termination-mutant", "approval-interruption", "approval-live-mutant", "approval-review-gap", "approval-publication-mutant", "approval-catalogue-mutant", "approval-reservation-mutant", "approval-quoted-mutant", "approval-supervision-mutant", "approval-live-target-mutant", "approval-delimiter-mutant", "ingestion-retained-mutant", "ingestion-duplicate-mutant", "store-cancel-gap", "store-cancel-mutant", "store-expiry-mutant", "ingestion-race", "ingestion-race-mutant", "ingestion-cleanup-mutant", "ingestion-observer-mutant", "control-reservation-mutant", "control-body-mutant", "control-release-mutant", "control-fifo-mutant", "control-unsupported", "control-unsupported-mutant", "control-steer-observation-mutant", "control-write", "control-interruption", "control-ticket-mutant", "control-reload-race", "control-preparation", "control-preparation-mutant"}:
    raise SystemExit("unknown audit mode")
work = Path(tempfile.mkdtemp(prefix=f"audit-{mode}.", dir=os.environ["CABAL_BUILDDIR"]))
copy = work / "agentic-0.1.0.0"
def capture_package(origin, destination, label):
    command = ["cabal", "--store-dir=" + os.environ["CABAL_BUILDDIR"] + "/cabal-store",
               "--active-repositories=:none", "sdist", "--ignore-project", "--list-only",
               "--null-sep", "--output-directory=-", "--builddir=" + str(work / (label + "-cabal"))]
    with (work / (label + ".log")).open("wb") as diagnostic:
        result = subprocess.run(command, cwd=origin, stdout=subprocess.PIPE, stderr=diagnostic, timeout=120)
    if result.returncode:
        raise RuntimeError("Cabal source enumeration failed")
    if len(result.stdout) > 1048576:
        raise RuntimeError("Cabal source enumeration exceeded audit bound")
    (work / (label + ".list")).write_bytes(result.stdout)
    members = {}
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        spelling = raw.decode("utf-8")
        name = PurePosixPath(spelling)
        if name.is_absolute() or ".." in name.parts or "\\" in spelling or not name.parts:
            raise RuntimeError("non-relative Cabal source member")
        relative = str(name)
        if relative in members:
            raise RuntimeError("duplicate Cabal source member")
        path = origin
        for component in name.parts:
            path = path / component
            if stat.S_ISLNK(path.lstat().st_mode):
                raise ValueError("declared source member is a symlink")
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError("declared source member is not regular")
        members[relative] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                             "mode": oct(path.stat().st_mode & 0o777)}
    if "agentic.cabal" not in members or "manager/test/Agentic/Manager/Test/AcceptanceAudit.hs" not in members:
        raise RuntimeError("required declared package source missing")
    destination.mkdir()
    for name in members:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(origin / name, target, follow_symlinks=False)
        if target.is_symlink() or not stat.S_ISREG(target.lstat().st_mode):
            raise RuntimeError("captured package member is not regular")
        if hashlib.sha256(target.read_bytes()).hexdigest() != members[name]["sha256"]:
            raise RuntimeError("source changed during package capture")
    (work / (label + "-hashes.json")).write_text(json.dumps(members, indent=2) + "\n")
    return members

original_members = capture_package(source, copy, "source")
if mode == "package-boundary":
    (copy / ".audit-cache").mkdir()
    (copy / ".audit-cache/unlisted").write_text("must not be copied")
    (copy / "unlisted-sentinel").write_text("must not be hashed")
    outside = work / "outside-sentinel"
    outside.write_text("unlisted symlink target")
    (copy / "unlisted-symlink").symlink_to(outside)
    captured = capture_package(copy, work / "recaptured", "recaptured")
    if captured != original_members:
        raise RuntimeError("unlisted content changed package capture")
    if any((work / "recaptured" / name).exists() for name in [".audit-cache", "unlisted-sentinel", "unlisted-symlink"]):
        raise RuntimeError("unlisted content crossed positive package boundary")
    declared = copy / "manager/test/Agentic/Manager/Test/AcceptanceAudit.hs"
    declared.rename(copy / "unlisted-helper-backup")
    declared.symlink_to(outside)
    try:
        capture_package(copy, work / "rejected", "declared-symlink")
    except ValueError as failure:
        if "symlink" not in str(failure):
            raise
    else:
        raise RuntimeError("declared source symlink was not rejected")
    (work / "package-boundary.json").write_text(json.dumps({"unlistedContentExcluded": True,
        "declaredHelpersRetained": True, "declaredSymlinkRejected": True, "memberCount": len(captured)}, indent=2) + "\n")
    print(f"PASS positive Cabal package boundary: {work}")
    raise SystemExit(0)

changes = []

def replace(path, old, new):
    target = copy / path
    before = target.read_text()
    if before.count(old) != 1:
        raise RuntimeError(f"expected exactly one {path} boundary anchor")
    after = before.replace(old, new, 1)
    target.write_text(after)
    changes.append({"path": path, "beforeSha256": hashlib.sha256(before.encode()).hexdigest(),
                    "afterSha256": hashlib.sha256(after.encode()).hexdigest(),
                    "diff": "".join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile=path, tofile=path))})

commands = "manager/src/Agentic/Manager/Commands.hs"
if mode in {"restore-interruption", "shutdown-races", "history-corrections", "history-observation", "interruption", "ticket-mutant", "approval-interruption", "approval-review-gap", "approval-publication-mutant", "approval-catalogue-mutant", "store-cancel-gap", "store-cancel-mutant", "store-expiry-mutant", "ingestion-race", "ingestion-race-mutant", "control-write", "control-interruption", "control-ticket-mutant", "control-reload-race", "control-preparation", "control-preparation-mutant"}:
    helper = copy / "manager/src/Agentic/Manager/Test/AcceptanceAudit.hs"
    helper.parent.mkdir(parents=True, exist_ok=True)
    helper.write_bytes((source / "manager/test/Agentic/Manager/Test/AcceptanceAudit.hs").read_bytes())
    changes.append({"path": "manager/src/Agentic/Manager/Test/AcceptanceAudit.hs", "beforeSha256": None,
                    "afterSha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
                    "source": "manager/test/Agentic/Manager/Test/AcceptanceAudit.hs",
                    "diff": "".join(difflib.unified_diff([], helper.read_text().splitlines(True), fromfile="/dev/null", tofile="manager/src/Agentic/Manager/Test/AcceptanceAudit.hs"))})
    replace("agentic.cabal", "    Agentic.Exec\n", "    Agentic.Manager.Test.AcceptanceAudit\n    Agentic.Exec\n")
if mode == "restore-interruption":
    store = "manager/src/Agentic/Manager/Store.hs"
    replace(store, "import Agentic.Manager.Lease (duplicateLease)\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Lease (duplicateLease)\n")
    replace(store, '      publishBytes root ["restore-in-progress"] (BL.toStrict(encode(revision,storeAuthorityEpoch identity,claims)))\n',
            '      publishBytes root ["restore-in-progress"] (BL.toStrict(encode(revision,storeAuthorityEpoch identity,claims)))\n      Audit.afterCurrentReview "restore-marker"\n')
    target, arguments = "manager-admission-check", ["restart-interruption"]
elif mode == "shutdown-races":
    replace(commands, "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace(commands, "CommandAttempt _ _ _ candidate retained generationAtCreation _ <-", "CommandAttempt _ _ _ candidate retained generationAtCreation auditAttemptPhase <-")
    replace(commands, "      Right (receipt, replayed, dispatch, refs, generation, epoch, association) -> do\n",
            "      Right (receipt, replayed, dispatch, refs, generation, epoch, association) -> do\n        unless replayed (Audit.afterFreshCommit candidate retained auditAttemptPhase)\n")
    admission = "manager/src/Agentic/Manager/Admission.hs"
    replace(admission, "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace(admission, "    current<-currentReview controller entry\n", "    current<-currentReview controller entry\n    Audit.afterCurrentReview \"acceptance\"\n")
    replace(admission, "        when(selected==CancelNow)(writeTVar(cancelled controller)True)\n",
            "        when(selected==CancelNow)(writeTVar(cancelled controller)True)\n  Audit.afterCurrentReview \"shutdown-request\"\n")
    target, arguments = "manager-approval-check", ["shutdown-races"]
elif mode == "history-policy":
    target, arguments = "manager-approval-check", ["history-policy"]
elif mode == "history-corrections":
    path = "manager/src/Agentic/Manager/Admission.hs"
    replace(path, "import Agentic.Manager.Authorization\n", "import Agentic.Manager.Authorization\nimport qualified Agentic.Manager.Test.AcceptanceAudit as Audit\n")
    replace(path, "    assembled <- assembleAcceptedDraft (store controller) (entryPermit entry) >>= need\n", "    assembled <- assembleAcceptedDraft (store controller) (entryPermit entry) >>= need\n    Audit.afterCurrentReview \"lineage-assembly\"\n")
    target, arguments = "manager-approval-check", ["history-corrections"]
elif mode == "history-observation":
    path = "manager/src/Agentic/Manager/Artifacts.hs"
    replace(path, "import Agentic.Manager.Store\n", "import Agentic.Manager.Store\nimport qualified Agentic.Manager.Test.AcceptanceAudit as Audit\n")
    replace(path, "        bytes <- captureObservedResult root nativeId ref\n", "        bytes <- captureObservedResult root nativeId ref\n        Audit.afterCurrentReview \"history-artifact-captured\"\n")
    target, arguments = "manager-history-check", ["corrections"]
elif mode in {"control-preparation", "control-preparation-mutant"}:
    replace("manager/src/Agentic/Manager/State.hs", "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace("manager/src/Agentic/Manager/State.hs", "          policy <- either (const(throwIO Command.StorageUnavailable)) pure selected\n",
            '          policy <- either (const(throwIO Command.StorageUnavailable)) pure selected\n          Audit.afterCurrentReview ("control-preparation:"<>associationRun association)\n')
    replace("manager/src/Agentic/Manager/Admission.hs", "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace("manager/src/Agentic/Manager/Admission.hs", 'proof request version prepare = operation controller $\n  withMVar',
            'proof request version prepare = operation controller $ do\n  Audit.recordControlWait ("control-preparation:"<>run)\n  withMVar')
    if mode == "control-preparation-mutant":
        replace("manager/src/Agentic/Manager/Admission.hs", 'withMVar (entryControlGate entry) $ \\_ -> do', 'entryControlGate entry `seq` do')
    target, arguments = "manager-approval-check", ["controls-preparation"]
    marker = "FAIL same-run preparation holds original queued caller"
elif mode == "control-reload-race":
    replace("manager/src/Agentic/Manager/State.hs", "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace("manager/src/Agentic/Manager/State.hs", "          policy <- either (const(throwIO Command.StorageUnavailable)) pure selected\n",
            '          policy <- either (const(throwIO Command.StorageUnavailable)) pure selected\n          Audit.afterCurrentReview "control-authorization"\n')
    target, arguments = "manager-approval-check", ["controls-reload-race"]
elif mode == "control-write":
    helper = copy / "runtime/src/ControlDeliveryAudit.hs"
    helper.write_bytes((source / "runtime/test/ControlDeliveryAudit.hs").read_bytes())
    changes.append({"path": "runtime/src/ControlDeliveryAudit.hs", "beforeSha256": None,
                    "afterSha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
                    "source": "runtime/test/ControlDeliveryAudit.hs", "diff": helper.read_text()})
    replace("agentic.cabal", "    Agentic.Exec\n", "    ControlDeliveryAudit\n    Agentic.Exec\n")
    replace("runtime/src/Agentic/Runtime/Machine.hs", "import Agentic.Runtime.Control\n", "import qualified ControlDeliveryAudit as Audit\nimport Agentic.Runtime.Control\n")
    replace("runtime/src/Agentic/Runtime/Machine.hs", '      frame <- readNdjsonFrame maxFrameBytes "runtime control" handle buffered',
            '      Audit.beforeControlRead (BS.length buffered)\n      frame <- readNdjsonFrame maxFrameBytes "runtime control" handle buffered')
    replace("manager/src/Agentic/Manager/Worker.hs", "import Agentic.Manager.Protocol.Command", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Protocol.Command")
    replace("manager/src/Agentic/Manager/Worker.hs", '(BS.hPut pipe (bytes <> "\\n") >> hFlush pipe)', '(Audit.writeControlFrame pipe (bytes <> "\\n"))')
    replace("manager/src/Agentic/Manager/Worker.hs", "Handle, hFlush, hSetBinaryMode", "Handle, hSetBinaryMode")
    target, arguments = "manager-approval-check", ["controls-write"]
elif mode in {"control-unsupported", "control-unsupported-mutant"}:
    helper = copy / "runtime/src/ControlDeliveryAudit.hs"
    helper.write_bytes((source / "runtime/test/ControlDeliveryAudit.hs").read_bytes())
    changes.append({"path": "runtime/src/ControlDeliveryAudit.hs", "beforeSha256": None,
                    "afterSha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
                    "source": "runtime/test/ControlDeliveryAudit.hs", "diff": helper.read_text()})
    replace("agentic.cabal", "    Agentic.Exec\n", "    ControlDeliveryAudit\n    Agentic.Exec\n")
    replace("runtime/src/Agentic/Runtime/Machine.hs", "import Agentic.Runtime.Control\n", "import qualified ControlDeliveryAudit as Audit\nimport Agentic.Runtime.Control\n")
    replace("runtime/src/Agentic/Runtime/Machine.hs", "                Just delivery -> do\n",
            "                Just delivery -> do\n                  case delivery of ActSteer {} -> Audit.beforeControlDelivery (controlIdText (controlId control)); _ -> pure ()\n")
    replace("runtime/src/Agentic/Exec.hs", "import Agentic.Runtime.Control\n", "import qualified ControlDeliveryAudit as Audit\nimport Agentic.Runtime.Control\n")
    replace("runtime/src/Agentic/Exec.hs", "        (unregisterControlAttempt controls attempt)",
            "        (unregisterControlAttempt controls attempt >> Audit.afterAttemptRetired (T.pack (show attempt)))")
    target, arguments = "manager-approval-check", ["controls-stale-steer"]
    marker = "FAIL genuine Accepted to Unsupported remains distinct with no effect"
    if mode == "control-unsupported-mutant":
        replace("manager/src/Agentic/Manager/State.hs", '["commandId" .= ident,"state" .= state,"message"',
                '["commandId" .= ident,"state" .= (if state=="unsupported" then "delivered" else state),"message"')
elif mode == "control-steer-observation-mutant":
    replace("runtime/src/Agentic/Runtime/Snapshot.hs", "pure current {snapshotAttemptSteerable = Just steerable}",
            "pure current {snapshotAttemptSteerable = Just (steerable && False)}")
    target, arguments = "manager-approval-check", ["controls-steering"]
    marker = "FAIL genuine registered steerability observed"
elif mode in {"control-reservation-mutant", "control-body-mutant", "control-release-mutant", "control-fifo-mutant"}:
    path = "manager/src/Agentic/Manager/State.hs"
    target, arguments = "manager-approval-check", ["controls"]
    if mode == "control-reservation-mutant":
        replace(path, '| state/="pending" -> pure(Left Command.StaleRevision)', '| False && state/="pending" -> pure(Left Command.StaleRevision)')
        marker = "FAIL reserved generation cannot accept another answer before write"
    elif mode == "control-body-mutant":
        replace(path, 'maybe Null id (KM.lookup "value" fields)', 'maybe Null (\\rawAnswer -> if rawAnswer==Bool False then Bool True else rawAnswer) (KM.lookup "value" fields)')
        marker = "FAIL false null arrays objects and numbers reach original Runtime typed answer store unchanged"
    elif mode == "control-release-mutant":
        replace(path, 'if state `elem` ["rejected-stale","unsupported","failed"] then releaseDecision', 'if state `elem` ["accepted","rejected-stale","unsupported","failed"] then releaseDecision')
        marker = "FAIL native Accepted cannot release submitting decision"
    else:
        replace(path, 'headId/=ident;_->True -> pure(Left Command.DecisionNotHead)', 'headId/=headId;_->False -> pure(Left Command.DecisionNotHead)')
        target, arguments = "manager-approval-check", ["controls-live"]
        marker = "FAIL genuine mixed non-head refuses through both internal entrypoints"
elif mode in {"interruption", "ticket-mutant", "approval-interruption", "control-interruption", "control-ticket-mutant"}:
    replace(commands, "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace(commands, "CommandAttempt _ _ _ candidate retained generationAtCreation _ <-", "CommandAttempt _ _ _ candidate retained generationAtCreation auditAttemptPhase <-")
    replace(commands, "      Right (receipt, replayed, dispatch, refs, generation, epoch, association) -> do\n",
            "      Right (receipt, replayed, dispatch, refs, generation, epoch, association) -> do\n        unless replayed (Audit.afterFreshCommit candidate retained auditAttemptPhase)\n")
    replace(commands, "  done <- readIORef phase\n", "  Audit.recordReconciliation candidate retained phase\n  done <- readIORef phase\n")
    replace(commands, "        Right () -> Right <$> restore (action payload)",
            "        Right () -> do\n          Audit.recordDelivery ident state\n          Right <$> restore (action payload)")
    if mode in {"ticket-mutant", "control-ticket-mutant"}:
        replace(commands, "  reconcile = do\n   outcome <-", "  reconcile = do\n   replacement <- newIORef (TicketState Unreserved Nothing)\n   outcome <-")
        replace(commands, "if dispatch then Just(DispatchTicket store candidate generation refs retained)", "if dispatch then Just(DispatchTicket store candidate generation refs replacement)")
    if mode in {"approval-interruption", "control-interruption", "control-ticket-mutant"}:
        replace(commands, "          Right <$> restore (action payload)", "          Right <$> restore (action payload <* Audit.afterNativeReturn ident state)")
        target, arguments = "manager-approval-check", ["interrupted-approval" if mode == "approval-interruption" else "controls-interruption"]
    else:
        target, arguments = "manager-admission-check", ["interrupted-acceptance"]
    marker = "FAIL control acceptance reconciles original ticket and payload" if mode == "control-ticket-mutant" else "FAIL interrupted live cleanup uses original attempt and original ticket state"
elif mode in {"approval-review-gap", "approval-publication-mutant", "approval-catalogue-mutant"}:
    admission = "manager/src/Agentic/Manager/Admission.hs"
    replace(admission, "import Agentic.Manager.Authorization\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Authorization\n")
    replace(admission, "  current <- currentReview controller entry\n", "  current <- currentReview controller entry\n  Audit.afterCurrentReview \"publication\"\n")
    replace(admission, "    current<-currentReview controller entry\n", "    current<-currentReview controller entry\n    Audit.afterCurrentReview \"acceptance\"\n")
    target, arguments = "manager-approval-check", ["review-gap"]
    if mode == "approval-publication-mutant":
        replace("manager/src/Agentic/Manager/Approval.hs", "    unless(currentCatalogue catalogues (P.reviewProfile public) (reviewProfileRevision context) descriptor workflow)(refuseTransaction StaleRevision)", "    unless(currentCatalogue catalogues (P.reviewProfile public) (reviewProfileRevision context) descriptor workflow)(pure())")
        marker = "FAIL publication final catalogue agrees with original currentReview"
    elif mode == "approval-catalogue-mutant":
        replace("manager/src/Agentic/Manager/Approval.hs", "        unless(currentCatalogue catalogues (P.preparationProfile preparation) (P.preparationProfileRevision preparation) (P.preparationDescriptorRevision preparation) (P.reviewWorkflow(P.preparationReview preparation)))(Left StaleRevision)", "        unless(currentCatalogue catalogues (P.preparationProfile preparation) (P.preparationProfileRevision preparation) (P.preparationDescriptorRevision preparation) (P.reviewWorkflow(P.preparationReview preparation)))(pure())")
        marker = "FAIL fresh approval final catalogue agrees with original currentReview"
elif mode == "approval-reservation-mutant":
    replace("manager/src/Agentic/Manager/Approval.hs", "  unless(rows==[[SQL.SQLInteger 1]])(refuseTransaction StateConflict)", "  unless(rows==[[SQL.SQLInteger 1]])(pure())")
    target, arguments = "manager-approval-check", ["reservation-integrity"]
    marker = "FAIL approval requires complete original reservation footprint"
elif mode == "approval-quoted-mutant":
    path = "manager/src/Agentic/Manager/Approval.hs"
    replace(path, "      | c=='`' || (isPunctuation c && c `notElem` (\"-_\"::String)) = \" \"", "      | c=='`' || (isPunctuation c && c `notElem` (\"-_\"::String)) = T.singleton c")
    target, arguments = "manager-approval-check", ["privacy-native"]
    marker = "FAIL quoted or punctuated native credentials refuse exact review"
elif mode == "approval-delimiter-mutant":
    replace("manager/src/Agentic/Manager/Approval.hs", "      | c `elem` (\":=\"::String) = T.pack [' ',c,' ']", "      | c `elem` (\":=\"::String) = T.singleton c")
    target, arguments = "manager-approval-check", ["privacy-header"]
    marker = "FAIL uniform credential delimiter matrix refuses native review"
elif mode == "approval-supervision-mutant":
    path = "manager/src/Agentic/Manager/Admission.hs"
    replace(path, "UPDATE runs SET supervision=?,revision=?,control_revision=? WHERE request_id=? AND supervision=?", "UPDATE runs SET supervision=?,revision=revision,control_revision=? WHERE request_id=? AND supervision=?")
    replace(path, "[text next,text revision,text revision,text(entryRequest entry),text previous]", "[text next,text revision,text(entryRequest entry),text previous]")
    target, arguments = "manager-approval-check", ["supervision"]
    marker = "FAIL original stop changes run revision with supervision"
elif mode == "approval-live-target-mutant":
    replace("manager/src/Agentic/Manager/Worker.hs", "  either (const(throwIO WorkerWrongIdentity)) pure (operatorPreparedTarget (selectionContext selected) reply)", "  pure ()")
    target, arguments = "manager-approval-check", ["targets-live"]
    marker = "FAIL live Worker rejects real prepared field corruption: bad-prefix"
elif mode == "approval-live-mutant":
    replace("manager/src/Agentic/Manager/Store.hs", "  mapM_ checkPreparedCommit prepared", "  mapM_ (\\guard -> void(try @StoreFailure(checkPreparedCommit guard))) prepared")
    target, arguments = "manager-approval-check", ["worker-loss"]
    marker = "FAIL detected original worker loss rejects final acceptance"
elif mode in {"ingestion-race", "ingestion-race-mutant"}:
    path = "manager/src/Agentic/Manager/State.hs"
    replace(path,"import Agentic.Manager.Store\n","import Agentic.Manager.Store\nimport qualified Agentic.Manager.Test.AcceptanceAudit as Audit\n")
    replace(path,"\n  empty <- valid (captureSnapshotCheckpoint (associationNative association) [])\n",'\n  Audit.afterCurrentReview "state-prefix"\n  empty <- valid (captureSnapshotCheckpoint (associationNative association) [])\n')
    replace(path,"      runTransaction store $ do\n",'      Audit.afterCurrentReview "state-publication"\n      runTransaction store $ do\n')
    if mode == "ingestion-race-mutant":
        replace(path,"        unless (actual == expected) (refuseTransaction StoreBusy)","        void (pure (actual == expected))")
    target, arguments = "manager-approval-check", ["ingestion-race"]
    marker = "FAIL stale concurrent publication returns explicit StoreBusy"
elif mode == "ingestion-cleanup-mutant":
    replace("manager/src/Agentic/Manager/Admission.hs","(actual==revision || associated)","(actual==revision && not associated)")
    target, arguments = "manager-approval-check", ["ingestion-cleanup"]
    marker = "manager-approval-check: StateConflict"
elif mode == "ingestion-observer-mutant":
    path = "cli/test/ManagerApprovalProbe.hs"
    text = (copy/path).read_text()
    start = text.index("processObservation observe =")
    end = text.index("\nobserveProcess ::",start)
    replace(path,text[start:end],'processObservation observe = do\n  (code,output,_) <- observe\n  pure (if code==ExitFailure 1 then Nothing else Just output)\n')
    target, arguments = "manager-approval-check", ["ingestion-observer"]
    marker = "FAIL observer rejects diagnostic exit-one rather than claiming absence"
elif mode in {"store-cancel-gap", "store-cancel-mutant", "store-expiry-mutant"}:
    path = "manager/src/Agentic/Manager/Store.hs"
    replace(path, "import Agentic.Manager.Configuration\n", "import qualified Agentic.Manager.Test.AcceptanceAudit as Audit\nimport Agentic.Manager.Configuration\n")
    replace(path, "    collectRows budget statement\n", '    if "1000000000000" `T.isInfixOf` sql then Audit.atSqlStep (collectRows budget statement) else collectRows budget statement\n')
    if mode in {"store-cancel-mutant", "store-expiry-mutant"}:
        text = (copy / path).read_text()
        start = text.index("boundedWith db remaining action =")
        end = text.index("\nstorageErrors ::",start)
        replace(path,text[start:end],"boundedWith db remaining action = do\n  Audit.retainSqlInterrupt (SQL.interrupt db)\n  micros <- remaining\n  result <- timeout micros (SQL.interruptibly db action)\n  maybe (throwIO StoreDeadline) pure result\n")
        replace(path,"import Control.Concurrent (threadDelay)\nimport Control.Concurrent.Async (race, withAsync, asyncWithUnmask, cancel, wait)","import Control.Concurrent.Async (race)")
        replace(path,", onException, catch)",", catch)")
        replace(path,", forever)",")")
    else:
        replace(path,"boundedWith db remaining action = mask $ \\restore ->\n  withAsync", "boundedWith db remaining action = mask $ \\restore -> do\n  Audit.retainSqlInterrupt (SQL.interrupt db)\n  withAsync")
    if mode == "store-expiry-mutant":
        replace("cli/test/ManagerApprovalProbe.hs", '[False,True] $ \\expiry ->', '[True,False] $ \\expiry ->')
    target, arguments = "manager-approval-check", ["store-cancel-gap"]
    marker = "FAIL missed SQL interrupt joins original action"
elif mode == "ingestion-retained-mutant":
    replace("manager/src/Agentic/Manager/Worker.hs", "        (Just <$> peekTBQueue (eventQueue worker)) `orElse` do", "        closed <- readTVar (released worker)\n        when closed (throwSTM WorkerClosed)\n        (Just <$> peekTBQueue (eventQueue worker)) `orElse` do")
    target, arguments = "manager-approval-check", ["ingestion-native"]
    marker = "manager-approval-check: WorkerClosed"
elif mode == "ingestion-duplicate-mutant":
    replace("manager/src/Agentic/Manager/State.hs", "      pure False\n    Nothing -> do", "      runTransaction store (pure (False,[Invalidation \"run.changed\" (runURI association <> \"/snapshot\") \"duplicate\"]))\n    Nothing -> do")
    target, arguments = "manager-approval-check", ["ingestion-native"]
    marker = "FAIL commit-return duplicate window creates no invalidation"
elif mode == "retry-mutant":
    replace("manager/src/Agentic/Manager/Admission.hs", "  completed <- atomically(tryReadTMVar(entryResult entry))\n  unless (isJust completed) (throwIO StateConflict)\n", "")
    target, arguments = "manager-admission-check", ["active-retry"]
    marker = "FAIL active retry prevented Admission scope shutdown"
elif mode == "deadline-mutant":
    replace("manager/src/Agentic/Manager/Store.hs", "  unless(observed<deadline)(throwIO StoreDeadline)", "  void(pure(observed<deadline))")
    target, arguments = "manager-command-check", ["deadline-crossing"]
    marker = "FAIL deadline crossing inside fresh acceptance refuses commit"
elif mode == "termination-mutant":
    path = "runtime/src/Agentic/Runtime/ProcessGroup.hs"
    text = (copy / path).read_text()
    start = text.index("terminateProcessGroup grace group =")
    finish = text.index("    signalOwned signal", start)
    body = text[text.index("    terminate = mask", start):finish]
    original = "terminateProcessGroup grace group =" + body.split("=", 1)[1]
    original = "\n".join(line[4:] if line.startswith("    ") else line for line in original.splitlines()) + "\n  where\n"
    replace(path, text[start:finish], original)
    replace(path, "import Control.Concurrent.Async (asyncWithUnmask, waitCatch)\n", "")
    target, arguments = "manager-worker-check", ["termination-cases"]
    marker = "FAIL caller "
elif mode == "watchdog-mutant":
    replace("manager/src/Agentic/Manager/Worker.hs", "    void (readTMVar (prepared worker)) `orElse` void (readTMVar (finished worker))", "    void (readTMVar (finished worker))")
    target, arguments = "manager-worker-check", ["watchdog-survival"]
    marker = "FAIL successful preparation disarms startup watchdog independently of caller await"
else:
    replace("manager/src/Agentic/Manager/Admission/Policy.hs", "Set.disjoint (candidateResources candidate) claimed", "Set.disjoint Set.empty claimed")
    target, arguments = "manager-admission-check", ["static-occupancy"]
    marker = "FAIL supplied held claims exclude conflicts and consume global capacity"

(work / "instrumentation.json").write_text(json.dumps({"mode": mode, "changes": changes}, indent=2) + "\n")
(work / "instrumentation.diff").write_text("".join(change["diff"] for change in changes))
environment = dict(os.environ, CABAL_BUILDDIR=str(work / "build"))
environment.pop("GHCRTS", None)
results = []

def run(command, log, timeout=1200):
    if mode in {"restore-interruption", "shutdown-races", "history-policy", "history-corrections", "history-observation"}:
        assert not any(name == "GHCRTS" or name.startswith("AGENT_CAT_") for name in environment)
    entry = {"command": command, "log": log, "executionDeadlineSeconds": timeout,
             "returncode": None, "primaryFailure": None, "signalFailure": None,
             "waitFailure": None, "joinInterruptions": 0, "ownership": "not-started"}
    results.append(entry)
    def record(primary=None):
        try:
            (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        except OSError:
            if primary is None:
                raise
        except KeyboardInterrupt:
            if primary is None:
                raise
            entry["joinInterruptions"] += 1
    with (work / log).open("w") as output:
        process = None
        waiting = False
        try:
            process = subprocess.Popen(command, cwd=copy, env=environment,
                                       stdout=output, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + timeout
            entry["ownership"] = "original-child-running"
            record()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            waiting = True
            code = process.wait(timeout=remaining)
            waiting = False
        except BaseException as primary:
            entry["primaryFailure"] = type(primary).__name__
            if process is None:
                entry["ownership"] = "process-creation-UNPROVEN"
                record(primary)
                raise
            if waiting and not isinstance(primary, (subprocess.TimeoutExpired, KeyboardInterrupt)):
                entry["waitFailure"] = type(primary).__name__
                entry["ownership"] = "original-child-and-descendant-cleanup-UNPROVEN"
                record(primary)
                raise
            entry["ownership"] = "cleanup-unresolved"
            record(primary)
            try:
                process.send_signal(signal.SIGINT)
            except BaseException as failure:
                entry["signalFailure"] = type(failure).__name__
                record(primary)
            # Execution deadline has failed. Joining the original child has no kill deadline.
            while True:
                try:
                    entry["returncode"] = process.wait()
                    entry["ownership"] = "original-child-joined"
                    record(primary)
                    break
                except KeyboardInterrupt:
                    entry["joinInterruptions"] += 1
                    record(primary)
                except BaseException as failure:
                    entry["waitFailure"] = type(failure).__name__
                    entry["ownership"] = "original-child-and-descendant-cleanup-UNPROVEN"
                    record(primary)
                    break
            raise
        entry["returncode"] = code
        entry["ownership"] = "original-child-joined"
        record()
    return code

print(f"Audit evidence: {work}", flush=True)
if run(["bash", "test/cabal.sh", "build", target, "routing-fixed-point-probe", "--ghc-options=-Werror"], "build.log"):
    raise RuntimeError("instrumented/mutant compilation failed")

def binary(name):
    return subprocess.check_output(["bash", "test/cabal.sh", "list-bin", name], cwd=copy, env=environment, text=True, timeout=60).strip()

checker, native = binary(target), binary("routing-fixed-point-probe")
(work / "executables.json").write_text(json.dumps({path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in [checker, native]}, indent=2) + "\n")
for capabilities in ["N1", "N8"]:
    if mode in {"history-policy", "history-corrections", "history-observation"}:
        fixture = Path(tempfile.mkdtemp(prefix=f"wm018-{capabilities}.", dir=os.environ["TMPDIR"]))
    elif mode in {"restore-interruption", "shutdown-races"}:
        fixture = Path(tempfile.mkdtemp(prefix=f"{mode}-{capabilities}.", dir=os.environ["TMPDIR"]))
    else:
        fixture = work / capabilities
        fixture.mkdir()
    command = [checker, *arguments]
    if mode != "policy-mutant":
        command.append(str(fixture))
    if mode not in {"deadline-mutant", "policy-mutant"}:
        command.append(str(copy) if mode == "history-observation" else native)
    if mode in {"history-policy", "approval-live-mutant", "approval-live-target-mutant", "ingestion-race", "ingestion-race-mutant", "control-fifo-mutant", "control-unsupported", "control-unsupported-mutant", "control-steer-observation-mutant", "control-preparation", "control-preparation-mutant"}:
        command.extend([str(copy), shutil.which("python3")])
    command.extend(["+RTS", "-" + capabilities, "-RTS"])
    code = run(command, capabilities + ".log", timeout=120)
    output = (work / (capabilities + ".log")).read_text()
    if mode in {"restore-interruption", "shutdown-races", "history-policy", "history-corrections", "history-observation", "interruption", "approval-interruption", "approval-review-gap", "store-cancel-gap", "ingestion-race", "control-unsupported", "control-write", "control-interruption", "control-reload-race", "control-preparation"}:
        success = "PASS original cleanup effect commits with release" if mode == "interruption" else "PASS interrupted original start retains one native start and immutable receipt"
        if mode == "restore-interruption":
            success = "PASS interrupted restore refuses ordinary startup without fabricated success"
        if mode == "shutdown-races":
            success = "PASS one committed approval has one original attempted delivery"
        if mode == "history-policy":
            success = "PASS actual WM018 non-null routed policy provenance"
        if mode == "history-corrections":
            success = "PASS actual WM018 native lineage preservation and original ownership"
        if mode == "history-observation":
            success = "PASS removed retention root cannot enter artifact response"
        if mode == "control-preparation":
            success = "PASS independent run progresses during held original preparation"
        if mode == "control-reload-race":
            success = "PASS profile reload racing control acceptance cannot authorize write"
        if mode == "control-write":
            success = "PASS actual partial-write outcome remains unresolved without a native acknowledgement"
        if mode == "control-interruption":
            success = "PASS interrupted controls retain one original native write"
        if mode == "control-unsupported":
            success = "PASS genuine Accepted to Unsupported remains distinct with no effect"
        if mode == "store-cancel-gap":
            success = "PASS rollback restores autocommit for subsequent real commit"
        if mode == "ingestion-race":
            success = "PASS competing publication preserves advanced boundary and exact earlier evidence"
        if mode == "approval-review-gap":
            success = "PASS catalogue change cannot retroactively reinterpret accepted consent"
        if code or success not in output:
            raise RuntimeError(f"real {mode} checks failed")
    elif not code or marker not in output:
        raise RuntimeError("compiled mutant did not fail its intended assertion")
    label = "real offline restore interruption" if mode == "restore-interruption" else "real shutdown acceptance boundaries" if mode == "shutdown-races" else "real WM018 owner checks" if mode in {"history-policy", "history-corrections", "history-observation"} else "real per-entry preparation ownership" if mode == "control-preparation" else "real control authorization race" if mode == "control-reload-race" else "real original-handle write evidence" if mode == "control-write" else "real original control interruption" if mode == "control-interruption" else "real Accepted-to-Unsupported evidence" if mode == "control-unsupported" else "real catalogue race and unchanged/replay controls" if mode == "approval-review-gap" else "real interrupted acceptance" if mode in {"interruption", "approval-interruption"} else "intended mutant assertion"
    print(f"PASS {mode} {capabilities}: {label}", flush=True)
