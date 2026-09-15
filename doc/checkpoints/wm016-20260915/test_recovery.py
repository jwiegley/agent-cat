#!/usr/bin/env python3
"""Data-only recovery regression. Pass a private Products directory as argv[1]."""

from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import stat
import sys
import tarfile
import tempfile

import recover


def make_pool(path, name, payload=b"retained bytes\n", corrupt=False):
    digest = hashlib.sha256(payload).hexdigest()
    manifest = {"format": "agent-cat-recovery-pool-1", "files": {
        name: {"sha256": digest, "bytes": len(payload), "mode": 0o640}}}
    with tarfile.open(path, "w:gz") as archive:
        for member_name, content in [
                ("manifest.json", json.dumps(manifest).encode()),
                ("blobs/" + digest, b"x" * len(payload) if corrupt else payload)]:
            member = tarfile.TarInfo(member_name)
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))


def run(archive, destination=None):
    previous = sys.argv
    sys.argv = ["recover.py", str(archive)]
    if destination is not None:
        sys.argv += ["--destination", str(destination)]
    try:
        with redirect_stdout(io.StringIO()):
            recover.main()
    finally:
        sys.argv = previous


def refuses(archive, destination, message):
    try:
        run(archive, destination)
    except ValueError as failure:
        assert message in str(failure), failure
    else:
        raise AssertionError("Expected refusal")


def main():
    parent = Path(sys.argv[1]).expanduser()
    with tempfile.TemporaryDirectory(prefix="recovery-test.", dir=parent) as tmp:
        root = Path(tmp)
        good = root / "good.tar.gz"
        make_pool(good, "source/value.txt")
        restored = root / "restored"
        run(good, restored)
        assert (restored / "source/value.txt").read_bytes() == b"retained bytes\n"
        assert stat.S_IMODE((restored / "source/value.txt").stat().st_mode) == 0o640
        assert json.loads((restored / "recovery-manifest.json").read_text())["files"]
        refuses(good, restored, "Destination must not already exist")
        assert (restored / "source/value.txt").read_bytes() == b"retained bytes\n"
        for index, name in enumerate([
                "recovery-manifest.json", "recovery-manifest.json/child",
                "RECOVERY-MANIFEST.JSON"]):
            archive = root / f"collision-{index}.tar.gz"
            destination = root / f"collision-{index}"
            make_pool(archive, name)
            refuses(archive, destination, "Reserved recovery path")
            assert not destination.exists()
        unsafe = root / "unsafe.tar.gz"
        make_pool(unsafe, "../outside")
        refuses(unsafe, root / "unsafe", "Unsafe recovery path")
        assert not (root / "outside").exists()
        corrupt = root / "corrupt.tar.gz"
        make_pool(corrupt, "source/value.txt", corrupt=True)
        refuses(corrupt, root / "corrupt", "Incorrect blob digest")
        assert not (root / "corrupt").exists()
    print("PASS recovery bytes/mode, exclusive destination, reserved paths, traversal and digest checks")


if __name__ == "__main__":
    main()
