#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The text message service's logic on a plain JVM.

android/lineage-24/overlay/sms is the Java app that delivers a text message the host sends. What it builds
(the SMS-DELIVER PDUs, the request's parsing and the answers, the delivery record, the host channel's frame
and server) does not touch the platform: SmsServiceTest.java drives the PDUs and the bytes, reading the PDUs
back with a parser of its own and the JDK's "UTF-16" decoder, which is what Android's SmsMessage uses for the
user data; RecordTest.java the record (a child JVM is ended at each point a request can end at);
ChannelTest.java the server, and the listening socket (VsockListener) over scripted stand-ins for the
android.system classes in tests/tooling/android/sms/stubs. The sources compile here without the Android glue
(Delivery and HostChannel, which need the framework); the glue is compiled by the image build. The golden
bytes are tests/unit/andarium/fixtures/sms-golden-frames.txt, which the host's tests read too.
Skipped (status 77) where the host has no JDK.
"""

from __future__ import annotations
__import__("sys").dont_write_bytecode = True

import pathlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ElementTree

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
SOURCES = REPOSITORY / "android" / "lineage-24" / "overlay" / "sms" / "src" / "android" / "kernarium" / "sms"
TESTS = HERE / "sms" / "android" / "kernarium" / "sms"
STUBS = HERE / "sms" / "stubs"
GOLDEN = REPOSITORY / "tests" / "unit" / "andarium" / "fixtures" / "sms-golden-frames.txt"
ANDROID_GLUE = ("Delivery.java", "HostChannel.java")
# VsockListener names only android.system, which the stubs stand in for.
STUB_COMPILED = {"VsockListener.java"}
PLATFORM_FREE = {"Answer.java", "DeliverPdu.java", "DeliveryRecord.java", "DeliveryService.java", "HostFrame.java",
                 "Message.java", "RecordFiles.java", "RecordStore.java", "Server.java"}
# The test classes that run, each printing PASS.
MAINS = ("SmsServiceTest", "RecordTest", "ChannelTest")
MANIFEST = SOURCES.parents[3] / "AndroidManifest.xml"
ANDROID = "{http://schemas.android.com/apk/res/android}"
SKIP = 77


def manifest_problems() -> list[str]:
    """The service declares no component and is persistent, so nothing but its own socket reaches it (U5)."""
    application = ElementTree.parse(MANIFEST).getroot().find("application")
    if application is None:
        return ["the manifest has no application"]
    problems = [f"declares a <{child.tag}>" for child in application]
    if application.get(f"{ANDROID}persistent") != "true":
        problems.append("is not android:persistent=\"true\"")
    if application.get(f"{ANDROID}name") != ".HostChannel":
        problems.append("does not start HostChannel")
    return problems


def jdk_tool(name: str) -> str | None:
    """A working javac or java: the macOS /usr/bin stubs exist without a JDK, so ask it."""
    path = shutil.which(name)
    if path is None:
        return None
    probe = subprocess.run([path, "-version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=60, check=False)
    return path if probe.returncode == 0 else None


def main() -> int:
    problems = manifest_problems()
    if problems:
        print(f"FAIL: the service's manifest {', '.join(problems)}", file=sys.stderr)
        return 1
    javac, java = jdk_tool("javac"), jdk_tool("java")
    if javac is None or java is None:
        print("SKIP: no JDK (javac and java) on PATH")
        return SKIP
    sources = sorted(path for path in SOURCES.glob("*.java") if path.name not in ANDROID_GLUE)
    if {path.name for path in sources} != PLATFORM_FREE | STUB_COMPILED:
        print(f"FAIL: the sources outside the Android glue are {sorted(path.name for path in sources)}, "
              f"not {sorted(PLATFORM_FREE | STUB_COMPILED)}", file=sys.stderr)
        return 1
    for name in ANDROID_GLUE:
        if not (SOURCES / name).is_file():
            print(f"FAIL: {name} is missing", file=sys.stderr)
            return 1
    with tempfile.TemporaryDirectory(prefix="uml-sms-service-") as scratch:
        classes = pathlib.Path(scratch) / "classes"
        classes.mkdir()
        compiled = subprocess.run(
            [javac, "-Xlint:all", "-Werror", "-encoding", "UTF-8", "-d", str(classes),
             *(str(path) for path in sources), *(str(path) for path in sorted(STUBS.rglob("*.java"))),
             *(str(path) for path in sorted(TESTS.glob("*.java")))],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240,
            check=False)
        if compiled.returncode != 0:
            print(f"FAIL: javac:\n{compiled.stdout}", file=sys.stderr)
            return 1
        for main_class in MAINS:
            ran = subprocess.run([java, "-Dfile.encoding=UTF-8", f"-Dsms.golden={GOLDEN}", "-cp", str(classes),
                                  f"android.kernarium.sms.{main_class}"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 timeout=240, check=False)
            print(ran.stdout, end="")
            if ran.returncode != 0 or not ran.stdout.rstrip().endswith("PASS"):
                print(f"FAIL: {main_class}", file=sys.stderr)
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
