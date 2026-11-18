#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Qualify an Android release's text-message service: its host-only channel and its delivery record.

The guest is the release on a fresh data disk (or on the instance named by --instance), started with the macOS
launcher and ``--vsock-forward=127.0.0.1:0-5560``, so that the runner plays the host application: it sends the
requests of the contract over the forward, in frames. The contract is android/lineage-24/README.md ("Text
messages"); the bytes are tests/unit/andarium/fixtures/sms-golden-frames.txt, which this runner reads, and the
service is android/lineage-24/overlay/sms. The runner has three modes, each one boot:

- ``channel`` (a release image, no root): the channel's rows. G1 a host's request is taken, handed over,
  and answered; G2a-d the provider is gone and a guest-local or adb-made connection is refused or ends at once;
  G3 the service restarts after a crash and no answer is wrong; G4 its domain, its life and its denials, with the
  boot order (H7) and the record's location and label (H11); G5 the memory cost; G6 every vsock listener of the
  guest and its owner, and no virtual machine (H10, H13); G8 an application's domain and the shell cannot create
  a vsock socket; G9 the shell cannot move adbd's listener; H6 adbd's reverse forward on vsock as the stock image
  has it; H9 the kernel's vsock configuration. G2e (a reverse forward onto vsock, and onto ``acceptfd:``) needs
  the adbd topic of the AOSP patches, and G7 (the development launch) is not a gate: each is opt-in.
- ``record`` (a release image): the record's rows over this channel. I1 a process ended between sends, I2 a
  reboot, I4 fifty first attempts with a crash fired at a varying time, I5 the answers' bytes, I7 an image with
  no SMS provider, I8 payloads that are not version 2.
- ``proof`` (a userdebug proof build: it needs ``su``): I3 a pending record left by an ended process, and I6 the
  record's storage (its files, its size at 300 sends and, where strace exists, the order of its writes).

Each row is reported on its own, so that one boot shows every difference; the verdict is the worst. The rows that
need something the run lacks are listed with the reason. Every wait has a deadline. The guest's launcher is
stopped through its own process on any exit, and the guest is reached through the shared adb server, always named
with ``-s``.

The runner is opt-in: it needs the macos-android17 executable, an installed release, an adb client and, for the
channel mode, the probe's APK and DEX (tests/integration/android/sms/build-apk.sh).
usage: run_android_sms.py --emulator uml-darwin-android17 --mode channel --probe-apk AndariumSmsProbe.apk
           --vsockprobe-dex vsockprobe.dex [--release DIR] [--variant messaging|no-messaging|no-provider]
       run_android_sms.py --list-rows
"""

from __future__ import annotations
# Standalone runners must not leave source-adjacent bytecode caches.
__import__("sys").dont_write_bytecode = True

import argparse
import base64
import concurrent.futures
import hashlib
import importlib.util
import os
import pathlib
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from collections.abc import Callable
from dataclasses import dataclass

HERE = pathlib.Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
sys.path.insert(0, str(REPOSITORY / "tests" / "integration" / "support"))
import slot_ports  # noqa: E402

SPEC = importlib.util.spec_from_file_location("boot_android", REPOSITORY / "tools" / "boot_android.py")
assert SPEC is not None and SPEC.loader is not None
boot_android = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boot_android)

GOLDEN = REPOSITORY / "tests" / "unit" / "andarium" / "fixtures" / "sms-golden-frames.txt"
DEFAULT_ADB_PORT = 5578
SMS_PORT = 5560
PACKAGE = "android.kernarium.sms"
PROBE_PACKAGE = "org.example.andarium.smsprobe"
TAG = "AndariumSms"
RECORD_DIRECTORY = "/data/user_de/0/android.kernarium.sms/files"
RECORD_LABEL = "u:object_r:kernarium_sms_data_file:s0"
FORWARD = re.compile(r"vsock forward (\S+):(\d+) -> guest port (\d+)")
FORWARD_SECONDS = 60
COMMAND_SECONDS = 120
SETTLE_SECONDS = 60
ANSWER_SECONDS = 30
REFUSAL_SECONDS = 5
RESTART_SECONDS = 30
REBOOT_SECONDS = 300
INBOX_SECONDS = 20
PROBE_SECONDS = 30
VM_SECONDS = 60
SWEEP_PORT_SECONDS = 2
SWEEP_SECONDS = 1800
SWEEP_WIDTH = 16
# The shared adb server's port: the sweep speaks its protocol to ask adbd for a connection.
ADB_SERVER_PORT = 5037

# ---- The wire: frames, requests and answers (HostFrame, Message and Answer of the service).

FRAME_MAGIC = b"KSMS"
FRAME_VERSION = 1
MAXIMUM_REQUEST = 8192
MAXIMUM_ANSWER = 4096
MAXIMUM_UNITS = 670
# The record's size at its capacity: the header, 256 lines of 103 bytes and the trailer.
MAXIMUM_RECORD_BYTES = 26404
RECORD_CAPACITY = 256
RECORD_HEADER = "kernarium-sms-record 1"


class Failure(RuntimeError):
    pass


def frame(payload: bytes) -> bytes:
    """A payload in its frame: the magic, the frame version and the payload's length as u16 little endian."""
    if len(payload) > 0xFFFF:
        raise ValueError("a payload does not fit a frame")
    return FRAME_MAGIC + struct.pack("<HH", FRAME_VERSION, len(payload)) + payload


def frame_length(header: bytes) -> int | None:
    """The payload length that an answer's header announces, or None when the header is not an answer's."""
    if len(header) != 8 or header[:4] != FRAME_MAGIC:
        return None
    version, length = struct.unpack("<HH", header[4:])
    if version != FRAME_VERSION or length > MAXIMUM_ANSWER:
        return None
    return length


def encode_field(text: str | bytes) -> str:
    raw = text.encode("utf-8") if isinstance(text, str) else text
    return base64.b64encode(raw).decode("ascii")


def request(attempt: str, identifier: str, sender: str | bytes, text: str | bytes) -> bytes:
    """``2.<first|retry>.<identifier>.<sender64>.<text64>``."""
    if attempt not in ("first", "retry"):
        raise ValueError(attempt)
    return f"2.{attempt}.{identifier}.{encode_field(sender)}.{encode_field(text)}".encode("ascii")


def new_identifier(seed: int | None = None) -> str:
    """A fresh identifier: 128 bits in lower-case hex; with a seed, the seed is its first four bytes."""
    raw = os.urandom(16)
    return (seed.to_bytes(4, "big") + raw[4:]).hex() if seed is not None else raw.hex()


@dataclass(frozen=True)
class Answer:
    kind: str
    identifier: str = ""
    detail: str = ""

    def payload(self) -> bytes:
        return answer_bytes(self.kind, self.identifier, self.detail)


DETAILS = {
    "handed-over": None,
    "handed-over-earlier": None,
    "not-handed-over": ("invalid", "plan", "store"),
    "uncertain": ("interrupted", "unknown", "conflict"),
    "unsettled": ("store",),
}


def answer_bytes(kind: str, identifier: str = "", detail: str = "") -> bytes:
    if kind == "refused-version":
        return b"2.refused-version"
    return f"2.{kind}.{identifier}.{detail}".encode("ascii")


def parse_answer(payload: bytes) -> Answer:
    """What an answer's payload says; kind ``malformed`` for anything the contract does not name."""
    if payload == b"2.refused-version":
        return Answer("refused-version")
    try:
        fields = payload.decode("ascii").split(".")
    except UnicodeDecodeError:
        return Answer("malformed")
    if len(fields) != 4 or fields[0] != "2" or fields[1] not in DETAILS:
        return Answer("malformed")
    kind, identifier, detail = fields[1], fields[2], fields[3]
    if not re.fullmatch(r"[0-9a-f]{32}", identifier):
        return Answer("malformed")
    allowed = DETAILS[kind]
    if allowed is None:
        if not re.fullmatch(r"[1-9][0-9]?", detail) or not 1 <= int(detail) <= 11:
            return Answer("malformed")
    elif detail not in allowed:
        return Answer("malformed")
    return Answer(kind, identifier, detail)


def read_golden(path: pathlib.Path = GOLDEN) -> dict[str, str]:
    """The vectors of the golden file by name, each as the text after ``name: ``."""
    vectors: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, separator, rest = line.partition(": ")
        if not separator:
            raise Failure(f"a golden line has no name: {line[:60]!r}")
        vectors[name] = rest.strip()
    return vectors


@dataclass(frozen=True)
class GoldenRequest:
    attempt: str
    identifier: str
    sender: bytes
    text: bytes
    payload: bytes


def golden_request(vectors: dict[str, str], name: str) -> GoldenRequest:
    """``request-*``: ``<attempt> <identifier> <sender-hex> <text-hex> => <payload-hex>``."""
    fields, _, payload = vectors[name].partition(" => ")
    attempt, identifier, sender, text = fields.split(" ")
    return GoldenRequest(attempt, identifier, bytes.fromhex(sender), bytes.fromhex(text), bytes.fromhex(payload))


def golden_payload(vectors: dict[str, str], name: str) -> bytes:
    """``refuse-*`` and ``version-*``: the payload's hex alone."""
    return bytes.fromhex(vectors[name].split(" ")[0])


# ---- The record's file, as the host helper of the proof rows writes it (RecordStore, DeliveryRecord).

def digest(sender: str, text: str) -> str:
    """SHA-256 of ``kernarium-sms-digest 1\\0`` and each of the sender and the text as a 32-bit big-endian length and
    its UTF-8 bytes."""
    s = sender.encode("utf-8")
    t = text.encode("utf-8")
    return hashlib.sha256(
        b"kernarium-sms-digest 1\0" + struct.pack(">I", len(s)) + s + struct.pack(">I", len(t)) + t).hexdigest()


def make_record(entries: list[tuple[str, str, str, int]]) -> bytes:
    """The record file: the header, a line ``<p|h|u> <identifier> <digest> <parts>`` for each entry and the CRC-32
    of every byte before the trailer."""
    body = (RECORD_HEADER + "\n" + "".join(f"{s} {i} {d} {p}\n" for s, i, d, p in entries)).encode("ascii")
    return body + f"end {zlib.crc32(body):08x}\n".encode("ascii")


def parse_record(data: bytes) -> list[tuple[str, str, str, int]]:
    """The entries of a record file; a Failure for a file the service would refuse."""
    text = data.decode("ascii", errors="replace")
    if len(data) > MAXIMUM_RECORD_BYTES:
        raise Failure(f"the record has {len(data)} bytes, more than {MAXIMUM_RECORD_BYTES}")
    match = re.fullmatch(r"(?s)(.*)end ([0-9a-f]{8})\n", text)
    if not match:
        raise Failure("the record has no end line")
    body = match[1].encode("ascii")
    if f"{zlib.crc32(body):08x}" != match[2]:
        raise Failure("the record's checksum is wrong")
    lines = match[1].split("\n")
    if lines[0] != RECORD_HEADER or lines[-1] != "":
        raise Failure("the record's header or last line is wrong")
    entries = []
    for line in lines[1:-1]:
        entry = re.fullmatch(r"([phu]) ([0-9a-f]{32}) ([0-9a-f]{64}) (0|[1-9][0-9]?)", line)
        if not entry:
            raise Failure(f"a record line is malformed: {line[:40]!r}")
        entries.append((entry[1], entry[2], entry[3], int(entry[4])))
    if len(entries) > RECORD_CAPACITY:
        raise Failure(f"the record holds {len(entries)} entries, more than {RECORD_CAPACITY}")
    return entries


# ---- Readers of what the guest prints. The tooling test feeds them text in the same layout.

STEP_LINE = re.compile(r"\bI AndariumSms\s*: step (\d+) of ([0-9a-f]{8})\s*$", re.MULTILINE)
EPOCH_LINE = re.compile(r"^\s*(\d+\.\d+)\s+\d+\s+\d+\s+[A-Z]\s+(\S+?)\s*:\s*(.*?)\s*$", re.MULTILINE)


def step_lines(logcat: str, identifier: str, number: int = 1) -> int:
    """How many lines say that step ``number`` of the message has been taken: the service logs one before each
    side effect, so a line is a hand-over that was begun."""
    return sum(1 for n, found in STEP_LINE.findall(logcat) if found == identifier[:8] and int(n) == number)


def epoch_lines(logcat: str, tag: str) -> list[tuple[float, str]]:
    """The lines of ``logcat -v epoch`` with a tag: the time and the message."""
    return [(float(when), message) for when, found, message in EPOCH_LINE.findall(logcat) if found == tag]


def check_boot_order(logcat: str, events: str) -> str | None:
    """H7: the service's first ``listening`` line comes before the boot's ``boot_progress_enable_screen`` event,
    which Android logs when it finishes booting, just before it sets sys.boot_completed."""
    listening = [when for when, message in epoch_lines(logcat, TAG)
                 if message == f"listening on vsock port {SMS_PORT}"]
    enabled = [when for when, _ in epoch_lines(events, "boot_progress_enable_screen")]
    if not listening:
        return "the service logged no 'listening on vsock port' line"
    if not enabled:
        return "the event log has no boot_progress_enable_screen to compare with"
    if min(listening) > min(enabled):
        return f"the service listened at {min(listening):.3f}, after the boot finished at {min(enabled):.3f}"
    return None


def check_record_location(logcat: str) -> str | None:
    """H11: the service logs once where its record is and how that directory is labelled."""
    lines = [message for _, message in epoch_lines(logcat, TAG) if message.startswith("record in ")]
    if not lines:
        return "the service logged no 'record in' line"
    if RECORD_DIRECTORY not in lines[0] or RECORD_LABEL not in lines[0]:
        return f"the record's place is {lines[0]!r}, not {RECORD_DIRECTORY} labelled {RECORD_LABEL}"
    return None


@dataclass(frozen=True)
class Process:
    label: str
    user: str
    pid: int
    name: str

    @property
    def domain(self) -> str:
        parts = self.label.split(":")
        return parts[2] if len(parts) > 2 else ""


def parse_ps(text: str) -> list[Process]:
    """``ps -A -Z``: the label, the user, the pid and the name of each process."""
    found = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0].startswith("u:r:") and fields[2].isdigit():
            found.append(Process(fields[0], fields[1], int(fields[2]), fields[-1]))
    return found


# The types that the compiled policy lets create, bind or listen on a vsock socket (A4.23's thirty), and the ones of
# them that a running image has: adbd and its compatibility types, the tracing daemon, the four host-only daemons
# (the gamepad relay and the vibrator, thermal and sensors HALs), the camera HAL, the composer, and the service.
VSOCK_TYPES = frozenset({
    "adbd", "adbd_202604", "adbd_tradeinmode", "aisealhostservice", "aisealhostservice_virtualizationmanager",
    "compos_fd_server", "compos_verify_virtualizationmanager", "composd_virtualizationmanager",
    "early_virtmgr_vendor", "hal_camera_default", "hal_graphics_composer_default", "hal_light_cuttlefish",
    "hal_sensors_default", "hal_thermal_default", "hal_vibrator_default", "kernarium_gamepad", "libcuttlefish_rild",
    "platform_app_all_virtualizationmanager", "priv_app_all_virtualizationmanager", "shell_virtualizationmanager",
    "socket_vsock_proxy", "storageproxyd_system", "tombstone_transmit", "traced",
    "trusty_security_vm_launcher_early_virtmgr", "untrusted_app_all_virtualizationmanager",
    "virtualizationmanager_vendor", "virtualizationservice", "virtualizationservice_virtualizationmanager",
    "vmlauncher_app", "kernarium_sms"})
RUNNING_VSOCK_TYPES = frozenset({
    "adbd", "traced", "kernarium_gamepad", "hal_vibrator_default", "hal_thermal_default", "hal_sensors_default",
    "hal_camera_default", "hal_graphics_composer_default", "kernarium_sms"})
# The vsock ports that answer from inside the guest: adbd's, and the host-only daemons' and the service's.
EXPECTED_PORTS = frozenset(range(5555, 5561))


def inventory_problems(ps_text: str) -> list[str]:
    """G6 (1): a process in a domain that may use vsock and is not one of the expected ones, a missing service,
    and any crosvm."""
    problems = []
    processes = parse_ps(ps_text)
    domains = {process.domain for process in processes}
    for process in processes:
        if process.domain in VSOCK_TYPES and process.domain not in RUNNING_VSOCK_TYPES:
            problems.append(f"{process.name} (pid {process.pid}) runs in {process.domain}, which may use vsock")
        if process.name.endswith("crosvm") or process.name.startswith("crosvm"):
            problems.append(f"a crosvm process runs (pid {process.pid})")
    if "kernarium_sms" not in domains:
        problems.append("no process runs in kernarium_sms")
    return problems


def port_problems(answering: set[int]) -> list[str]:
    """G6 (2): the ports that answered are exactly the expected ones."""
    problems = [f"vsock port {port} did not answer" for port in sorted(EXPECTED_PORTS - answering)]
    problems += [f"vsock port {port} answered and is not one of the guest's" for port in sorted(answering - EXPECTED_PORTS)]
    return problems


def smart_request(service: str) -> bytes:
    """A request to the adb server: four hex digits of the length, then the text."""
    encoded = service.encode("ascii")
    return f"{len(encoded):04x}".encode("ascii") + encoded


def parse_smart_reply(data: bytes) -> tuple[str, str]:
    """The adb server's reply: ``OKAY`` or ``FAIL`` with its message, or ``SHORT`` for anything less."""
    if data[:4] == b"OKAY":
        return "OKAY", ""
    if data[:4] == b"FAIL":
        length = int(data[4:8], 16) if re.fullmatch(rb"[0-9a-fA-F]{4}", data[4:8]) else 0
        return "FAIL", data[8:8 + length].decode("utf-8", errors="replace")
    return "SHORT", ""


def parse_total_pss(text: str) -> int | None:
    """``dumpsys meminfo <package>``: the total proportional set size in kB."""
    match = re.search(r"TOTAL PSS:\s+(\d+)", text) or re.search(r"^\s*TOTAL\s+(\d+)\b", text, re.MULTILINE)
    return int(match[1]) if match else None


def inbox_rows(text: str, sender: str, body: str) -> int:
    """``content query --uri content://sms/inbox --projection address:body``: the rows that hold the message."""
    count = 0
    for line in text.splitlines():
        address = re.search(r"address=(.*?), body=", line)
        if address and address[1] == sender and line.endswith(", body=" + body.replace("\n", " ")):
            count += 1
    return count


def parse_received(text: str) -> list[tuple[str, str]]:
    """The probe's files/received.txt: each line is the sender and the text in base64."""
    found = []
    for line in text.splitlines():
        fields = line.split(" ")
        if len(fields) == 2:
            found.append((base64.b64decode(fields[0]).decode("utf-8"), base64.b64decode(fields[1]).decode("utf-8")))
    return found


def cap_eff_bit(status: str, bit: int) -> bool | None:
    """``/proc/<pid>/status``: whether a bit of the effective capability set is set."""
    match = re.search(r"^CapEff:\s+([0-9a-f]+)$", status, re.MULTILINE)
    return None if not match else bool(int(match[1], 16) >> bit & 1)


def kernel_config_problems(config_gz_text: str, accepted: str) -> list[str]:
    """H9: each ``CONFIG_*VSOCK*``-family line of the accepted bundle's kernel/config is the running kernel's."""
    pattern = re.compile(r"^(?:# )?CONFIG_(?:VSOCKETS|VIRTIO_VSOCKETS|VHOST_VSOCK|VMWARE_VMCI|HYPERV)\S*( is not set|=.*)?$",
                         re.MULTILINE)

    def lines(text: str) -> set[str]:
        return {match[0] for match in pattern.finditer(text)}

    running, wanted = lines(config_gz_text), lines(accepted)
    return ([f"the kernel lacks '{line}'" for line in sorted(wanted - running)]
            + [f"the kernel has '{line}', which its bundle does not" for line in sorted(running - wanted)])


# ---- What the rows ask of the answers.

def retry_problem(first: Answer | None, retry: Answer | None, steps: int) -> str | None:
    """I4: what one first attempt, a crash at a varying time and a retry may and may not show. ``first`` is None
    when the first attempt got no answer; ``steps`` counts the step-1 lines for the identifier."""
    if steps > 1:
        return f"{steps} hand-overs were begun for one identifier"
    if first is not None and first.kind == "handed-over" and steps != 1:
        return f"the first attempt was answered handed-over with {steps} step-1 lines"
    if retry is None:
        return "the retry got no answer after the service had restarted"
    if retry.kind == "handed-over":
        return "a retry handed the message over"
    if retry.kind == "handed-over-earlier":
        return None if steps == 1 else f"handed-over-earlier with {steps} step-1 lines"
    if retry.kind == "uncertain" and retry.detail == "unknown":
        return None if steps == 0 else f"uncertain (unknown) with {steps} step-1 lines"
    if retry.kind == "uncertain" and retry.detail == "interrupted":
        return None
    if retry.kind == "not-handed-over":
        return None if steps == 0 else f"not-handed-over with {steps} step-1 lines"
    if retry.kind == "unsettled":
        return None
    return f"the retry's answer {retry.kind}.{retry.detail} is not one a retry of this message can have"


def restart_problem(answers: list[Exchange], identifier: str) -> str | None:
    """G3: no answer is wrong. A send ends not sent, unanswered or answered; an answer that comes must say what
    the record holds for a message sent before: handed over, now or earlier, or an interrupted one."""
    for exchange in answers:
        if exchange.outcome in ("connect-failed", "no-answer"):
            continue
        if exchange.outcome != "answered":
            return f"a send ended {exchange.outcome}"
        answer = parse_answer(exchange.payload)
        if answer.identifier != identifier:
            return f"an answer names another identifier: {exchange.payload!r}"
        if answer.kind in ("handed-over", "handed-over-earlier"):
            continue
        if answer.kind == "uncertain" and answer.detail == "interrupted":
            continue
        return f"a wrong answer: {exchange.payload!r}"
    if not answers or answers[-1].outcome != "answered":
        return "the send after the pid changed was not answered"
    return None


def strace_problem(trace: str, identifier: str) -> str | None:
    """I6: in the trace of the listener's thread, the record's rename comes first, then the directory's fsync, then
    the log line that says step 1 of the message (written before the side effect), then the first binder call."""
    marker = f"step 1 of {identifier[:8]}"
    lines = trace.splitlines()
    rename = next((i for i, line in enumerate(lines)
                   if re.search(r'rename(?:at2?)?\(.*sms-delivery-record\.new.*sms-delivery-record"', line)), None)
    if rename is None:
        return "the trace shows no rename of the record"
    fsync = next((i for i in range(rename + 1, len(lines)) if re.search(r"\bf(?:data)?sync\(", lines[i])), None)
    if fsync is None:
        return "the trace shows no fsync after the rename"
    logged = next((i for i in range(fsync + 1, len(lines))
                   if marker in lines[i] and re.search(r"\b(?:writev|sendmsg|write)\(", lines[i])), None)
    if logged is None:
        return f"the trace shows no write of '{marker}' after the fsync"
    binder = next((i for i in range(logged + 1, len(lines)) if "BINDER_WRITE_READ" in lines[i]), None)
    if binder is None:
        return "the trace shows no binder call after the log line"
    return None


# ---- The checks' catalogue: every row of the designs that is a runner's row, and why one may not run.

@dataclass(frozen=True)
class Row:
    name: str
    mode: str
    title: str
    covers: tuple[str, ...] = ()
    needs: str | None = None


NEEDS = {
    "adbd-topic": "needs an image with the adbd topic of the AOSP patches, which refuses a reverse forward onto "
                  "vsock: run it with --adbd-topic",
    "stock-adbd": "describes the stock adbd, which the adbd topic changes: run it without --adbd-topic",
    "kernel-config": "needs --kernel-config, the accepted kernel bundle's kernel/config",
    "g7": "records a residual and restarts adbd on a TCP port: run it with --g7",
    "no-provider": "needs the image variant with no SMS provider: run it with --variant no-provider",
    "proof": "needs su: run it with --mode proof on a userdebug proof build",
}

ROWS = (
    Row("G1", "channel", "a host's request is taken, handed over and answered", ("H2",)),
    Row("G2a", "channel", "the provider is gone", ("H4",)),
    Row("G2b", "channel", "an adb forward to vsock:3 is refused", ("H3",)),
    Row("G2c", "channel", "an adb forward to vsock:1 is refused", ("H3",)),
    Row("G2d", "channel", "an adb forward to vsock:2 ends at once", ("H3",)),
    Row("G2e", "channel", "adbd refuses a reverse forward onto vsock and onto acceptfd", (), "adbd-topic"),
    Row("G3", "channel", "the service restarts after a crash and no answer is wrong", ("H5",)),
    Row("G4", "channel", "domain, life, denials, boot order and record place", ("H1", "H7", "H8", "H11")),
    Row("G5", "channel", "the memory cost is reported"),
    Row("G6", "channel", "every vsock listener and no virtual machine", ("H10", "H13")),
    Row("G7", "channel", "the development launch's residual, recorded", (), "g7"),
    Row("G8", "channel", "the shell and an application cannot create a vsock socket"),
    Row("G9", "channel", "the shell cannot move adbd's listener"),
    Row("H6", "channel", "adbd's reverse forward onto vsock, as the stock image has it", (), "stock-adbd"),
    Row("H9", "channel", "the kernel's vsock configuration", (), "kernel-config"),
    Row("I1", "record", "a process ended between sends"),
    Row("I2", "record", "a reboot between sends"),
    Row("I4", "record", "never twice under kills"),
    Row("I5", "record", "the answers' bytes"),
    Row("I7", "record", "an image with no SMS provider", (), "no-provider"),
    Row("I8", "record", "payloads that are not version 2"),
    Row("I3", "proof", "a pending record left by an ended process", (), "proof"),
    Row("I6", "proof", "the record's storage and the order of its writes", (), "proof"),
)

# What no run of this runner covers, and where it is covered.
ELSEWHERE = (
    ("R1-R24, U1-U5", "the JVM rows of tests/tooling/android (android17-sms-service)"),
    ("U6", "the target-files verifier and its fixtures (lineage24-target-files-fixtures)"),
    ("B1", "the unsigned image build of the change, on each variant built"),
    ("H12", "the commit message of the adbd topic (route p0011) names the function and the listen forms; G2e tries each"),
)


def plan_rows(mode: str, available: set[str]) -> tuple[list[Row], list[tuple[Row, str]]]:
    """The rows of a mode that this run can make, and the ones it cannot with the reason."""
    run, skipped = [], []
    for row in ROWS:
        if row.mode != mode:
            continue
        if row.needs is None or row.needs in available:
            run.append(row)
        else:
            skipped.append((row, NEEDS[row.needs]))
    return run, skipped


# ---- The guest, the host's end of the channel and the adb server.

@dataclass
class Exchange:
    outcome: str  # answered, not-taken, no-answer, connect-failed or bad-header
    payload: bytes = b""


def recv_exactly(connection: socket.socket, count: int, deadline: float) -> bytes:
    """Up to ``count`` bytes: fewer at the end of the stream or the deadline."""
    data = b""
    while len(data) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        connection.settimeout(remaining)
        try:
            chunk = connection.recv(count - len(data))
        except (socket.timeout, ConnectionError):
            break
        if not chunk:
            break
        data += chunk
    return data


class Host:
    """The host application's end: a connection for each request, as the application makes one."""

    def __init__(self, port: int) -> None:
        self.port = port

    def exchange(self, payload: bytes, seconds: float = ANSWER_SECONDS) -> Exchange:
        try:
            connection = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        except OSError:
            return Exchange("connect-failed")
        with connection:
            try:
                connection.sendall(frame(payload))
            except OSError:
                return Exchange("no-answer")
            deadline = time.monotonic() + seconds
            header = recv_exactly(connection, 8, deadline)
            if len(header) < 8:
                return Exchange("no-answer", header)
            length = frame_length(header)
            if length is None:
                return Exchange("bad-header", header)
            body = recv_exactly(connection, length, deadline)
            if len(body) < length:
                return Exchange("no-answer", header + body)
            return Exchange("not-taken" if length == 0 else "answered", body)

    def answer(self, payload: bytes, seconds: float = ANSWER_SECONDS) -> Answer:
        """The answer, or a Failure when none came."""
        exchange = self.exchange(payload, seconds)
        if exchange.outcome != "answered":
            raise Failure(f"the request got no answer ({exchange.outcome})")
        return parse_answer(exchange.payload)


def raw_stream(port: int, data: bytes, seconds: float) -> tuple[bytes, bool, float]:
    """What a connection returns for ``data``: the bytes, whether the peer ended the stream, and when."""
    started = time.monotonic()
    try:
        connection = socket.create_connection(("127.0.0.1", port), timeout=10)
    except OSError as problem:
        raise Failure(f"cannot connect to 127.0.0.1:{port}: {problem}") from problem
    with connection:
        try:
            connection.sendall(data)
        except OSError:
            return b"", True, time.monotonic() - started
        received = b""
        deadline = started + seconds
        while time.monotonic() < deadline:
            connection.settimeout(max(0.01, deadline - time.monotonic()))
            try:
                chunk = connection.recv(4096)
            except socket.timeout:
                break
            except ConnectionError:
                return received, True, time.monotonic() - started
            if not chunk:
                return received, True, time.monotonic() - started
            received += chunk
        return received, False, time.monotonic() - started


def open_vsock_through_adbd(serial: str, port: int, seconds: float = SWEEP_PORT_SECONDS,
                            server_port: int = ADB_SERVER_PORT) -> str:
    """Asks adbd, through the adb server's own protocol, to connect to ``vsock:3:<port>``: ``OKAY`` once adbd has
    connected, ``FAIL`` when it is refused, ``TIMEOUT`` when neither comes."""
    deadline = time.monotonic() + seconds
    try:
        with socket.create_connection(("127.0.0.1", server_port), timeout=seconds) as connection:
            for service, last in ((f"host:transport:{serial}", False), (f"vsock:3:{port}", True)):
                connection.sendall(smart_request(service))
                reply = recv_exactly(connection, 4, deadline)
                if len(reply) < 4:
                    return "TIMEOUT"
                if reply == b"FAIL":
                    reply += recv_exactly(connection, 4, deadline)
                    reply += recv_exactly(connection, int(reply[4:8], 16) if len(reply) == 8 else 0, deadline)
                kind, _ = parse_smart_reply(reply)
                if kind != "OKAY":
                    return kind
                if last:
                    return "OKAY"
    except OSError:
        return "FAIL"
    return "FAIL"


class Guest:
    def __init__(self, adb: str, serial: str, process: subprocess.Popen, log: pathlib.Path, forward_port: int,
                 private: pathlib.Path) -> None:
        self.adb = adb
        self.serial = serial
        self.process = process
        self.log = log
        self.forward_port = forward_port
        self.private = private

    def adb_run(self, *arguments: str, timeout: float = COMMAND_SECONDS) -> subprocess.CompletedProcess:
        return subprocess.run(
            [self.adb, "-s", self.serial, *arguments], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)

    def shell(self, command: str, timeout: float = COMMAND_SECONDS, check: bool = True) -> str:
        result = self.adb_run("shell", command, timeout=timeout)
        if check and result.returncode != 0:
            raise Failure(f"'{command}' exited {result.returncode}: {result.stdout.strip()[-500:]}")
        return result.stdout

    def su(self, command: str, timeout: float = COMMAND_SECONDS, check: bool = True) -> str:
        return self.shell(f"su 0 sh -c {shlex.quote(command)}", timeout=timeout, check=check)

    def alive(self) -> None:
        if self.process.poll() is not None:
            raise Failure(f"the guest exited with status {self.process.returncode}:\n"
                          + self.log.read_text(errors="replace")[-3000:])

    def pid(self) -> int | None:
        result = self.adb_run("shell", f"pidof {PACKAGE}", timeout=30)
        text = result.stdout.strip().split()
        return int(text[0]) if result.returncode == 0 and text and text[0].isdigit() else None

    def logcat(self, *arguments: str) -> str:
        return self.shell("logcat -d " + " ".join(arguments), timeout=COMMAND_SECONDS)

    def service_log(self) -> str:
        return self.logcat("-s", f"{TAG}:I")

    def crash_service(self) -> None:
        self.shell(f"am crash {PACKAGE}", timeout=60, check=False)

    def probe_result(self, name: str, nonce: str, seconds: float = PROBE_SECONDS) -> str:
        """A file of the probe's, once its first line is the nonce of the request."""
        deadline = time.monotonic() + seconds
        text = ""
        while time.monotonic() < deadline:
            self.alive()
            text = self.adb_run("exec-out", f"run-as {PROBE_PACKAGE} cat files/{name}", timeout=30).stdout
            lines = text.splitlines()
            if lines and lines[0] == nonce:
                return "\n".join(lines[1:])
            time.sleep(0.5)
        raise Failure(f"the probe wrote no files/{name} for nonce {nonce} in {seconds:.0f} s: {text[:200]!r}")

    def probe_call(self, call: str, seconds: float = PROBE_SECONDS) -> str:
        nonce = os.urandom(6).hex()
        self.shell(f"am broadcast -f 32 -n {PROBE_PACKAGE}/.CommandReceiver --es do {call} --es nonce {nonce}",
                   timeout=60)
        return self.probe_result({"vsock": "vsock.txt", "vm": "vm.txt"}[call], nonce, seconds)

    def inbox(self) -> str:
        return self.shell("content query --uri content://sms/inbox --projection address:body", check=False)

    def forward(self, spec: str) -> int:
        result = self.adb_run("forward", "tcp:0", spec, timeout=30)
        text = result.stdout.strip()
        if result.returncode != 0 or not text.isdigit():
            raise Failure(f"adb forward tcp:0 {spec} failed: {text[:200]}")
        return int(text)

    def remove_forward(self, port: int) -> None:
        self.adb_run("forward", "--remove", f"tcp:{port}", timeout=30)


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_until(description: str, seconds: float, check: Callable[[], str | None], guest: Guest | None = None,
               interval: float = 1.0) -> None:
    """Calls ``check`` until it returns None (done); its last message is the failure."""
    deadline = time.monotonic() + seconds
    message: str | None = "not checked"
    while time.monotonic() < deadline:
        if guest is not None:
            guest.alive()
        message = check()
        if message is None:
            return
        time.sleep(interval)
    raise Failure(f"{description}: {message} (after {seconds:.0f} s)")


def vsock_forward_port(log: pathlib.Path, process: subprocess.Popen, guest_port: int) -> int:
    """The host port the launcher chose for the forward to a guest vsock port."""
    deadline = time.monotonic() + FORWARD_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise Failure(f"the guest exited with status {process.returncode}:\n"
                          + log.read_text(errors="replace")[-3000:])
        for _, port, found in FORWARD.findall(log.read_text(errors="replace")):
            if int(found) == guest_port:
                return int(port)
        time.sleep(0.2)
    raise Failure(f"the launcher reported no vsock forward to guest port {guest_port}")


# ---- The run: the options, the guest, the host, and the helpers that the rows share.

class Run:
    def __init__(self, options: argparse.Namespace, guest: Guest, vectors: dict[str, str]) -> None:
        self.options = options
        self.guest = guest
        self.host = Host(guest.forward_port)
        self.vectors = vectors
        self.notes: list[str] = []

    def note(self, line: str) -> None:
        self.notes.append(line)
        print(f"  note: {line}")

    def ping(self) -> bool:
        """Whether the service answers: a version-3 request is refused with its version, and nothing is touched."""
        exchange = self.host.exchange(b"3.ping", seconds=5)
        return exchange.outcome == "answered" and parse_answer(exchange.payload).kind == "refused-version"

    def wait_serving(self, previous: int | None, seconds: float = RESTART_SECONDS) -> None:
        """Until the service has a pid other than ``previous`` and answers."""
        def check() -> str | None:
            pid = self.guest.pid()
            if pid is None or pid == previous:
                return f"the pid is {pid}, was {previous}"
            return None if self.ping() else "the service does not answer"
        wait_until("the service restarting", seconds, check, self.guest)

    def sender_and_text(self, tag: str) -> tuple[str, str]:
        return "+15550100", f"sms-check {tag} {os.urandom(3).hex()}"

    def first(self, identifier: str, sender: str, text: str, seconds: float = ANSWER_SECONDS) -> Answer:
        return self.host.answer(request("first", identifier, sender, text), seconds)

    def retry(self, identifier: str, sender: str, text: str, seconds: float = ANSWER_SECONDS) -> Answer:
        return self.host.answer(request("retry", identifier, sender, text), seconds)

    def expect(self, answer: Answer, kind: str, identifier: str, detail: str) -> None:
        if answer != Answer(kind, identifier, detail):
            raise Failure(f"the answer is {answer.payload()!r}, expected {Answer(kind, identifier, detail).payload()!r}")

    def inbox_rows_within(self, sender: str, text: str, seconds: float = INBOX_SECONDS) -> int:
        deadline = time.monotonic() + seconds
        rows = 0
        while time.monotonic() < deadline:
            rows = inbox_rows(self.guest.inbox(), sender, text)
            if rows:
                break
            time.sleep(1)
        return rows

    @property
    def has_inbox(self) -> bool:
        return self.options.variant != "no-provider"


def refused(run: Run, port: int, label: str) -> None:
    """The stream of a connection that the service must refuse ends with no byte within five seconds."""
    request_bytes = frame(request("first", new_identifier(), "+15550100", "must not be delivered"))
    received, closed, elapsed = raw_stream(port, request_bytes, REFUSAL_SECONDS)
    if received or not closed:
        raise Failure(f"{label}: expected the end of the stream with no byte within {REFUSAL_SECONDS} s, got "
                      f"{len(received)} byte(s), closed={closed}, after {elapsed:.1f} s")


# ---- The channel rows.

def row_g1(run: Run) -> None:
    golden = golden_request(run.vectors, "request-first-number")
    if request(golden.attempt, golden.identifier, golden.sender, golden.text) != golden.payload:
        raise Failure("the runner's encoder disagrees with the golden request")
    sender, text = golden.sender.decode(), golden.text.decode()
    # The probe application holds RECEIVE_SMS and records what it is handed.
    run.guest.shell(f"pm grant {PROBE_PACKAGE} android.permission.RECEIVE_SMS")
    run.guest.shell(f"am broadcast -f 32 -n {PROBE_PACKAGE}/.CommandReceiver --es do reset", timeout=60)
    answer = run.host.answer(golden.payload)
    run.expect(answer, "handed-over", golden.identifier, "1")
    if step_lines(run.guest.service_log(), golden.identifier) != 1:
        raise Failure("the service log does not show exactly one step 1 for the golden request")
    def received() -> str | None:
        text_found = run.guest.adb_run("exec-out", f"run-as {PROBE_PACKAGE} cat files/received.txt", timeout=30).stdout
        return None if (sender, text) in parse_received(text_found) else "the probe has not received it"
    wait_until("SMS_RECEIVED reaching the probe", PROBE_SECONDS, received, run.guest)
    if run.has_inbox:
        rows = run.inbox_rows_within(sender, text)
        if rows != 1:
            raise Failure(f"the inbox holds {rows} rows for the message, expected 1")
        run.note(f"inbox rows: {rows}")


def row_g2a(run: Run) -> None:
    steps = len(STEP_LINE.findall(run.guest.service_log()))
    output = run.guest.shell("content call --uri content://android.kernarium.sms --method deliver --arg x",
                             check=False)
    if not re.search(r"(?i)(not found|no content provider|unable to find|unknown ur[il]|error while accessing)",
                     output):
        raise Failure(f"the provider's call did not say the provider is missing: {output.strip()[:300]!r}")
    if len(STEP_LINE.findall(run.guest.service_log())) != steps:
        raise Failure("a hand-over began")


def row_g2_forward(run: Run, spec: str, expect_log: str | None) -> None:
    port = run.guest.forward(spec)
    try:
        refused(run, port, spec)
    finally:
        run.guest.remove_forward(port)
    if expect_log and expect_log not in run.guest.service_log():
        raise Failure(f"the service did not log '{expect_log}'")


def row_g2b(run: Run) -> None:
    row_g2_forward(run, f"vsock:3:{SMS_PORT}", "refused a connection from CID 1")


def row_g2c(run: Run) -> None:
    row_g2_forward(run, f"vsock:1:{SMS_PORT}", "refused a connection from CID 1")


def row_g2d(run: Run) -> None:
    port = run.guest.forward(f"vsock:2:{SMS_PORT}")
    try:
        received, closed, _ = raw_stream(port, b"", REFUSAL_SECONDS)
    finally:
        run.guest.remove_forward(port)
    if received or not closed:
        raise Failure("a forward to the host did not end at once with no byte")


REVERSE_VSOCK_FORMS = ("vsock:5560", "vsock:5599", "vsock:0", "vsock:4294967295")


def row_g2e(run: Run) -> None:
    """Every listen form that a reverse forward may name is refused, with the service running and with it
    disabled, while a TCP reverse and its rebind work and adbd stays reachable."""
    guest = run.guest

    def adbd_works() -> None:
        if guest.shell("echo adbd-works", timeout=60).strip() != "adbd-works":
            raise Failure("adb over vsock stopped answering")

    def attempt(spec: str) -> None:
        result = guest.adb_run("reverse", spec, f"tcp:{free_port()}", timeout=60)
        listed = guest.adb_run("reverse", "--list", timeout=60).stdout
        if result.returncode == 0 or spec in listed:
            raise Failure(f"'adb reverse {spec}' was not refused: {result.stdout.strip()[:200]!r}, list {listed!r}")
        adbd_works()

    def pass_once() -> None:
        for spec in (*REVERSE_VSOCK_FORMS, *(f"acceptfd:{n}" for n in range(32))):
            attempt(spec)
        first, second, third = free_port(), free_port(), free_port()
        for spec, target in ((f"tcp:{first}", f"tcp:{second}"), (f"tcp:{first}", f"tcp:{third}")):
            result = guest.adb_run("reverse", spec, target, timeout=60)
            if result.returncode != 0:
                raise Failure(f"'adb reverse {spec} {target}' failed: {result.stdout.strip()[:200]!r}")
        guest.adb_run("reverse", "--remove", f"tcp:{first}", timeout=60)
        adbd_works()

    pass_once()
    guest.shell(f"pm disable-user {PACKAGE}")
    try:
        pass_once()
    finally:
        guest.shell(f"pm enable {PACKAGE}", check=False)
        wait_until("the service enabled again", RESTART_SECONDS, lambda: None if run.ping() else "no answer",
                   guest)


def row_h6(run: Run) -> None:
    """The stock adbd lets a reverse forward listen on vsock, and holds no CAP_NET_BIND_SERVICE (bit 10)."""
    guest = run.guest
    result = guest.adb_run("reverse", "vsock:5599", f"tcp:{free_port()}", timeout=60)
    try:
        if result.returncode != 0 or "vsock:5599" not in guest.adb_run("reverse", "--list", timeout=60).stdout:
            raise Failure(f"the stock adbd refused 'adb reverse vsock:5599': {result.stdout.strip()[:200]!r}")
    finally:
        guest.adb_run("reverse", "--remove", "vsock:5599", timeout=60)
    adbd = guest.shell("pidof adbd").split()[0]
    bit = cap_eff_bit(guest.shell(f"cat /proc/{adbd}/status"), 10)
    if bit is None or bit:
        raise Failure(f"adbd's CapEff has bit 10 {'set' if bit else 'unreadable'}")


def row_g3(run: Run) -> None:
    guest = run.guest
    sender, text = run.sender_and_text("restart")
    identifier = new_identifier()
    answers = [run.host.exchange(request("first", identifier, sender, text))]
    before = guest.pid()
    guest.crash_service()
    deadline = time.monotonic() + RESTART_SECONDS
    while time.monotonic() < deadline:
        guest.alive()
        answers.append(run.host.exchange(request("first", identifier, sender, text), seconds=5))
        pid = guest.pid()
        if pid is not None and pid != before:
            break
        time.sleep(0.5)
    else:
        raise Failure(f"the service did not restart in {RESTART_SECONDS} s")
    answers.append(run.host.exchange(request("first", identifier, sender, text)))
    problem = restart_problem(answers, identifier)
    if problem:
        raise Failure(problem)
    if step_lines(guest.service_log(), identifier) != 1:
        raise Failure("the message was handed over more or less than once")


def row_g4(run: Run) -> None:
    guest = run.guest
    ps = guest.shell("ps -A -Z | grep " + PACKAGE, check=False)
    mine = [process for process in parse_ps(ps) if process.name == PACKAGE]
    if not mine or mine[0].label != "u:r:kernarium_sms:s0" or mine[0].user != "system":
        raise Failure(f"the service runs as {mine and (mine[0].label, mine[0].user)}, not u:r:kernarium_sms:s0, system")
    processes = guest.shell(f"dumpsys activity processes | grep -A6 {PACKAGE}", check=False)
    if not re.search(r"\*PERS\*|persistent=true", processes):
        raise Failure("the activity manager does not list the service as persistent")
    epoch = guest.logcat("-b", "all", "-v", "epoch", "-s", f"{TAG}:I")
    problem = check_boot_order(epoch, guest.logcat("-b", "events", "-v", "epoch", "-s", "boot_progress_enable_screen"))
    if problem:
        raise Failure(problem)
    problem = check_record_location(epoch)
    if problem:
        raise Failure(problem)
    denials = [line for line in guest.logcat("-b", "all").splitlines()
               if "avc: " in line and "denied" in line and "kernarium_sms" in line]
    if denials:
        raise Failure("SELinux denials: " + "; ".join(denials[:3]))
    if not step_lines(guest.service_log(), golden_request(run.vectors, "request-first-number").identifier):
        raise Failure("no delivery was observed before the denial check, so its silence proves nothing: run G1 first")


def row_g5(run: Run) -> None:
    pss = parse_total_pss(run.guest.shell(f"dumpsys meminfo {PACKAGE}"))
    if pss is None:
        raise Failure("dumpsys meminfo shows no total")
    run.note(f"total PSS of {PACKAGE}: {pss} kB (to the owner before acceptance)")


def row_g6(run: Run) -> None:
    guest = run.guest
    problems = []
    if guest.shell("test -x /apex/com.android.virt/bin/vm && echo yes", check=False).strip() == "yes":
        started = guest.adb_run("shell", "/apex/com.android.virt/bin/vm run-microdroid", timeout=VM_SECONDS)
        run.note(f"vm run-microdroid exited {started.returncode}: {started.stdout.strip()[:120]!r}")
        if started.returncode == 0:
            problems.append("'vm run-microdroid' started a virtual machine")
    else:
        run.note("the image has no vm tool")
    grant = guest.adb_run("shell", f"pm grant {PROBE_PACKAGE} android.permission.MANAGE_VIRTUAL_MACHINE", timeout=60)
    run.note(f"granting MANAGE_VIRTUAL_MACHINE: exit {grant.returncode} {grant.stdout.strip()[:120]!r}")
    vm = guest.probe_call("vm", seconds=VM_SECONDS)
    run.note(vm.strip())
    if "vm: started" in vm:
        problems.append("the probe application started a virtual machine")
    terminal = guest.shell("pm list packages | grep -i terminal", check=False).strip()
    if terminal:
        package = terminal.splitlines()[0].split(":", 1)[1]
        guest.shell(f"monkey -p {package} -c android.intent.category.LAUNCHER 1", timeout=60, check=False)
        time.sleep(5)
    if guest.shell("pidof crosvm", check=False).strip():
        problems.append("a crosvm process runs")
    problems += inventory_problems(guest.shell("ps -A -Z"))
    answering: set[int] = set()
    started = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(SWEEP_WIDTH) as pool:
        futures = {pool.submit(open_vsock_through_adbd, guest.serial, port): port for port in range(1, 65536)}
        for future in concurrent.futures.as_completed(futures, timeout=SWEEP_SECONDS):
            if future.result() == "OKAY":
                answering.add(futures[future])
            if time.monotonic() - started > SWEEP_SECONDS:
                raise Failure("the port sweep passed its deadline")
    problems += port_problems(answering)
    if problems:
        raise Failure("; ".join(problems))


def row_g7(run: Run) -> None:
    """Not a gate: what adbd does on ``adb tcpip 5560`` while the service holds the port, and after a crash."""
    guest = run.guest
    guest.adb_run("tcpip", str(SMS_PORT), timeout=60)
    time.sleep(5)
    lines = [message for _, message in epoch_lines(guest.logcat("-b", "all", "-v", "epoch"), "adbd")
             if f"vsock:{SMS_PORT}" in message]
    run.note("adbd's lines about the port: " + (" | ".join(lines[:3]) or "none"))


def row_g8(run: Run) -> None:
    guest = run.guest
    pushed = guest.adb_run("push", str(run.options.vsockprobe_dex), "/data/local/tmp/vsockprobe.dex", timeout=60)
    if pushed.returncode != 0:
        raise Failure(f"pushing the probe failed: {pushed.stdout.strip()[:200]}")
    shell = guest.shell("CLASSPATH=/data/local/tmp/vsockprobe.dex app_process /system/bin VsockProbe", timeout=60)
    app = guest.probe_call("vsock").strip()
    for who, text in (("the shell", shell.strip()), ("an application", app)):
        if text != "socket: errno=13 EACCES":
            raise Failure(f"{who} got '{text}', expected 'socket: errno=13 EACCES'")


def row_g9(run: Run) -> None:
    guest = run.guest
    result = guest.shell("setprop service.adb.listen_addrs vsock:5599", check=False)
    value = guest.shell("getprop service.adb.listen_addrs").strip()
    if value:
        raise Failure(f"the shell set service.adb.listen_addrs to {value!r}")
    run.note(f"setprop said: {result.strip()[:120]!r}")


def row_h9(run: Run) -> None:
    accepted = run.options.kernel_config.read_text()
    running = run.guest.shell("zcat /proc/config.gz")
    problems = kernel_config_problems(running, accepted)
    if problems:
        raise Failure("; ".join(problems))


# ---- The record rows.

def reboot_guest(run: Run) -> None:
    guest = run.guest
    guest.adb_run("reboot", timeout=60)

    def booted() -> str | None:
        result = guest.adb_run("shell", "getprop sys.boot_completed", timeout=15)
        if result.returncode != 0 or result.stdout.strip() != "1":
            return "not booted"
        return None if run.ping() else "the service does not answer"
    time.sleep(10)
    wait_until("the guest after its reboot", REBOOT_SECONDS, booted, guest, interval=3.0)


def row_i1(run: Run) -> None:
    guest = run.guest
    sender, text = run.sender_and_text("i1")
    identifier = new_identifier()
    run.expect(run.first(identifier, sender, text), "handed-over", identifier, "1")
    before = guest.pid()
    guest.crash_service()
    run.wait_serving(before)
    run.expect(run.retry(identifier, sender, text), "handed-over-earlier", identifier, "1")
    run.expect(run.first(identifier, sender, text), "handed-over-earlier", identifier, "1")
    steps = step_lines(guest.service_log(), identifier)
    if steps != 1:
        raise Failure(f"{steps} step-1 lines for the identifier, expected 1")
    if run.has_inbox:
        run.note(f"inbox rows within {INBOX_SECONDS} s: {run.inbox_rows_within(sender, text)}")


def row_i2(run: Run) -> None:
    guest = run.guest
    sender, text = run.sender_and_text("i2")
    identifier = new_identifier()
    run.expect(run.first(identifier, sender, text), "handed-over", identifier, "1")
    # The log does not survive a reboot: count the lines before it and after it.
    steps = step_lines(guest.service_log(), identifier)
    reboot_guest(run)
    run.expect(run.retry(identifier, sender, text), "handed-over-earlier", identifier, "1")
    steps += step_lines(guest.service_log(), identifier)
    if steps != 1:
        raise Failure(f"{steps} step-1 lines for the identifier across the reboot, expected 1")


CRASH_DELAYS_MS = (0, 10, 25, 50, 80, 120, 160, 200)
KILL_ROUNDS = 50


def row_i4(run: Run) -> None:
    guest = run.guest
    sender = "+15550100"
    for i in range(KILL_ROUNDS):
        identifier = new_identifier(4000 + i)
        text = f"sms-check i4 {i} {os.urandom(3).hex()}"
        delay = CRASH_DELAYS_MS[i % len(CRASH_DELAYS_MS)] / 1000
        before = guest.pid()
        crash = threading.Timer(delay, guest.crash_service)
        crash.start()
        exchange = run.host.exchange(request("first", identifier, sender, text), seconds=15)
        crash.join()
        first = parse_answer(exchange.payload) if exchange.outcome == "answered" else None
        run.wait_serving(before)
        retry = run.host.exchange(request("retry", identifier, sender, text))
        answer = parse_answer(retry.payload) if retry.outcome == "answered" else None
        problem = retry_problem(first, answer, step_lines(guest.service_log(), identifier))
        if problem:
            raise Failure(f"round {i} (crash after {delay * 1000:.0f} ms, first {exchange.outcome}, retry "
                          f"{answer.kind if answer else retry.outcome}): {problem}")
    run.note(f"{KILL_ROUNDS} rounds: never twice")


def row_i5(run: Run) -> None:
    sender, text = run.sender_and_text("i5")
    first, fresh, conflict = new_identifier(), new_identifier(), new_identifier()
    expected = [
        ("first attempt", request("first", first, sender, text), answer_bytes("handed-over", first, "1")),
        ("retry of a fresh identifier", request("retry", fresh, sender, text),
         answer_bytes("uncertain", fresh, "unknown")),
        ("other content under a known identifier", request("first", first, sender, text + " other"),
         answer_bytes("uncertain", first, "conflict")),
        ("a 671-unit text", request("first", conflict, sender, "x" * (MAXIMUM_UNITS + 1)),
         answer_bytes("not-handed-over", conflict, "invalid")),
        ("a version 3 payload", b"3.first." + first.encode() + b".x.y", answer_bytes("refused-version")),
    ]
    for label, payload, wanted in expected:
        exchange = run.host.exchange(payload)
        if exchange.outcome != "answered" or exchange.payload != wanted:
            raise Failure(f"{label}: got {exchange.outcome} {exchange.payload!r}, expected {wanted!r}")
    if len(expected[3][2]) != 58:
        raise Failure("the not-handed-over (invalid) form is not 58 bytes")
    exchange = run.host.exchange(golden_payload(run.vectors, "refuse-missing-padding"))
    if exchange.outcome != "not-taken":
        raise Failure(f"a payload that is not version 2: got {exchange.outcome}, expected the empty answer")


def row_i7(run: Run) -> None:
    sender = "+15550100"
    pairs = [(new_identifier(7000 + i), f"sms-check i7 {i} {os.urandom(3).hex()}") for i in range(20)]
    for identifier, text in pairs:
        answer = run.first(identifier, sender, text)
        if answer.kind != "handed-over":
            raise Failure(f"a first attempt was answered {answer.kind}.{answer.detail}, expected handed-over "
                          "(the receivers-only plan, G.4 a)")
    for identifier, text in pairs:
        answer = run.retry(identifier, sender, text)
        if answer.kind != "handed-over-earlier":
            raise Failure(f"a retry was answered {answer.kind}.{answer.detail}, expected handed-over-earlier")


def row_i8(run: Run) -> None:
    """The design's four payloads, then every golden payload that is not a version 2 request: the empty answer, and
    for a request of another version its own, and no step line for any of them."""
    for label, name in (("the version 1 three-field argument", "refuse-v1-three-fields"),
                        ("a trailing line feed", "refuse-trailing-byte"),
                        ("non-canonical base64", "refuse-pad-bits")):
        exchange = run.host.exchange(golden_payload(run.vectors, name))
        if exchange.outcome != "not-taken":
            raise Failure(f"{label}: got {exchange.outcome} {exchange.payload!r}, expected the empty answer")
    for name in (n for n in run.vectors if n.startswith("refuse-")):
        exchange = run.host.exchange(golden_payload(run.vectors, name))
        if exchange.outcome != "not-taken":
            raise Failure(f"{name}: got {exchange.outcome} {exchange.payload!r}, expected the empty answer")
    for name in (n for n in run.vectors if n.startswith("version-")):
        exchange = run.host.exchange(golden_payload(run.vectors, name))
        if exchange.outcome != "answered" or exchange.payload != answer_bytes("refused-version"):
            raise Failure(f"{name}: got {exchange.outcome} {exchange.payload!r}, expected 2.refused-version")
    identifier = golden_request(run.vectors, "request-first-number").identifier
    if any(step_lines(run.guest.service_log(), identifier, n) for n in (1, 2)):
        raise Failure("a step line was written for a payload that is not version 2")


# ---- The proof rows (they need su).

def record_path() -> str:
    return f"{RECORD_DIRECTORY}/sms-delivery-record"


def read_record(run: Run) -> list[tuple[str, str, str, int]]:
    run.guest.su(f"cp {record_path()} /data/local/tmp/record.copy && chmod 644 /data/local/tmp/record.copy")
    local = run.guest.private / "record.copy"
    pulled = run.guest.adb_run("pull", "/data/local/tmp/record.copy", str(local), timeout=60)
    if pulled.returncode != 0:
        raise Failure(f"pulling the record failed: {pulled.stdout.strip()[:200]}")
    return parse_record(local.read_bytes())


def row_i3(run: Run) -> None:
    guest = run.guest
    sender, text = run.sender_and_text("i3")
    pending, other = new_identifier(), new_identifier()
    before = guest.pid()
    guest.crash_service()
    run.wait_serving(before)
    record = guest.private / "record.pending"
    record.write_bytes(make_record([("p", pending, digest(sender, text), 1)]))
    pushed = guest.adb_run("push", str(record), "/data/local/tmp/record.pending", timeout=60)
    if pushed.returncode != 0:
        raise Failure(f"pushing the record failed: {pushed.stdout.strip()[:200]}")
    guest.su(f"cp /data/local/tmp/record.pending {record_path()} && chown system:system {record_path()} "
             f"&& restorecon {record_path()}")
    run.expect(run.retry(pending, sender, text), "uncertain", pending, "interrupted")
    run.expect(run.first(pending, sender, text), "uncertain", pending, "interrupted")
    if step_lines(guest.service_log(), pending):
        raise Failure("a hand-over began for the pending identifier")
    if [entry for entry in read_record(run) if entry[1] == pending][0][0] != "p":
        raise Failure("the lookups rewrote the record: it no longer holds p for the pending identifier")
    run.expect(run.first(other, sender, text + " next"), "handed-over", other, "1")
    if [entry for entry in read_record(run) if entry[1] == pending][0][0] != "u":
        raise Failure("the next pending write did not turn p into u")


def row_i6(run: Run) -> None:
    guest = run.guest
    listing = guest.su(f"ls -lZ {RECORD_DIRECTORY}")
    for name in ("sms-delivery-record", "sms-delivery-record.lock"):
        line = next((entry for entry in listing.splitlines() if entry.rstrip().endswith(name)), None)
        if line is None or "system" not in line or "kernarium_sms_data_file" not in line:
            raise Failure(f"{name} is not owned by system and labelled kernarium_sms_data_file: {line!r}")
    sender = "+15550100"
    for i in range(300):
        run.first(new_identifier(1000 + i), sender, f"sms-check i6 {i}")
    size = int(guest.su(f"stat -c %s {record_path()}").strip())
    if size > MAXIMUM_RECORD_BYTES:
        raise Failure(f"the record has {size} bytes after 300 sends, more than {MAXIMUM_RECORD_BYTES}")
    entries = read_record(run)
    if len(entries) > RECORD_CAPACITY:
        raise Failure(f"the record holds {len(entries)} entries")
    if guest.su("which strace", check=False).strip():
        pid = guest.pid()
        identifier = new_identifier(2000)
        trace = "/data/local/tmp/sms.strace"
        guest.su(f"(timeout 20 strace -f -s 128 -e trace=fsync,fdatasync,renameat,renameat2,writev,sendmsg,ioctl "
                 f"-p {pid} -o {trace} &) ; sleep 2", check=False)
        run.first(identifier, sender, "sms-check i6 traced")
        time.sleep(3)
        problem = strace_problem(guest.su(f"cat {trace}", check=False), identifier)
        if problem:
            raise Failure(problem)
    else:
        run.note("this proof build has no strace: the order of the writes was not traced")


ROW_FUNCTIONS: dict[str, Callable[[Run], None]] = {
    "G1": row_g1, "G2a": row_g2a, "G2b": row_g2b, "G2c": row_g2c, "G2d": row_g2d, "G2e": row_g2e, "G3": row_g3,
    "G4": row_g4, "G5": row_g5, "G6": row_g6, "G7": row_g7, "G8": row_g8, "G9": row_g9, "H6": row_h6, "H9": row_h9,
    "I1": row_i1, "I2": row_i2, "I3": row_i3, "I4": row_i4, "I5": row_i5, "I6": row_i6, "I7": row_i7, "I8": row_i8,
}


def run_rows(run: Run, rows: list[Row]) -> dict[str, str]:
    """Each row in turn, reported on its own; a row's failure does not stop the next."""
    verdicts: dict[str, str] = {}
    for row in rows:
        print(f"{row.name}: {row.title}")
        try:
            ROW_FUNCTIONS[row.name](run)
            verdicts[row.name] = "PASS"
        except (Failure, subprocess.TimeoutExpired, OSError, concurrent.futures.TimeoutError) as problem:
            verdicts[row.name] = f"FAIL: {problem}"
        run.guest.alive()
        print(f"  {verdicts[row.name]}")
    return verdicts


# ---- Starting and stopping the guest.

def start_guest(options: argparse.Namespace, adb: str, private: pathlib.Path) -> Guest:
    instance = options.instance or private / "instance"
    boot_options = boot_android.parse_arguments([
        *(["--release", str(options.release)] if options.release else []),
        *(["--emulator", str(options.emulator)] if options.emulator else []),
        "--instance", str(instance),
        "--adb-port", str(options.adb_port),
        "--cpus", str(options.cpus),
        "--memory", options.memory,
        "--display", "offscreen",
        "--audio-output", "null",
        "--engine", "gadgets",
    ])
    emulator = boot_android.resolve_executable(boot_options.emulator)
    release = boot_android.release_path(boot_options.release)
    identity = boot_android.android_instance.read_release(release)
    decision = boot_android.plan_start(boot_options, identity, instance)
    boot_android.android_instance.apply(instance, identity, decision)
    command = [
        *boot_android.emulator_command(
            boot_options, release, instance / boot_android.android_instance.DATA_DISK, emulator,
            boot_android.data_capacity(boot_options, identity)),
        f"--vsock-forward=127.0.0.1:0-{SMS_PORT}",
    ]
    log = private / "emulator.log"
    stream = log.open("wb")
    environment = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                               start_new_session=True, env=environment)
    stream.close()
    serial = f"127.0.0.1:{options.adb_port}"
    # main's cleanup owns the emulator only once this returns, so a failure from here on stops it here.
    try:
        guest = Guest(adb, serial, process, log, vsock_forward_port(log, process, SMS_PORT), private)
        boot_android.wait_for_adb(adb, serial, process, options.boot_timeout)
        if not boot_android.wait_for_boot_completed(adb, serial, process, options.boot_timeout):
            raise Failure("Android did not reach sys.boot_completed")
        boot_android.android_instance.booted(instance, identity)
        if not options.instance:
            boot_android.provision_guest(adb, serial)
        print(f"booted; settling for {SETTLE_SECONDS} s")
        time.sleep(SETTLE_SECONDS)
    except BaseException:
        boot_android.disconnect_adb(adb, serial)
        boot_android.stop_guest(process)
        raise
    return guest


def install_probe(guest: Guest, apk: pathlib.Path) -> None:
    result = guest.adb_run("install", "-r", str(apk), timeout=COMMAND_SECONDS)
    if result.returncode != 0 or "Success" not in result.stdout:
        raise Failure(f"installing the probe failed: {result.stdout.strip()[-300:]}")


def available_needs(options: argparse.Namespace) -> set[str]:
    needs = set()
    if options.adbd_topic:
        needs.add("adbd-topic")
    else:
        needs.add("stock-adbd")
    if options.kernel_config is not None:
        needs.add("kernel-config")
    if options.g7:
        needs.add("g7")
    if options.variant == "no-provider":
        needs.add("no-provider")
    if options.mode == "proof":
        needs.add("proof")
    return needs


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=("channel", "record", "proof"), default="channel")
    parser.add_argument("--variant", choices=("messaging", "no-messaging", "no-provider"), default="messaging",
                        help="what the image has: Messaging and the SMS provider; the provider alone; neither")
    parser.add_argument("--list-rows", action="store_true", help="print the rows and what each needs, and stop")
    parser.add_argument("--emulator", type=pathlib.Path,
                        help="the macos-android17 uml-darwin-android17 (the launcher's default)")
    parser.add_argument("--release", type=pathlib.Path, help="installed Android release (default: accepted)")
    parser.add_argument("--instance", type=pathlib.Path,
                        help="an existing instance to boot; the default is a fresh one that is removed at the end")
    parser.add_argument("--adb", default="adb", help="adb client to use")
    parser.add_argument("--adb-port", type=int, default=slot_ports.slot_port(slot_ports.ADB_OFFSET, DEFAULT_ADB_PORT),
                        help="loopback port the launcher forwards adbd to (default: the guest slot's first port "
                        f"when GUEST_SLOT_PORT_BASE is set, else {DEFAULT_ADB_PORT})")
    parser.add_argument("--probe-apk", type=pathlib.Path, help="AndariumSmsProbe.apk (channel mode)")
    parser.add_argument("--vsockprobe-dex", type=pathlib.Path, help="vsockprobe.dex (channel mode)")
    parser.add_argument("--kernel-config", type=pathlib.Path, help="the accepted kernel bundle's kernel/config (H9)")
    parser.add_argument("--adbd-topic", action="store_true",
                        help="the image has the adbd topic of the AOSP patches (G2e instead of H6)")
    parser.add_argument("--g7", action="store_true", help="also record the development launch (G7)")
    parser.add_argument("--cpus", type=int, default=4)
    parser.add_argument("--memory", default="4G")
    parser.add_argument("--boot-timeout", type=int, default=900,
                        help="seconds to wait for adbd and for boot_completed")
    return parser


def print_rows() -> None:
    for mode in ("channel", "record", "proof"):
        print(f"mode {mode}:")
        for row in (row for row in ROWS if row.mode == mode):
            covers = f" (also {', '.join(row.covers)})" if row.covers else ""
            needs = f" [{NEEDS[row.needs]}]" if row.needs else ""
            print(f"  {row.name:5} {row.title}{covers}{needs}")
    print("elsewhere:")
    for names, where in ELSEWHERE:
        print(f"  {names}: {where}")


def main() -> int:
    options = build_parser().parse_args()
    if options.list_rows:
        print_rows()
        return 0
    if options.cpus <= 0 or options.boot_timeout <= 0:
        print("counts and timeouts must be positive", file=sys.stderr)
        return 2
    if options.mode == "channel" and not all(
            path is not None and path.is_file() for path in (options.probe_apk, options.vsockprobe_dex)):
        print("--probe-apk and --vsockprobe-dex must name files in the channel mode", file=sys.stderr)
        return 2
    if options.kernel_config is not None and not options.kernel_config.is_file():
        print(f"--kernel-config names no file: {options.kernel_config}", file=sys.stderr)
        return 2
    adb = boot_android.resolve_executable(options.adb, sdk_fallback=True)
    # Short, so every socket path below it stays within sun_path.
    private = pathlib.Path(tempfile.mkdtemp(prefix="uml-sms-"))
    guest: Guest | None = None
    try:
        vectors = read_golden()
        guest = start_guest(options, adb, private)
        if options.mode == "channel":
            install_probe(guest, options.probe_apk)
        if options.mode == "proof" and "uid=0" not in guest.shell("su 0 id", check=False):
            raise Failure("the proof mode needs su, which only a userdebug proof build has")
        run = Run(options, guest, vectors)
        rows, skipped = plan_rows(options.mode, available_needs(options))
        verdicts = run_rows(run, rows)
        print("\nrows:")
        for row in rows:
            print(f"  {row.name:5} {verdicts[row.name]}")
        for row, reason in skipped:
            print(f"  {row.name:5} NOT RUN: {reason}")
        for names, where in ELSEWHERE:
            print(f"  {names}: not this runner's ({where})")
        failed = [name for name, verdict in verdicts.items() if verdict != "PASS"]
        print("FAIL" if failed else "PASS")
        return 1 if failed else 0
    except (Failure, boot_android.LauncherError, subprocess.TimeoutExpired, OSError) as problem:
        print(f"FAIL: {problem}", file=sys.stderr)
        log = private / "emulator.log"
        if log.is_file():
            print("launcher log tail:\n" + "\n".join(log.read_text(errors="replace").splitlines()[-30:]),
                  file=sys.stderr)
        return 1
    finally:
        if guest is not None:
            boot_android.disconnect_adb(adb, guest.serial)
            boot_android.stop_guest(guest.process)
        shutil.rmtree(private, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
