#!/usr/bin/env python3
"""Check that both public editions keep normal access rules and that the local flag fails without the private source or with the App Store flag."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
EDITION = ROOT / "Sources/AgeminApp/BuildEdition.swift"

with tempfile.TemporaryDirectory(prefix="agemin-public-access-", dir="/private/tmp") as directory:
    folder = Path(directory)

    # The fixture needs no Xcode plugins, so the Command Line Tools compile it without an Xcode license.
    compile_environment = os.environ.copy()
    compile_environment["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
    compiler = ["swiftc", "-module-cache-path", str(folder / "modules")]

    # Public source and App Store builds must both keep the shared identity and normal access rules.
    for flags, expected in (([], "source"), (["-D", "AGEMIN_APP_STORE"], "app-store")):
        executable = folder / f"test-{expected}"
        subprocess.run(
            compiler + flags + [str(EDITION), str(ROOT / "scripts/test_source_build.swift"), "-o", str(executable)],
            check=True,
            env=compile_environment,
        )
        subprocess.run([str(executable), expected], check=True)

    # The local flag must fail when the ignored access source is absent.
    missing = subprocess.run(
        compiler + ["-typecheck", "-D", "AGEMIN_LOCAL_BUILD", str(EDITION)],
        capture_output=True,
        text=True,
        env=compile_environment,
    )
    assert missing.returncode != 0 and "AgeminLocalAccess" in missing.stderr

    # App Store and private-local flags must never coexist.
    conflict = subprocess.run(
        compiler + [
            "-typecheck", "-D", "AGEMIN_LOCAL_BUILD", "-D", "AGEMIN_APP_STORE", str(EDITION),
        ],
        capture_output=True,
        text=True,
        env=compile_environment,
    )
    assert conflict.returncode != 0 and "Local access must not be included" in conflict.stderr
    print("Public source and App Store editions keep normal access rules, and local flags are guarded")
