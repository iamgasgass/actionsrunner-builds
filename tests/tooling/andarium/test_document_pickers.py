#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that the App Store configuration keeps the document pickers in place.

Andarium's two document pickers (Install APK in Shared/Settings.swift and the
file browser's Import in Shared/FileBrowserBar.swift) open the files in place
with SwiftUI's fileImporter in the App Store configuration, and present the
copy-mode picker (Shared/CopyDocumentPicker.swift) in every other
(Andarium/README.md#configurations). This reads the sources as the compiler
does with APP_STORE set and not set, and fails when the condition is taken
away, turned round or put anywhere else. It also reads every other source of
the application: an in-place importer (SwiftUI's fileImporter, or the system
picker in open mode without a copy) is either in the App Store branch of a
split or named in PERMITTED_IN_PLACE_IMPORTERS with its reason. The bundle
check (Andarium/scripts/check-app-store-bundle.py) says the same of a built
application; its names for the presenter are held to the sources here.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import importlib.util
import re
import sys
from pathlib import Path

SHARED = Path("Andarium/Andarium/Shared")
CALL_SITES = ("Settings.swift", "FileBrowserBar.swift")
PRESENTER = "CopyDocumentPicker.swift"
# What only the copy-mode presenter may mention, in the App Store view of any
# file of the application.
PRESENTER_NAMES = ("CopyDocumentPicker", "documentCopyPicker", "PickedCopies", "asCopy: true")

# The production sources that may hold an in-place importer in a configuration
# other than the App Store's, besides the two call sites (whose own split is
# checked below): path from the repository root -> why it is meant. A source
# that adds an in-place importer on purpose names it here, and the entry must
# keep matching one.
PERMITTED_IN_PLACE_IMPORTERS: dict[str, str] = {
    "Andarium/Andarium/Shared/Feedback/SendFeedbackFilePicker.swift":
        "Send feedback attaches a picked file where it is kept (a file of any size is mapped for the mail, "
        "never copied first), in every configuration that has the feature",
}

SWIFTUI_IMPORTER = re.compile(r"\bfileImporter\s*\(")
UIKIT_PICKER = re.compile(r"\bUIDocumentPickerViewController\s*\(")

CONDITION = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def active(text: str, app_store: bool) -> list[str]:
    """The lines the compiler sees when APP_STORE is `app_store`. A condition
    on anything else (FEEDBACK_MAIL, FOLLOW_X) is taken as holding, so that
    code under it is judged by APP_STORE alone."""
    stack: list[tuple[bool, bool]] = []  # (this branch is on, a branch of this #if was on)
    lines = []
    for line in text.splitlines():
        match = CONDITION.match(line)
        if match is None:
            if all(on for on, _taken in stack):
                lines.append(line)
            continue
        word, rest = match.group(1), match.group(2).split("//")[0].strip()
        if word == "if":
            on = evaluate(rest, app_store)
            stack.append((on, on))
        elif word == "elseif":
            _on, taken = stack.pop()
            on = not taken and evaluate(rest, app_store)
            stack.append((on, taken or on))
        elif word == "else":
            _on, taken = stack.pop()
            stack.append((not taken, True))
        else:
            stack.pop()
    if stack:
        raise ValueError("an #if without its #endif")
    return lines


def evaluate(condition: str, app_store: bool) -> bool:
    if condition == "APP_STORE":
        return app_store
    if condition == "!APP_STORE":
        return not app_store
    return True


def code(lines: list[str]) -> list[str]:
    """The lines that are code: no blank line and no comment."""
    return [line for line in lines if line.strip() and not line.strip().startswith("//")]


def count(lines: list[str], needle: str) -> int:
    return sum(line.count(needle) for line in code(lines))


def code_text(lines: list[str]) -> str:
    """The code of `lines` as one text, a trailing comment taken off each."""
    return "\n".join(line.split("//")[0] for line in code(lines))


def call_arguments(text: str, start: int) -> str:
    """What is between the parentheses of the call whose opening one is at
    `start`; the rest of the text when they never close."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:index]
    return text[start + 1:]


def in_place_importers(lines: list[str]) -> list[str]:
    """The in-place importers in `lines`: SwiftUI's fileImporter, and the
    system picker made to open files that is not made to copy them (an export,
    and a picker with asCopy true, are no in-place importer)."""
    text = code_text(lines)
    found = [f"fileImporter at offset {match.start()}" for match in SWIFTUI_IMPORTER.finditer(text)]
    for match in UIKIT_PICKER.finditer(text):
        arguments = " ".join(call_arguments(text, match.end() - 1).split())
        if not arguments.startswith("forExporting") and "asCopy: true" not in arguments:
            found.append(f"UIDocumentPickerViewController at offset {match.start()}")
    return found


def problems(
    call_sites: dict[str, str], presenter: str, others: dict[str, str],
    permitted: dict[str, str] = PERMITTED_IN_PLACE_IMPORTERS,
) -> list[str]:
    """What is wrong with the pickers of these sources: `call_sites` are the two
    files that present one, `presenter` is the copy-mode file and `others` the
    other files of the application. `permitted` names the files of `others`
    that may hold an in-place importer outside the App Store branch."""
    found = []
    for name, text in call_sites.items():
        in_store, elsewhere = active(text, True), active(text, False)
        if count(in_store, ".fileImporter(") != 1:
            found.append(f"{name}: the App Store configuration must open the files in place, "
                         f"with one fileImporter (found {count(in_store, '.fileImporter(')})")
        if in_place_importers(elsewhere):
            found.append(f"{name}: a configuration other than the App Store's holds an in-place importer")
        if count(elsewhere, ".documentCopyPicker(") != 1:
            found.append(f"{name}: every other configuration must present the copy-mode picker, once "
                         f"(found {count(elsewhere, '.documentCopyPicker(')})")
        for needle in PRESENTER_NAMES:
            if count(in_store, needle):
                found.append(f"{name}: the App Store configuration mentions {needle}")
    if code(active(presenter, True)):
        found.append(f"{PRESENTER}: the copy-mode presenter has code in the App Store configuration")
    if not code(active(presenter, False)):
        found.append(f"{PRESENTER}: the copy-mode presenter is empty in the other configurations")
    if in_place_importers(active(presenter, False)):
        found.append(f"{PRESENTER}: the copy-mode presenter holds an in-place importer")
    for name, text in others.items():
        for needle in PRESENTER_NAMES:
            if count(active(text, True), needle):
                found.append(f"{name}: the App Store configuration mentions {needle}")
        # Every other production source: an in-place importer is inside the
        # App Store branch of a split, or named as a permitted exception.
        if in_place_importers(active(text, False)) and name not in permitted:
            found.append(f"{name}: an in-place importer outside the App Store branch of a split "
                         f"(a source that means it names itself in PERMITTED_IN_PLACE_IMPORTERS)")
    for name in permitted:
        if name not in others:
            found.append(f"PERMITTED_IN_PLACE_IMPORTERS names {name}, which is no production source")
        elif not in_place_importers(active(others[name], False)):
            found.append(f"PERMITTED_IN_PLACE_IMPORTERS names {name}, which holds no in-place importer")
    return found


def load_checker(path: Path):
    spec = importlib.util.spec_from_file_location("check_app_store_bundle", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # The checker's dataclasses look their module up by name.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def fragment_problems(checker, presenter: str) -> list[str]:
    """The bundle check looks for the presenter by mangled names: each must be a
    name of the presenter's file as Swift writes it, its length first."""
    found = []
    for fragment in checker.PICKER_COPY:
        match = re.fullmatch(rb"(\d+)([A-Za-z_][A-Za-z0-9_]*)", fragment)
        if match is None or int(match.group(1)) != len(match.group(2)):
            found.append(f"the bundle check's fragment {fragment!r} is not a Swift name with its length")
        elif match.group(2).decode() not in presenter:
            found.append(f"the bundle check looks for {match.group(2).decode()}, which the presenter does not define")
    for name, fragment in checker.PICKER_IN_PLACE.items():
        if b"12fileImporter11isPresented19allowedContentTypes" not in fragment:
            found.append(f"the bundle check's fragment for {name} is not SwiftUI's fileImporter")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True, help="the repository")
    options = parser.parse_args()
    root: Path = options.root

    shared = root / SHARED
    call_sites = {name: (shared / name).read_text(encoding="utf-8") for name in CALL_SITES}
    presenter = (shared / PRESENTER).read_text(encoding="utf-8")
    others = {
        str(path.relative_to(root)): path.read_text(encoding="utf-8")
        for path in sorted((root / "Andarium/Andarium").rglob("*.swift"))
        if not (path.parent == shared and path.name in (*CALL_SITES, PRESENTER))
    }
    failures = [f"the sources: {line}" for line in problems(call_sites, presenter, others)]
    checker = load_checker(root / "Andarium/scripts/check-app-store-bundle.py")
    failures.extend(fragment_problems(checker, presenter))

    # The check finds what a later edit could do to the condition: each change
    # below must fail it.
    stray = "        .fileImporter(isPresented: .constant(false), allowedContentTypes: [.item]) { _ in }\n"
    for site, text in call_sites.items():
        mutations = {
            "the condition taken away": text.replace("#if APP_STORE", "#if true", 1),
            "the branches turned round": text.replace("#if APP_STORE", "#if !APP_STORE", 1),
            "an importer in every build": text.replace("#if APP_STORE", stray + "#if APP_STORE", 1),
        }
        for label, mutated in mutations.items():
            if mutated == text:
                failures.append(f"{site}: the check's change '{label}' changed nothing")
            elif not problems({**call_sites, site: mutated}, presenter, others):
                failures.append(f"{site}: {label} passed the check")
    # A presenter outside its condition, and a mention of it elsewhere.
    if not problems(call_sites, presenter.replace("#if !APP_STORE", "#if true", 1), others):
        failures.append(f"{PRESENTER}: a presenter outside the condition passed the check")
    if not problems(call_sites, presenter, {**others, "Elsewhere.swift": "let picker = CopyDocumentPicker()\n"}):
        failures.append("a mention of the presenter outside the condition passed the check")

    # Every other source: a third importer, in every configuration or outside
    # the App Store branch, fails; one inside the App Store branch, or named as
    # an exception, does not; an exception that matches nothing fails.
    third = "Andarium/Andarium/Shared/Third.swift"
    importer = "Color.clear.fileImporter(\n            isPresented: .constant(false), allowedContentTypes: [.item]) { _ in }"
    body = "struct Third: View {\n    var body: some View {\n        %s\n    }\n}\n"
    unconditional = body % importer
    in_store = body % f"#if APP_STORE\n        {importer}\n        #else\n        Color.clear\n        #endif"
    outside = body % f"#if !APP_STORE\n        {importer}\n        #else\n        Color.clear\n        #endif"
    uikit = "let picker = UIDocumentPickerViewController(\n    forOpeningContentTypes: [.item], asCopy: false)\n"
    exporter = "let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: false)\n"
    third_cases = {
        "a third unconditional importer": (unconditional, {}, True),
        "a third importer outside the App Store branch": (outside, {}, True),
        "a third in-place system picker": (uikit, {}, True),
        "a third importer named as an exception": (unconditional, {third: "meant"}, False),
        "a third importer in the App Store branch": (in_store, {}, False),
        "an export that is no importer": (exporter, {}, False),
        "an exception for a source with no importer": (exporter, {third: "meant"}, True),
    }
    for label, (text, permitted, must_fail) in third_cases.items():
        found = problems(call_sites, presenter, {**others, third: text}, {**PERMITTED_IN_PLACE_IMPORTERS, **permitted})
        if must_fail and not found:
            failures.append(f"{label} passed the check")
        elif not must_fail and found:
            failures.append(f"{label} failed the check: {found}")
    if problems(call_sites, presenter, others, {**PERMITTED_IN_PLACE_IMPORTERS, third: "meant"}) == []:
        failures.append("an exception that names no source passed the check")

    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
