#!/usr/bin/env python3
"""Verify or restore the paused WM-016 evidence without executing it."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def relative_path(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or ".." in path.parts
            or str(path) != name or "\\" in name):
        raise ValueError(f"Unsafe recovery path: {name!r}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--destination", type=Path,
                        help="New, nonexistent directory under a private artifact root")
    args = parser.parse_args()
    with tarfile.open(args.archive, "r:gz") as archive:
        entries = {}
        for member in archive.getmembers():
            relative_path(member.name)
            if not member.isfile() or member.name in entries:
                raise ValueError(f"Invalid or duplicate archive member: {member.name}")
            entries[member.name] = member
        manifest = json.load(archive.extractfile(entries["manifest.json"]))
        if manifest.get("format") != "agent-cat-recovery-pool-1":
            raise ValueError("Unsupported recovery format")
        expected = {}
        for name, record in manifest["files"].items():
            relative_path(name)
            digest = record["sha256"]
            if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise ValueError(f"Invalid digest for {name}")
            if (type(record["bytes"]) is not int or record["bytes"] < 0
                    or type(record["mode"]) is not int
                    or record["mode"] < 0 or record["mode"] & ~0o777):
                raise ValueError(f"Invalid file metadata for {name}")
            if digest in expected and expected[digest] != record["bytes"]:
                raise ValueError("Conflicting content-addressed sizes")
            expected[digest] = record["bytes"]
        if set(entries) != {"manifest.json"} | {"blobs/" + d for d in expected}:
            raise ValueError("Archive members do not match the manifest")
        payloads = {}
        for digest in sorted(expected):
            member = entries["blobs/" + digest]
            if member.size != expected[digest]:
                raise ValueError(f"Incorrect blob size: {digest}")
            with archive.extractfile(member) as source:
                if args.destination is None:
                    actual = hashlib.file_digest(source, "sha256").hexdigest()
                else:
                    payloads[digest] = source.read()
                    actual = hashlib.sha256(payloads[digest]).hexdigest()
                if actual != digest:
                    raise ValueError(f"Incorrect blob digest: {digest}")
        if args.destination is not None:
            destination = args.destination.expanduser().absolute()
            if destination.exists() or destination.is_symlink():
                raise ValueError("Destination must not already exist")
            destination.mkdir(mode=0o700)
            for name, record in sorted(manifest["files"].items()):
                target = destination.joinpath(*relative_path(name).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                for parent in [target.parent, *target.parent.parents]:
                    if parent == destination:
                        break
                    if parent.is_symlink():
                        raise ValueError(f"Symlink in destination: {parent}")
                with target.open("xb") as output:
                    output.write(payloads[record["sha256"]])
                target.chmod(record["mode"])
            (destination / "recovery-manifest.json").write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"Verified {len(manifest['files'])} file records and {len(expected)} blobs")
        if args.destination is not None:
            print(f"Restored data to {args.destination}")
        print("No captured command, executable, PID, or worker authority was used")


if __name__ == "__main__":
    main()
