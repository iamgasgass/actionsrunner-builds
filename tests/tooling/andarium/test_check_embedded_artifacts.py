#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""scripts/check-embedded-artifacts.py refuses an artifact behind its commit.

Each case builds a synthetic Git repository that holds the files the check
reads (the input list, the descriptors, the kernel metadata and fragments), a
staged system and a built application with a runtime framework whose Mach-O
carries a kernel banner and configuration, then changes one thing and runs the
script on it. The staged and the packaged system disk are tied to the accepted
release as installed below .build/android/releases, not to a digest their own
layout names, and a repeated JSON key is refused. An unsigned proof image, which a developer build may embed, is
refused in the staged and the packaged system, and the Xcode build phase that
runs the check does so for the AppStore and TestFlight configurations only.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import gzip
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
SCRIPT = REPOSITORY / "scripts/check-embedded-artifacts.py"
sys.path.insert(0, str(REPOSITORY / "android/lineage-24/tools"))
import release_inputs  # noqa: E402


RELEASE_ID = "20261201-los24-r99"
KERNEL_ID = "20261201-6.18.99-ks99"
KERNEL_RELEASE = "6.18.99-gfeedface0000"
DISK = b"disk-bytes" * 100
TREE = "a" * 40
OTHER_TREE = "b" * 40
FRAMEWORK = "KRuntime_Android_6_18_4K"
LIST = release_inputs.LIST_RELATIVE
DESCRIPTOR = "android/lineage-24/metadata/accepted-release.env"
KERNEL_DESCRIPTOR = "kernel/mainline-6.18/artifacts/accepted-android-4k.env"
METADATA = "kernel/mainline-6.18/patches/metadata.env"
CONFIG = "CONFIG_UML=y\nCONFIG_MODULES=n\nCONFIG_BINDER=y\n# CONFIG_NFS_FS is not set\nCONFIG_HZ=100\n"

INPUTS = (
    "input\tandroid/lineage-24/overlay\tthe product tree\n"
    "input\tandroid/lineage-24/tools/publish-release.py\twrites the manifest\n"
    "input\tandroid/lineage-24/third_party\tthe pins of the sources the image builds\n"
    "input\tdependencies/patches/talkback\tthe series applied to TalkBack\n"
    "excluded\tandroid/lineage-24/README.md\tdocumentation\n"
    "excluded\tandroid/lineage-24/metadata/accepted-release.env\tthe acceptance record\n"
    "excluded\tandroid/lineage-24/support/release/input-paths.tsv\tthis list\n"
)


def git(repo: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True, stdin=subprocess.DEVNULL, capture_output=True, text=True,
    ).stdout.strip()


def write(repo: Path, relative: str, text: str) -> None:
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def macho(sections: dict) -> bytes:
    """A thin arm64 Mach-O whose __TEXT segment holds the given sections."""
    names = list(sections)
    command_size = 72 + 80 * len(names)
    offset = 32 + command_size
    entries = b""
    payload = b""
    for name in names:
        data = sections[name]
        entries += (
            name.encode().ljust(16, b"\0") + b"__TEXT".ljust(16, b"\0")
            + struct.pack("<QQIIIIIIII", 0, len(data), offset + len(payload), 0, 0, 0, 0, 0, 0, 0)
        )
        payload += data
    segment = (
        struct.pack("<II", 0x19, command_size) + b"__TEXT".ljust(16, b"\0")
        + struct.pack("<QQQQIIII", 0, offset + len(payload), 0, offset + len(payload), 7, 5, len(names), 0)
    )
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, 1, command_size, 0, 0)
    return header + segment + entries + payload


NEUTRAL_BUILDER = "kernarium@kernarium"


def kernel_image(
    release: str = KERNEL_RELEASE, config: str = CONFIG,
    builder: str = NEUTRAL_BUILDER, proc_builder: str = NEUTRAL_BUILDER,
) -> bytes:
    """A kernel image with the banner and the /proc/version format, which both name the builder."""
    return (
        b"\x7fELF" + b"\0" * 64
        + f"Linux version {release} ({builder}) (clang) #1 SMP\n".encode()
        + b"\0" * 8 + f"%s version %s ({proc_builder}) (clang) %s\n".encode()
        + b"\0" * 32 + b"IKCFG_ST" + gzip.compress(config.encode()) + b"IKCFG_ED" + b"\0" * 16
    )


class Fixture:
    """A repository at a commit whose artifacts are current, with a staged system and an app."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.repo = root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", ".")
        write(self.repo, ".gitignore", "/.build/\n")
        write(self.repo, LIST, "# list\n" + INPUTS)
        write(self.repo, "android/lineage-24/overlay/product.mk", "PRODUCT=1\n")
        write(self.repo, "android/lineage-24/tools/publish-release.py", "# publish\n")
        write(self.repo, "android/lineage-24/README.md", "docs\n")
        write(self.repo, "kernel/common/patches/0001-one.patch", "one\n")
        write(self.repo, "kernel/mainline-6.18/patches/series/0001-two.patch", "two\n")
        write(self.repo, METADATA, f"UML_KERNEL_FINAL_TREE='{TREE}'\n")
        write(self.repo, "kernel/common/config/darwin-uml.fragment", "CONFIG_UML=y\nCONFIG_MODULES=n\n")
        write(self.repo, "kernel/mainline-6.18/config/android.fragment", "# android\nCONFIG_BINDER=y\n# CONFIG_NFS_FS is not set\n")
        write(self.repo, "kernel/mainline-6.18/config/android-required-builtins.txt", "CONFIG_BINDER\n")
        write(self.repo, "kernel/mainline-6.18/config/android-forbidden-options.txt", "CONFIG_NFS_FS\n")
        write(self.repo, "android/lineage-24/third_party/accessibility/metadata.env", f"TALKBACK_UPSTREAM_COMMIT='{'1' * 40}'\n")
        write(self.repo, "dependencies/patches/talkback/series.tsv", f"# series\ntree\t{'4' * 40}\n")
        self.first = commit(self.repo, "base")
        self.trees = release_inputs.object_ids(self.repo, release_inputs.input_paths(self.repo / LIST))
        self.set_descriptors()
        self.stage()
        self.app = self.package()

    def set_descriptors(
        self, trees=None, schema: int = 7, kernel_tree: str = TREE, release_id: str = RELEASE_ID
    ) -> None:
        trees = self.trees if trees is None else trees
        lines = [
            f"LINEAGE24_ACCEPTED_SCHEMA={schema}",
            f"LINEAGE24_ACCEPTED_RELEASE_ID='{release_id}'",
            f"LINEAGE24_ACCEPTED_DIRECTORY_NAME='lineage24-mainline6.18-4k-{release_id}'",
        ]
        if schema >= 7:
            lines.append(f"LINEAGE24_ACCEPTED_INPUT_TREES='{release_inputs.render_trees(trees)}'")
        write(self.repo, DESCRIPTOR, "\n".join(lines) + "\n")
        write(
            self.repo, KERNEL_DESCRIPTOR,
            f"UML_KERNEL_ARTIFACT_RELEASE_ID='{KERNEL_ID}'\n"
            f"UML_KERNEL_ARTIFACT_RELEASE='{KERNEL_RELEASE}'\n"
            f"UML_KERNEL_ARTIFACT_FINAL_TREE='{kernel_tree}'\n")
        commit(self.repo, "accept the artifacts")
        self.install(release_id)

    def install(self, release_id: str = RELEASE_ID, disk: bytes = DISK) -> Path:
        """The accepted release as install-release.py leaves it below .build/android/releases."""
        installed = self.repo / ".build/android/releases" / f"lineage24-mainline6.18-4k-{release_id}"
        shutil.rmtree(installed, ignore_errors=True)
        write(installed, "release-manifest.json", json.dumps(self.manifest(release_id)))
        write(installed, "guest/partition-layout.json", json.dumps(self.layout(disk)))
        return installed

    @staticmethod
    def layout(disk: bytes) -> dict:
        import hashlib

        return {"schema_version": 2, "system_disk": {"size_bytes": len(disk), "sha256": hashlib.sha256(disk).hexdigest()}}

    def manifest(self, release_id: str = RELEASE_ID, trees=None) -> dict:
        trees = self.trees if trees is None else trees
        return {
            "acceptance": "accepted", "release_id": release_id,
            "outer": {"revision": "c" * 40, "dirty": False, "input_trees": trees},
        }

    def proof_manifest(self, release_id: str = "unsigned-proof-ff1") -> dict:
        """What Andarium/scripts/stage-system-image.py --unsigned-proof stages."""
        return {
            "acceptance": "unsigned-proof", "release_id": release_id,
            "android": {"build_number": 29, "signed": False},
            "outer": {"revision": "c" * 40, "dirty": False},
        }

    def stage(self, release_id: str = RELEASE_ID, trees=None, disk: bytes = DISK) -> Path:
        staged = self.repo / ".build/andarium-system"
        shutil.rmtree(staged, ignore_errors=True)
        (staged / "guest").mkdir(parents=True)
        (staged / "boot").mkdir()
        (staged / "guest/system.img").write_bytes(disk)
        write(staged, "guest/partition-layout.json", json.dumps(self.layout(disk)))
        write(staged, "boot/kernel-command-line.txt", "init=/init\n")
        write(staged, "release-manifest.json", json.dumps(self.manifest(release_id, trees)))
        return staged

    def package(self, release: str = KERNEL_RELEASE, config: str = CONFIG, **builders: str) -> Path:
        app = self.root / "Andarium.app"
        shutil.rmtree(app, ignore_errors=True)
        shutil.copytree(self.repo / ".build/andarium-system", app / "andarium-system")
        framework = app / "Frameworks" / f"{FRAMEWORK}.framework"
        framework.mkdir(parents=True)
        (framework / FRAMEWORK).write_bytes(macho({"__uml_elf": kernel_image(release, config, **builders)}))
        return app

    def run(self, *arguments: str, decision: str | None = None, app: bool = True, python: str = sys.executable):
        environment = {key: value for key, value in os.environ.items() if key != "PENDING_INPUTS_DECISION"}
        if decision is not None:
            environment["PENDING_INPUTS_DECISION"] = decision
        command = [python, "-B", str(SCRIPT), "--repository", str(self.repo), "--android-release", "--kernel", "android"]
        if app:
            command += ["--app", str(self.app)]
        return subprocess.run(
            command + list(arguments), env=environment, check=False, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=120)


class CheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.fixture = Fixture(self.root)
        self.repo = self.fixture.repo

    def passes(self, result) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)

    def fails(self, result, *needles: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for needle in needles:
            self.assertIn(needle, result.stderr)

    def test_current_artifacts_pass(self) -> None:
        result = self.fixture.run()
        self.passes(result)
        self.assertIn("input paths are the ones on this commit", result.stdout)
        self.passes(self.fixture.run(app=False))

    def test_runs_on_the_system_python(self) -> None:
        # Xcode's PATH reaches /usr/bin/python3 first, which is older than the tools.
        if not Path("/usr/bin/python3").exists():
            self.skipTest("no /usr/bin/python3")
        self.passes(self.fixture.run(python="/usr/bin/python3"))

    def test_a_changed_input_names_the_path_and_the_commits(self) -> None:
        write(self.repo, "android/lineage-24/overlay/product.mk", "PRODUCT=2\n")
        commit(self.repo, "overlay: change the product")
        write(self.repo, "android/lineage-24/overlay/more.mk", "MORE=1\n")
        commit(self.repo, "overlay: add more")
        result = self.fixture.run()
        self.fails(
            result, RELEASE_ID, "android/lineage-24/overlay changed",
            "overlay: change the product", "overlay: add more", "PENDING_INPUTS_DECISION=" + RELEASE_ID)
        self.assertNotIn("publish-release.py changed", result.stderr)

    def test_a_source_the_image_builds_is_an_input_of_the_release(self) -> None:
        # TalkBack and eSpeak NG are built by the image build, so their pins and
        # series decide the release as any other input does.
        for path, text, name in (
            ("android/lineage-24/third_party/accessibility/metadata.env",
             f"TALKBACK_UPSTREAM_COMMIT='{'9' * 40}'\n", "android/lineage-24/third_party"),
            ("dependencies/patches/talkback/series.tsv",
             f"# series\ntree\t{'6' * 40}\n", "dependencies/patches/talkback"),
        ):
            with self.subTest(path):
                original = (self.repo / path).read_text()
                write(self.repo, path, text)
                commit(self.repo, f"change {path}")
                self.fails(self.fixture.run(), RELEASE_ID, f"{name} changed")
                write(self.repo, path, original)
                commit(self.repo, f"restore {path}")
                self.passes(self.fixture.run())

    def test_an_excluded_path_changes_nothing(self) -> None:
        write(self.repo, "android/lineage-24/README.md", "more docs\n")
        commit(self.repo, "docs")
        self.passes(self.fixture.run())

    def test_a_dirty_input_fails_and_no_decision_covers_it(self) -> None:
        write(self.repo, "android/lineage-24/overlay/product.mk", "PRODUCT=dirty\n")
        for decision in (None, RELEASE_ID):
            self.fails(self.fixture.run(decision=decision), "uncommitted", "android/lineage-24/overlay/product.mk")
        git(self.repo, "checkout", "-q", "--", "android/lineage-24/overlay/product.mk")
        write(self.repo, "android/lineage-24/overlay/untracked.mk", "NEW=1\n")
        self.fails(self.fixture.run(decision=RELEASE_ID), "untracked.mk")
        (self.repo / "android/lineage-24/overlay/untracked.mk").unlink()
        write(self.repo, "kernel/common/config/darwin-uml.fragment", "CONFIG_UML=n\n")
        self.fails(self.fixture.run(decision=KERNEL_ID), "darwin-uml.fragment")

    def test_a_staged_release_that_is_not_the_accepted_one_fails(self) -> None:
        self.fixture.stage("20260101-los24-r1")
        result = self.fixture.run(app=False, decision=RELEASE_ID)
        self.fails(result, "20260101-los24-r1", "not the accepted " + RELEASE_ID)
        self.fixture.stage()
        self.fixture.stage(trees={**self.fixture.trees, "android/lineage-24/overlay": "d" * 40})
        self.fails(self.fixture.run(app=False), "input trees that differ")

    def test_a_staged_unsigned_proof_fails_by_name_and_no_decision_covers_it(self) -> None:
        # The proof's own release ID, and the accepted one with the accepted
        # input trees (a proof that took everything but its acceptance).
        for release_id in ("unsigned-proof-ff1", RELEASE_ID):
            with self.subTest(release_id):
                staged = self.fixture.stage()
                manifest = self.fixture.proof_manifest(release_id)
                if release_id == RELEASE_ID:
                    manifest["outer"]["input_trees"] = self.fixture.trees
                (staged / "release-manifest.json").write_text(json.dumps(manifest))
                for decision in (None, RELEASE_ID, f"{release_id},{KERNEL_ID}"):
                    for app in (False, True):
                        if app:
                            self.fixture.app = self.fixture.package()
                        result = self.fixture.run(app=app, decision=decision)
                        self.fails(result, "the staged system", "an unsigned proof image",
                                   "without --unsigned-proof")
        # Staging the accepted release again passes.
        self.fixture.stage()
        self.fixture.app = self.fixture.package()
        self.passes(self.fixture.run())

    def test_a_packaged_unsigned_proof_fails_though_the_staged_system_is_accepted(self) -> None:
        (self.fixture.app / "andarium-system/release-manifest.json").write_text(
            json.dumps(self.fixture.proof_manifest()))
        result = self.fixture.run(decision=RELEASE_ID)
        self.fails(result, "the packaged system", "an unsigned proof image")
        self.assertNotIn("the staged system", result.stderr)

    def test_a_manifest_that_is_not_marked_accepted_fails(self) -> None:
        for acceptance in ("candidate", None):
            with self.subTest(acceptance):
                manifest = self.fixture.manifest()
                if acceptance is None:
                    del manifest["acceptance"]
                else:
                    manifest["acceptance"] = acceptance
                (self.repo / ".build/andarium-system/release-manifest.json").write_text(json.dumps(manifest))
                self.fails(self.fixture.run(app=False, decision=RELEASE_ID),
                           "not an accepted release", f"acceptance {acceptance!r}")

    def test_an_accepted_manifest_over_another_disk_fails_staged_and_packaged(self) -> None:
        # A mixed staging directory: the accepted release's manifest and input
        # trees, another system disk (a proof's) and a layout that names it.
        proof_disk = b"another system disk" * 100
        self.fixture.stage(disk=proof_disk)
        for app in (False, True):
            if app:
                self.fixture.app = self.fixture.package()
            result = self.fixture.run(app=app, decision=RELEASE_ID)
            self.fails(result, "the system disk of the staged system", "not the accepted release's")
        # The staged system is the accepted one and the packaged one is not.
        self.fixture.stage()
        self.fixture.app = self.fixture.package()
        (self.fixture.app / "andarium-system/guest/system.img").write_bytes(proof_disk)
        (self.fixture.app / "andarium-system/guest/partition-layout.json").write_text(
            json.dumps(self.fixture.layout(proof_disk)))
        self.fails(self.fixture.run(decision=RELEASE_ID), "guest/partition-layout.json is not the staged one")
        # Both, with a layout that agrees with its disk, as a repackaging would leave them.
        self.fixture.stage(disk=proof_disk)
        self.fixture.app = self.fixture.package()
        self.fails(self.fixture.run(decision=RELEASE_ID), "the system disk of the staged system")
        self.fixture.stage()
        self.fixture.app = self.fixture.package()
        self.passes(self.fixture.run())

    def test_the_accepted_release_must_be_installed_to_tie_the_disk_to_it(self) -> None:
        shutil.rmtree(self.repo / ".build/android/releases")
        for app in (False, True):
            result = self.fixture.run(app=app, decision=RELEASE_ID)
            self.fails(result, "is not installed here", "install-release.py")
        # What is installed under the accepted directory name must be the accepted release.
        installed = self.fixture.install()
        write(installed, "release-manifest.json", json.dumps(self.fixture.manifest("20260101-los24-r1")))
        self.fails(self.fixture.run(app=False), "is not the accepted " + RELEASE_ID)
        manifest = self.fixture.manifest()
        manifest["acceptance"] = "unsigned-proof"
        write(installed, "release-manifest.json", json.dumps(manifest))
        self.fails(self.fixture.run(app=False), "not marked accepted")
        self.fixture.install()
        self.passes(self.fixture.run())

    def test_an_installed_layout_without_a_usable_digest_is_an_error_not_a_skipped_check(self) -> None:
        installed = self.fixture.install()
        layout = installed / "guest/partition-layout.json"
        digest = json.loads(layout.read_text())["system_disk"]["sha256"]
        self.assertNotEqual(digest, digest.upper())
        unusable = "names no usable system disk digest"
        cases = {
            "null": ({"system_disk": {"sha256": None}}, unusable),
            "empty": ({"system_disk": {"sha256": ""}}, unusable),
            "short": ({"system_disk": {"sha256": digest[:63]}}, unusable),
            "long": ({"system_disk": {"sha256": digest + "0"}}, unusable),
            "uppercase": ({"system_disk": {"sha256": digest.upper()}}, unusable),
            "not hexadecimal": ({"system_disk": {"sha256": "g" * 64}}, unusable),
            "number": ({"system_disk": {"sha256": 12}}, unusable),
            "list": ({"system_disk": {"sha256": [digest]}}, unusable),
            "no digest": ({"system_disk": {}}, "is not installed here"),
            "no system disk": ({"schema_version": 2}, "is not installed here"),
            "system disk null": ({"system_disk": None}, "is not installed here"),
        }
        for label, (content, needle) in cases.items():
            layout.write_text(json.dumps(content))
            for app in (False, True):
                with self.subTest(label, app=app):
                    self.fails(self.fixture.run(app=app, decision=RELEASE_ID), needle)
        # A usable digest checks again, whatever the staged disk says.
        self.fixture.install()
        self.passes(self.fixture.run())

    def test_a_descriptor_without_a_directory_name_fails(self) -> None:
        text = (self.repo / DESCRIPTOR).read_text()
        write(self.repo, DESCRIPTOR, "".join(line for line in text.splitlines(True) if "DIRECTORY_NAME" not in line))
        commit(self.repo, "drop the directory name")
        self.fails(self.fixture.run(app=False), "names no release directory")

    def test_a_repeated_json_key_in_a_manifest_or_a_layout_is_refused(self) -> None:
        staged = self.repo / ".build/andarium-system"
        manifest = (staged / "release-manifest.json").read_text()
        layout = (staged / "guest/partition-layout.json").read_text()
        installed = self.repo / ".build/android/releases" / f"lineage24-mainline6.18-4k-{RELEASE_ID}"
        cases = (
            (staged / "release-manifest.json", manifest, manifest[:-1] + ', "acceptance": "unsigned-proof"}',
             "repeats the key acceptance"),
            (staged / "guest/partition-layout.json", layout, layout[:-1] + ', "schema_version": 1}',
             "repeats the key schema_version"),
            (installed / "release-manifest.json", manifest, manifest[:-1] + ', "release_id": "x"}',
             "repeats the key release_id"),
        )
        for path, original, doubled, message in cases:
            with self.subTest(path.name):
                path.write_text(doubled)
                result = self.fixture.run(app=False, decision=RELEASE_ID)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                path.write_text(original)
        # The packaged copies too, which must also equal the staged ones.
        self.fixture.app = self.fixture.package()
        packaged = self.fixture.app / "andarium-system/guest/partition-layout.json"
        (staged / "guest/partition-layout.json").write_text(layout[:-1] + ', "schema_version": 2}')
        packaged.write_text(layout[:-1] + ', "schema_version": 2}')
        self.fails(self.fixture.run(decision=RELEASE_ID), "repeats the key schema_version")
        (staged / "guest/partition-layout.json").write_text(layout)
        packaged.write_text(layout)
        self.passes(self.fixture.run())

    def test_a_missing_staged_system_fails(self) -> None:
        shutil.rmtree(self.repo / ".build/andarium-system")
        self.fails(self.fixture.run(app=False), "no release-manifest.json")

    def test_a_packaged_release_that_is_not_the_staged_one_fails(self) -> None:
        (self.fixture.app / "andarium-system/release-manifest.json").write_text(
            json.dumps(self.fixture.manifest("20260101-los24-r1")))
        self.fails(self.fixture.run(decision=RELEASE_ID), "packaged system", "20260101-los24-r1")

    def test_a_packaged_system_disk_that_differs_from_its_layout_fails(self) -> None:
        (self.fixture.app / "andarium-system/guest/system.img").write_bytes(b"other bytes")
        self.fails(self.fixture.run(decision=RELEASE_ID), "packaged system disk")

    def test_a_descriptor_without_trees_is_unverifiable_and_a_decision_names_its_id(self) -> None:
        self.fixture.set_descriptors(schema=6)
        self.fixture.stage()
        self.fixture.app = self.fixture.package()
        self.fails(self.fixture.run(), "records no input trees", "cannot be checked")
        wrong = self.fixture.run(decision="20260101-los24-r1")
        self.fails(wrong, "records no input trees", "names 20260101-los24-r1, which has no pending change")
        right = self.fixture.run(decision=RELEASE_ID)
        self.passes(right)
        self.assertIn("warning:", right.stderr)
        self.assertIn("the archive will not carry it", right.stderr)

    def test_a_decision_covers_one_artifact_and_by_exact_id(self) -> None:
        write(self.repo, "android/lineage-24/tools/publish-release.py", "# changed\n")
        commit(self.repo, "publish: write another field")
        for decision in (RELEASE_ID + "x", "x" + RELEASE_ID, RELEASE_ID[:-1], "", KERNEL_ID):
            self.fails(self.fixture.run(decision=decision), "publish-release.py changed")
        for decision in (RELEASE_ID, f"{KERNEL_ID},{RELEASE_ID}", f"  {RELEASE_ID}\t{KERNEL_ID} "):
            result = self.fixture.run(decision=decision)
            self.passes(result)
            self.assertIn("publish: write another field", result.stderr)
        # The build setting spelling is the flag's.
        self.passes(self.fixture.run("--decision", RELEASE_ID))

    def test_a_decision_for_a_release_does_not_cover_the_next_one(self) -> None:
        write(self.repo, "android/lineage-24/overlay/product.mk", "PRODUCT=2\n")
        commit(self.repo, "overlay: change")
        self.fails(self.fixture.run(decision=RELEASE_ID[:-2] + "98"), "overlay changed")
        self.passes(self.fixture.run(decision=RELEASE_ID))
        # The next release, accepted from a build that missed the change, is a
        # different artifact: the decision about the earlier ID covers nothing.
        later = "20261202-los24-r100"
        self.fixture.set_descriptors(release_id=later)
        self.fixture.stage(later)
        self.fixture.app = self.fixture.package()
        result = self.fixture.run(decision=RELEASE_ID)
        self.fails(result, later, "overlay changed", f"names {RELEASE_ID}, which has no pending change")
        self.passes(self.fixture.run(decision=later))

    def test_the_list_changing_is_reported(self) -> None:
        write(self.repo, LIST, "# list\n" + INPUTS.replace(
            "excluded\tandroid/lineage-24/README.md\tdocumentation", "input\tandroid/lineage-24/README.md\tnow an input"))
        commit(self.repo, "list: README becomes an input")
        self.fails(self.fixture.run(), "android/lineage-24/README.md is an input now")
        write(self.repo, LIST, "# list\n" + INPUTS.replace("input\tandroid/lineage-24/overlay\tthe product tree\n", ""))
        commit(self.repo, "list: overlay is no longer an input")
        self.fails(self.fixture.run(), "android/lineage-24/overlay is no longer an input")

    def test_a_removed_input_is_reported(self) -> None:
        git(self.repo, "rm", "-q", "-r", "android/lineage-24/overlay")
        commit(self.repo, "overlay: remove")
        self.fails(self.fixture.run(), "android/lineage-24/overlay was removed")

    def test_a_recorded_tree_that_is_in_no_history_is_said_so(self) -> None:
        self.fixture.set_descriptors(trees={**self.fixture.trees, "android/lineage-24/overlay": "e" * 40})
        self.fixture.stage(trees={**self.fixture.trees, "android/lineage-24/overlay": "e" * 40})
        self.fixture.app = self.fixture.package()
        self.fails(self.fixture.run(), "android/lineage-24/overlay changed", "is not in the last")

    def test_a_directory_that_is_not_a_work_tree_fails(self) -> None:
        plain = self.root / "plain"
        plain.mkdir()
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--repository", str(plain), "--android-release"],
            capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL, timeout=60)
        self.fails(result, "not a Git work tree")

    def test_a_kernel_behind_its_series_names_the_changed_paths(self) -> None:
        write(self.repo, "kernel/common/patches/0002-three.patch", "three\n")
        write(self.repo, METADATA, f"UML_KERNEL_FINAL_TREE='{OTHER_TREE}'\n")
        commit(self.repo, "kernel: add a shared topic")
        result = self.fixture.run()
        self.fails(
            result, KERNEL_ID, "behind its patch series", METADATA, "0002-three.patch",
            "kernel: add a shared topic")
        self.assertEqual(self.fixture.run(decision=RELEASE_ID).returncode, 1)
        self.passes(self.fixture.run(decision=KERNEL_ID))
        self.assertIn("kernel: add a shared topic", self.fixture.run(decision=KERNEL_ID).stderr)

    def test_a_kernel_tree_missing_from_the_history_is_said_so(self) -> None:
        self.fixture.set_descriptors(kernel_tree="f" * 40)
        self.fails(self.fixture.run(app=False), "behind its patch series", "is not in the last")

    def test_a_packaged_kernel_that_is_not_the_accepted_one_fails_whatever_the_decision(self) -> None:
        self.fixture.app = self.fixture.package(release="6.18.98-gdeadbeef0000")
        self.fails(
            self.fixture.run(decision=f"{RELEASE_ID} {KERNEL_ID}"),
            "6.18.98-gdeadbeef0000", KERNEL_RELEASE, "package the frameworks")

    def test_a_packaged_kernel_built_as_another_user_or_host_fails_whatever_the_decision(self) -> None:
        # The build user and host are personal values: the verdict says that
        # the pair is wrong and never repeats it.
        cases = {
            "banner user": {"builder": "qzxuser@kernarium"},
            "banner host": {"builder": "kernarium@qzxhost"},
            "banner pair": {"builder": "qzxuser@qzxhost"},
            "proc format": {"proc_builder": "qzxuser@qzxhost"},
        }
        for label, builders in cases.items():
            with self.subTest(label):
                self.fixture.app = self.fixture.package(**builders)
                result = self.fixture.run(decision=f"{RELEASE_ID} {KERNEL_ID}")
                self.fails(result, NEUTRAL_BUILDER, "build-kernel.sh")
                self.assertNotIn("qzx", result.stdout + result.stderr)

    def test_a_missing_runtime_framework_fails(self) -> None:
        shutil.rmtree(self.fixture.app / "Frameworks")
        self.fails(self.fixture.run(decision=KERNEL_ID), f"embeds no {FRAMEWORK}")

    def test_a_packaged_kernel_configuration_behind_its_fragments_is_pending(self) -> None:
        stale = CONFIG.replace("CONFIG_BINDER=y", "# CONFIG_BINDER is not set")
        self.fixture.app = self.fixture.package(config=stale)
        write(self.repo, "kernel/mainline-6.18/config/android.fragment", "CONFIG_BINDER=y\n# CONFIG_NFS_FS is not set\nCONFIG_HZ=250\n")
        commit(self.repo, "config: tick at 250 Hz")
        result = self.fixture.run()
        self.fails(
            result, "configuration is behind its fragments", "CONFIG_BINDER", "CONFIG_HZ: ",
            "requests 250", "config: tick at 250 Hz")
        self.passes(self.fixture.run(decision=KERNEL_ID))

    def test_a_required_or_forbidden_symbol_of_the_product_is_checked(self) -> None:
        write(self.repo, "kernel/mainline-6.18/config/android-required-builtins.txt", "CONFIG_BINDER\nCONFIG_NEWLY_REQUIRED\n")
        write(self.repo, "kernel/mainline-6.18/config/android-forbidden-options.txt", "CONFIG_NFS_FS\nCONFIG_UML\n")
        commit(self.repo, "policy: a new required builtin")
        self.fails(self.fixture.run(), "CONFIG_NEWLY_REQUIRED", "CONFIG_UML")

    def test_the_last_fragment_that_names_a_symbol_owns_it(self) -> None:
        write(self.repo, "kernel/mainline-6.18/config/android.fragment", "CONFIG_MODULES=y\nCONFIG_BINDER=y\n# CONFIG_NFS_FS is not set\n")
        commit(self.repo, "config: product overrides the shared policy")
        self.fails(self.fixture.run(), "CONFIG_MODULES", "android.fragment requests y")

    def test_a_kernel_without_a_configuration_fails(self) -> None:
        image = b"\x7fELF" + f"Linux version {KERNEL_RELEASE} ({NEUTRAL_BUILDER}) #1\n".encode()
        (self.fixture.app / "Frameworks" / f"{FRAMEWORK}.framework" / FRAMEWORK).write_bytes(
            macho({"__uml_elf": image}))
        self.fails(self.fixture.run(decision=KERNEL_ID), "carries no configuration")

    def test_a_runtime_without_a_kernel_image_fails(self) -> None:
        (self.fixture.app / "Frameworks" / f"{FRAMEWORK}.framework" / FRAMEWORK).write_bytes(
            macho({"__other": b"x"}))
        self.fails(self.fixture.run(decision=KERNEL_ID), "carries no __uml_elf")

    def test_naming_no_artifact_is_refused(self) -> None:
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--repository", str(self.repo)],
            capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(result.returncode, 2)


class ConfigParityTests(unittest.TestCase):
    """The symbol check agrees with the kernel build's own (config-fragments.sh)."""

    CASES = (
        ("all symbols match", ["CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_N=4096\nCONFIG_S=\"x\"\n"],
         "CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_N=4096\nCONFIG_S=\"x\"\n"),
        ("a requested symbol is absent", ["CONFIG_A=y\n"], "CONFIG_Z=y\n"),
        ("a disabled symbol is absent", ["# CONFIG_B is not set\n"], "CONFIG_Z=y\n"),
        ("a disabled symbol is enabled", ["# CONFIG_B is not set\n"], "CONFIG_B=y\n"),
        ("the last fragment owns a symbol", ["CONFIG_A=y\n", "# CONFIG_A is not set\n"], "# CONFIG_A is not set\n"),
        ("the last fragment loses to the build", ["# CONFIG_A is not set\n", "CONFIG_A=y\n"], "# CONFIG_A is not set\n"),
        ("a value differs", ["CONFIG_N=4096\n"], "CONFIG_N=1024\n"),
        ("a string differs", ["CONFIG_S=\"x\"\n"], "CONFIG_S=\"y\"\n"),
        ("comments and blanks are ignored", ["# a comment\n\nCONFIG_A=y\n"], "CONFIG_A=y\n"),
    )

    def test_verdicts_agree(self) -> None:
        spec = importlib.util.spec_from_file_location("check_embedded_artifacts", SCRIPT)
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        helper = REPOSITORY / "kernel/common/tooling/config-fragments.sh"
        for label, fragments, config in self.CASES:
            with self.subTest(label), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                names = []
                for index, text in enumerate(fragments):
                    write(root, f"f{index}.fragment", text)
                    names.append(f"f{index}.fragment")
                write(root, "config", config)
                shell = subprocess.run(
                    ["sh", "-c", f". {helper}; uml_kernel_config_verify \"$@\"", "sh", str(root / "config"),
                     *[str(root / name) for name in names]],
                    capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL)
                problems = checker.config_mismatches(root, {"fragments": names}, config)
                self.assertEqual(shell.returncode == 0, not problems, (shell.stderr, problems))


PROJECT = REPOSITORY / "Andarium/Andarium.xcodeproj/project.xcproj"


def build_phase(name: str) -> dict:
    """The named script phase of the Andarium project (the format is JSON with trailing commas)."""
    project = json.loads(re.sub(r",(\s*[}\]])", r"\1", PROJECT.read_text(encoding="utf-8")))
    found = []

    def walk(value) -> None:
        if isinstance(value, dict):
            if value.get("kind") == "script" and value.get("name") == name:
                found.append(value)
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(project)
    if len(found) != 1:
        raise AssertionError(f"expected one build phase named {name}, found {len(found)}")
    return found[0]


class BuildPhaseTests(unittest.TestCase):
    """The AppStore and TestFlight configurations run the check; the others do not."""

    CONFIGURATIONS = ("Debug", "Release", "AppStore", "TestFlight")

    def setUp(self) -> None:
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        script = build_phase("Check embedded artifacts")["script"]
        self.script = script if isinstance(script, str) else "\n".join(script)

    def run_phase(self, configuration: str, fixture: Fixture):
        # The phase's own text, with the checker named by path and the
        # repository the fixture's, as an archive's work tree is.
        command = self.script.replace(
            '"$SRCROOT/../scripts/check-embedded-artifacts.py"',
            f'"{SCRIPT}" --repository "{fixture.repo}"')
        self.assertIn(str(SCRIPT), command)
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "CONFIGURATION": configuration,
            "SRCROOT": str(REPOSITORY / "Andarium"), "TARGET_BUILD_DIR": str(fixture.app.parent),
            "WRAPPER_NAME": fixture.app.name,
        }
        return subprocess.run(
            ["/bin/sh", "-c", command], env=environment, check=False, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=120)

    def test_the_phase_checks_the_app_for_the_accepted_release_and_kernel(self) -> None:
        self.assertIn("--app", self.script)
        self.assertIn("--android-release", self.script)
        self.assertIn("--kernel android", self.script)

    def test_a_staged_unsigned_proof_stops_an_appstore_and_a_testflight_build_only(self) -> None:
        fixture = Fixture(self.root)
        staged = fixture.stage()
        (staged / "release-manifest.json").write_text(json.dumps(fixture.proof_manifest()))
        fixture.app = fixture.package()
        self.assert_only_release_builds_refuse(fixture)

    def test_a_proof_the_staging_script_stages_stops_the_same_builds(self) -> None:
        # The staging script's own output, not a manifest written to look like it.
        import test_stage_system_image as staging

        fixture = Fixture(self.root)
        shutil.rmtree(fixture.repo / ".build/andarium-system")
        proof = staging.make_proof(self.root / "proofs")
        checkout = staging.make_checkout(self.root / "checkout")
        result = staging.run_script(
            checkout.script, "--release", str(proof), "--unsigned-proof",
            "--output", str(fixture.repo / ".build/andarium-system"))
        self.assertEqual(result.returncode, 0, result.stderr)
        fixture.app = fixture.package()
        self.assert_only_release_builds_refuse(fixture)

    def assert_only_release_builds_refuse(self, fixture: Fixture) -> None:
        for configuration in self.CONFIGURATIONS:
            with self.subTest(configuration):
                result = self.run_phase(configuration, fixture)
                if configuration in ("AppStore", "TestFlight"):
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("an unsigned proof image", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, "")

    def test_the_accepted_release_passes_the_phase_in_every_configuration(self) -> None:
        fixture = Fixture(self.root)
        for configuration in self.CONFIGURATIONS:
            with self.subTest(configuration):
                result = self.run_phase(configuration, fixture)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
