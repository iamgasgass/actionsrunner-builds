#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The text-message runner's pure parts, without a guest.

run_android_sms.py plays the host application against a booted release: it frames requests, reads answers
and judges what the guest prints. The tests here run those parts: its encoder and framing against the golden
file that the service and the host's tests read too, its readers against texts in the layout the guest
prints, its judgements of a round of rows, its host and its adb-server client against fakes on loopback,
the catalogue of rows, and a parse of the probe sources (Android's classes are not on the host, so javac
reads them without resolving a name).
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import contextlib
import importlib.util
import io
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest import mock

TESTS = Path(__file__).resolve().parents[2]
SCRIPT = TESTS / "integration/android/run_android_sms.py"
SPEC = importlib.util.spec_from_file_location("run_android_sms", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
runner = importlib.util.module_from_spec(SPEC)
# Dataclasses resolve their annotations through sys.modules.
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)

PROBE = TESTS / "integration/android/sms"
ID = "00112233445566778899aabbccddeeff"
OTHER = "ffeeddccbbaa99887766554433221100"


def jdk_tool(name: str) -> str | None:
    path = shutil.which(name)
    if path is None:
        return None
    probe = subprocess.run([path, "-version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=60, check=False)
    return path if probe.returncode == 0 else None


class GoldenTests(unittest.TestCase):
    """The runner's wire against the bytes that the service and the host agree on."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.vectors = runner.read_golden()

    def names(self, prefix: str) -> list[str]:
        found = [name for name in self.vectors if name.startswith(prefix)]
        self.assertTrue(found, prefix)
        return found

    def test_requests_encode_to_the_golden_payloads(self) -> None:
        for name in self.names("request-"):
            with self.subTest(name):
                golden = runner.golden_request(self.vectors, name)
                self.assertEqual(
                    runner.request(golden.attempt, golden.identifier, golden.sender, golden.text), golden.payload)

    def test_frames(self) -> None:
        for name in self.names("frame-"):
            with self.subTest(name):
                payload, _, whole = self.vectors[name].partition("=>")
                self.assertEqual(runner.frame(bytes.fromhex(payload.strip())), bytes.fromhex(whole.strip()))

    def test_answers_read_back_and_write_the_same_bytes(self) -> None:
        expected = {
            "answer-handed-over-1": ("handed-over", "1"),
            "answer-handed-over-11": ("handed-over", "11"),
            "answer-handed-over-earlier-1": ("handed-over-earlier", "1"),
            "answer-handed-over-earlier-11": ("handed-over-earlier", "11"),
            "answer-not-handed-over-invalid": ("not-handed-over", "invalid"),
            "answer-not-handed-over-plan": ("not-handed-over", "plan"),
            "answer-not-handed-over-store": ("not-handed-over", "store"),
            "answer-uncertain-interrupted": ("uncertain", "interrupted"),
            "answer-uncertain-unknown": ("uncertain", "unknown"),
            "answer-uncertain-conflict": ("uncertain", "conflict"),
            "answer-unsettled-store": ("unsettled", "store"),
        }
        self.assertEqual(sorted(expected), sorted(n for n in self.names("answer-") if n != "answer-refused-version"))
        for name, (kind, detail) in expected.items():
            with self.subTest(name):
                payload = bytes.fromhex(self.vectors[name].partition("=>")[2].strip())
                answer = runner.parse_answer(payload)
                self.assertEqual((answer.kind, answer.identifier, answer.detail), (kind, ID, detail))
                self.assertEqual(answer.payload(), payload)
        refused = bytes.fromhex(self.vectors["answer-refused-version"].partition("=>")[2].strip())
        self.assertEqual(runner.parse_answer(refused).kind, "refused-version")
        self.assertEqual(runner.answer_bytes("refused-version"), refused)

    def test_the_invalid_answer_has_58_bytes(self) -> None:
        self.assertEqual(len(runner.answer_bytes("not-handed-over", ID, "invalid")), 58)

    def test_answers_that_the_contract_does_not_name(self) -> None:
        for payload in (b"", b"2.handed-over." + ID.encode() + b".0", b"2.handed-over." + ID.encode() + b".12",
                        b"2.handed-over." + ID.encode() + b".01", b"2.uncertain." + ID.encode() + b".other",
                        b"2.unsettled." + ID.encode() + b".plan", b"2.handed-over.x.1", b"3.handed-over." + ID.encode()
                        + b".1", b"2.handed-over." + ID.encode() + b".1.x", b"2.refused-version.x", b"\xff"):
            with self.subTest(payload):
                self.assertEqual(runner.parse_answer(payload).kind, "malformed")

    def test_answer_headers(self) -> None:
        self.assertEqual(runner.frame_length(bytes.fromhex(self.vectors["header-answer-4096"])), 4096)
        self.assertEqual(runner.frame_length(bytes.fromhex(self.vectors["frame-answer-zero"].partition("=>")[2].strip())), 0)
        for name in ("reject-magic", "reject-version", "reject-version-0", "reject-answer-length-4097"):
            with self.subTest(name):
                self.assertIsNone(runner.frame_length(bytes.fromhex(self.vectors[name])))
        self.assertIsNone(runner.frame_length(b"KSMS\x01\x00"))

    def test_the_golden_request_the_rows_use_is_the_first_number(self) -> None:
        golden = runner.golden_request(self.vectors, "request-first-number")
        self.assertEqual((golden.attempt, golden.identifier), ("first", ID))
        self.assertEqual(golden.sender, b"+15551234567")
        self.assertEqual(golden.text, b"hello")

    def test_payload_vectors_for_the_rows_that_send_what_is_not_a_request(self) -> None:
        for name in self.names("refuse-"):
            payload = runner.golden_payload(self.vectors, name)
            self.assertLessEqual(len(payload), runner.MAXIMUM_REQUEST)
        for name in self.names("version-"):
            self.assertTrue(runner.golden_payload(self.vectors, name))

    def test_fresh_identifiers(self) -> None:
        self.assertRegex(runner.new_identifier(), r"[0-9a-f]{32}")
        self.assertNotEqual(runner.new_identifier(), runner.new_identifier())
        self.assertTrue(runner.new_identifier(4001).startswith("00000fa1"))
        with self.assertRaises(ValueError):
            runner.request("again", ID, "a", "b")


class RecordTests(unittest.TestCase):
    """The record file that the proof rows write and read, in the service's format."""

    def test_digest_vectors_of_the_service(self) -> None:
        for sender, text, wanted in (
                ("Bank", "hello", "35dfc8aa85463b0b36567dc603805cfb487b5855dffbbaf6cf70ef0ff9aa4285"),
                ("+15551234567", "café \U0001F600", "4c4d991afaa947c78c569baf4b8f938e9b8608710f68d32e5bf5356d63d540db"),
                ("", "", "d3baf49451436e834d2c79fff543d2f3e0fe317a552d6919b2a4721e91ceb68a")):
            self.assertEqual(runner.digest(sender, text), wanted)
        self.assertNotEqual(runner.digest("a", "bc"), runner.digest("ab", "c"))

    def test_round_trip(self) -> None:
        entries = [("p", ID, runner.digest("a", "b"), 1), ("h", OTHER, runner.digest("c", "d"), 11),
                   ("u", "0" * 32, runner.digest("e", "f"), 0)]
        data = runner.make_record(entries)
        self.assertTrue(data.startswith(b"kernarium-sms-record 1\n"))
        self.assertRegex(data.decode(), r"end [0-9a-f]{8}\n$")
        self.assertEqual(runner.parse_record(data), entries)

    def test_the_largest_record_is_the_documented_size(self) -> None:
        entries = [("u", f"{i:032x}", runner.digest("a", str(i)), 11) for i in range(runner.RECORD_CAPACITY)]
        self.assertEqual(len(runner.make_record(entries)), runner.MAXIMUM_RECORD_BYTES)
        self.assertEqual(runner.MAXIMUM_RECORD_BYTES, 26404)
        with self.assertRaises(runner.Failure):
            runner.parse_record(runner.make_record(entries + [("u", ID, runner.digest("a", "b"), 1)]))
        # Short lines: 257 of them fit the size, so only the count refuses them.
        short = [("u", f"{i:032x}", runner.digest("a", str(i)), 1) for i in range(runner.RECORD_CAPACITY + 1)]
        self.assertLess(len(runner.make_record(short)), runner.MAXIMUM_RECORD_BYTES)
        with self.assertRaises(runner.Failure) as refused:
            runner.parse_record(runner.make_record(short))
        self.assertIn("257 entries", str(refused.exception))

    def test_a_record_the_service_would_refuse(self) -> None:
        good = runner.make_record([("p", ID, runner.digest("a", "b"), 1)])
        for label, data in (("a flipped byte", good.replace(b"p " + ID.encode(), b"h " + ID.encode())),
                            ("no trailer", good[:-13]), ("another header", good.replace(b" 1\n", b" 2\n", 1)),
                            ("a bad line", runner.make_record([("p", ID, "x", 1)]))):
            with self.subTest(label):
                with self.assertRaises(runner.Failure):
                    runner.parse_record(data)


LOG = """\
11-16 12:00:00.100  1000  1100 I AndariumSms: listening on vsock port 5560
11-16 12:00:01.000  1000  1200 I AndariumSms: planned 2 step(s) for a message of 1 part(s), to com.android.messaging
11-16 12:00:01.001  1000  1200 I AndariumSms: step 1 of 00112233
11-16 12:00:01.002  1000  1200 I AndariumSms: step 2 of 00112233
11-16 12:00:02.000  1000  1200 I AndariumSms: step 1 of ffeeddcc
11-16 12:00:02.001  1000  1200 I AndariumSms: step 1 of ffeeddcc failed: SecurityException
11-16 12:00:03.000  1000  1200 I AndariumSms: step 1 of 00112233
11-16 12:00:04.000  1000  1200 W AndariumSms: step 1 of 99999999
"""

EPOCH = """\
1731758405.250  1000  1100 I AndariumSms: record in /data/user_de/0/android.kernarium.sms/files, labelled u:object_r:kernarium_sms_data_file:s0
1731758405.300  1000  1100 I AndariumSms: listening on vsock port 5560
1731758406.000   900   900 I OtherTag: listening on vsock port 5560
"""

EVENTS = """\
1731758420.100  1000  1000 I boot_progress_enable_screen: 15000
"""


class ReaderTests(unittest.TestCase):
    def test_step_lines(self) -> None:
        self.assertEqual(runner.step_lines(LOG, "00112233" + "0" * 24), 2)
        self.assertEqual(runner.step_lines(LOG, "00112233" + "0" * 24, 2), 1)
        # A failed step is not a step taken, and neither is a line of another priority.
        self.assertEqual(runner.step_lines(LOG, "ffeeddcc" + "0" * 24), 1)
        self.assertEqual(runner.step_lines(LOG, "99999999" + "0" * 24), 0)
        self.assertEqual(len(runner.STEP_LINE.findall(LOG)), 4)

    def test_epoch_lines_and_the_boot_order(self) -> None:
        self.assertEqual([when for when, _ in runner.epoch_lines(EPOCH, "AndariumSms")], [1731758405.25, 1731758405.3])
        self.assertIsNone(runner.check_boot_order(EPOCH, EVENTS))
        late = "1731758430.000  1000  1100 I AndariumSms: listening on vsock port 5560\n"
        self.assertIn("after the boot finished", runner.check_boot_order(late, EVENTS))
        self.assertIn("no 'listening", runner.check_boot_order("", EVENTS))
        self.assertIn("no boot_progress_enable_screen", runner.check_boot_order(EPOCH, ""))

    def test_the_record_place(self) -> None:
        self.assertIsNone(runner.check_record_location(EPOCH))
        wrong = EPOCH.replace("kernarium_sms_data_file", "system_app_data_file")
        self.assertIn("not /data/user_de/0/android.kernarium.sms/files labelled", runner.check_record_location(wrong))
        self.assertIn("no 'record in'", runner.check_record_location(""))

    PS = """\
LABEL                          USER           PID   PPID     VSZ    RSS WCHAN            ADDR S NAME
u:r:init:s0                    root             1      0   10000   1000 0                   0 S init
u:r:adbd:s0                    shell          300      1   10000   1000 0                   0 S adbd
u:r:traced:s0                  traced         310      1   10000   1000 0                   0 S traced
u:r:kernarium_gamepad:s0       nobody         320      1   10000   1000 0                   0 S kernarium_gamepad
u:r:hal_thermal_default:s0     system         330      1   10000   1000 0                   0 S thermal
u:r:kernarium_sms:s0           system         900    300   10000   1000 0                   0 S android.kernarium.sms
u:r:system_app:s0              system         950    300   10000   1000 0                   0 S com.android.settings
"""

    def test_the_listener_inventory(self) -> None:
        self.assertEqual([p.name for p in runner.parse_ps(self.PS)][-2:], ["android.kernarium.sms", "com.android.settings"])
        self.assertEqual(runner.inventory_problems(self.PS), [])
        extra = self.PS + "u:r:virtualizationservice:s0   system   960  1  1 1 0 0 S virtmgr\n"
        self.assertIn("virtmgr (pid 960) runs in virtualizationservice, which may use vsock",
                      runner.inventory_problems(extra))
        self.assertIn("a crosvm process runs (pid 961)",
                      runner.inventory_problems(self.PS + "u:r:crosvm:s0  system  961  1  1 1 0 0 S crosvm\n"))
        self.assertIn("no process runs in kernarium_sms",
                      runner.inventory_problems(self.PS.replace("kernarium_sms:s0", "system_app:s0")))

    def test_the_port_inventory(self) -> None:
        self.assertEqual(runner.port_problems(set(range(5555, 5561))), [])
        self.assertEqual(runner.port_problems(set(range(5555, 5561)) | {5599}),
                         ["vsock port 5599 answered and is not one of the guest's"])
        self.assertEqual(runner.port_problems(set(range(5555, 5560))), ["vsock port 5560 did not answer"])

    def test_adb_server_replies(self) -> None:
        self.assertEqual(runner.smart_request("host:transport:x"), b"0010host:transport:x")
        self.assertEqual(runner.parse_smart_reply(b"OKAY"), ("OKAY", ""))
        self.assertEqual(runner.parse_smart_reply(b"FAIL0004oops"), ("FAIL", "oops"))
        self.assertEqual(runner.parse_smart_reply(b"OK"), ("SHORT", ""))

    def test_dumps(self) -> None:
        self.assertEqual(runner.parse_total_pss("  Native Heap PSS: 7\n           TOTAL PSS:    18432            TOTAL RSS:    40960"),
                         18432)
        self.assertEqual(runner.parse_total_pss("        TOTAL    18432    1000"), 18432)
        self.assertIsNone(runner.parse_total_pss("nothing"))
        inbox = ("Row: 0 address=+15551234567, body=hello\nRow: 1 address=Bank, body=hello\n"
                 "Row: 2 address=+15551234567, body=hello\n")
        self.assertEqual(runner.inbox_rows(inbox, "+15551234567", "hello"), 2)
        self.assertEqual(runner.inbox_rows(inbox, "+15551234567", "hell"), 0)
        received = "K1Yy aGk=\n"
        self.assertEqual(runner.parse_received(received), [("+V2", "hi")])
        status = "Name:\tadbd\nCapEff:\t0000000000000400\n"
        self.assertTrue(runner.cap_eff_bit(status, 10))
        self.assertFalse(runner.cap_eff_bit(status, 9))
        self.assertIsNone(runner.cap_eff_bit("Name:\tadbd\n", 10))

    def test_the_kernel_configuration(self) -> None:
        accepted = "CONFIG_VSOCKETS=y\nCONFIG_VIRTIO_VSOCKETS=y\n# CONFIG_VHOST_VSOCK is not set\nCONFIG_OTHER=y\n"
        self.assertEqual(runner.kernel_config_problems(accepted + "CONFIG_X=y\n", accepted), [])
        self.assertEqual(runner.kernel_config_problems("CONFIG_VSOCKETS=y\n# CONFIG_VHOST_VSOCK is not set\n", accepted),
                         ["the kernel lacks 'CONFIG_VIRTIO_VSOCKETS=y'"])
        self.assertTrue(runner.kernel_config_problems(accepted + "CONFIG_VHOST_VSOCK=m\n", accepted)[0]
                        .startswith("the kernel has 'CONFIG_VHOST_VSOCK=m'"))


def answer(kind: str, detail: str = "") -> object:
    return runner.Answer(kind, ID, detail)


class JudgementTests(unittest.TestCase):
    """What a round of rows may and may not show."""

    def test_never_twice_under_kills(self) -> None:
        problem = runner.retry_problem
        handed, earlier = answer("handed-over", "1"), answer("handed-over-earlier", "1")
        self.assertIsNone(problem(handed, earlier, 1))
        self.assertIsNone(problem(None, earlier, 1))
        self.assertIsNone(problem(None, answer("uncertain", "unknown"), 0))
        self.assertIsNone(problem(None, answer("uncertain", "interrupted"), 0))
        self.assertIsNone(problem(None, answer("uncertain", "interrupted"), 1))
        self.assertIsNone(problem(None, answer("not-handed-over", "plan"), 0))
        self.assertIsNone(problem(None, answer("unsettled", "store"), 1))
        self.assertIn("2 hand-overs", problem(handed, earlier, 2))
        self.assertIn("a retry handed", problem(None, answer("handed-over", "1"), 1))
        self.assertIn("handed-over-earlier with 0", problem(None, earlier, 0))
        self.assertIn("uncertain (unknown) with 1", problem(None, answer("uncertain", "unknown"), 1))
        self.assertIn("answered handed-over with 0", problem(handed, earlier, 0))
        self.assertIn("no answer", problem(handed, None, 1))
        self.assertIn("conflict", problem(None, answer("uncertain", "conflict"), 0))
        self.assertIn("not-handed-over with 1", problem(None, answer("not-handed-over", "store"), 1))

    def test_a_restart_gives_no_wrong_answer(self) -> None:
        def made(kind: str, detail: str = "1", identifier: str = ID) -> object:
            return runner.Exchange("answered", runner.answer_bytes(kind, identifier, detail))

        gone = runner.Exchange("no-answer")
        refused = runner.Exchange("connect-failed")
        good = [made("handed-over"), gone, refused, made("handed-over-earlier"), made("handed-over-earlier")]
        self.assertIsNone(runner.restart_problem(good, ID))
        self.assertIn("after the pid changed", runner.restart_problem([made("handed-over"), gone], ID))
        self.assertIn("wrong answer", runner.restart_problem(good + [made("uncertain", "unknown")], ID))
        self.assertIn("another identifier", runner.restart_problem(good + [made("handed-over-earlier", "1", OTHER)], ID))
        self.assertIn("ended not-taken", runner.restart_problem(good + [runner.Exchange("not-taken")], ID))
        self.assertIn("after the pid changed", runner.restart_problem([], ID))

    TRACE = """\
1500 renameat(AT_FDCWD, "/data/user_de/0/android.kernarium.sms/files/sms-delivery-record.new", AT_FDCWD, "/data/user_de/0/android.kernarium.sms/files/sms-delivery-record") = 0
1500 fsync(7)                          = 0
1500 writev(5, [{iov_base="\\1\\0\\0\\0AndariumSms\\0step 1 of 00112233\\0", iov_len=33}], 1) = 33
1500 ioctl(12, BINDER_WRITE_READ, {write_size=64}) = 0
"""

    def test_the_order_of_the_writes(self) -> None:
        self.assertIsNone(runner.strace_problem(self.TRACE, ID))
        lines = self.TRACE.splitlines()
        self.assertIn("no rename", runner.strace_problem("\n".join(lines[1:]), ID))
        # The file's own fsync before the rename is not the directory's after it.
        self.assertIn("no fsync after", runner.strace_problem("\n".join([lines[1], lines[0], lines[2], lines[3]]), ID))
        self.assertIn("no write of 'step 1 of 00112233' after", runner.strace_problem(
            "\n".join([lines[0], lines[2], lines[1], lines[3]]), ID))
        self.assertIn("no binder call after", runner.strace_problem("\n".join([lines[0], lines[1], lines[3], lines[2]]), ID))


class CatalogueTests(unittest.TestCase):
    def test_every_row_has_a_check_and_every_check_a_row(self) -> None:
        self.assertEqual(sorted(row.name for row in runner.ROWS), sorted(runner.ROW_FUNCTIONS))
        self.assertEqual(len({row.name for row in runner.ROWS}), len(runner.ROWS))
        for row in runner.ROWS:
            self.assertIn(row.mode, ("channel", "record", "proof"))
            self.assertTrue(row.needs is None or row.needs in runner.NEEDS, row.name)

    def test_the_designs_rows_are_here_or_named_elsewhere(self) -> None:
        names = {row.name for row in runner.ROWS}
        covered = {c for row in runner.ROWS for c in row.covers}
        for wanted in ("G1", "G2a", "G2b", "G2c", "G2d", "G2e", "G3", "G4", "G5", "G6", "G7", "G8", "G9",
                       "I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8"):
            self.assertIn(wanted, names)
        for wanted in ("H1", "H2", "H3", "H4", "H5", "H7", "H8", "H10", "H11", "H13"):
            self.assertIn(wanted, covered)
        self.assertEqual(names & {"H6", "H9"}, {"H6", "H9"})
        elsewhere = " ".join(names for names, _ in runner.ELSEWHERE)
        for wanted in ("B1", "H12", "U6"):
            self.assertIn(wanted, elsewhere)

    def test_what_a_run_without_the_extras_skips(self) -> None:
        run, skipped = runner.plan_rows("channel", {"stock-adbd"})
        self.assertEqual([row.name for row, _ in skipped], ["G2e", "G7", "H9"])
        self.assertIn("G9", [row.name for row in run])
        self.assertIn("H6", [row.name for row in run])
        run, skipped = runner.plan_rows("channel", {"adbd-topic", "kernel-config", "g7"})
        self.assertEqual([row.name for row, _ in skipped], ["H6"])
        run, skipped = runner.plan_rows("record", set())
        self.assertEqual([row.name for row, _ in skipped], ["I7"])
        run, skipped = runner.plan_rows("proof", set())
        self.assertEqual([row.name for row in run], [])
        self.assertEqual({row.name for row, _ in skipped}, {"I3", "I6"})
        run, _ = runner.plan_rows("proof", {"proof"})
        self.assertEqual([row.name for row in run], ["I3", "I6"])

    def test_the_option_flags_make_the_rows_available(self) -> None:
        options = runner.build_parser().parse_args(["--adbd-topic", "--g7", "--variant", "no-provider"])
        self.assertEqual(runner.available_needs(options), {"adbd-topic", "g7", "no-provider"})
        options = runner.build_parser().parse_args(["--mode", "proof"])
        self.assertEqual(runner.available_needs(options), {"stock-adbd", "proof"})

    def test_the_row_listing_runs(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            runner.print_rows()
        self.assertIn("G2e", output.getvalue())
        self.assertIn("adbd topic", output.getvalue())
        self.assertIn("B1", output.getvalue())


class FakeService:
    """The service's end of a forward, on loopback: it reads a frame and does what the script says."""

    def __init__(self, script) -> None:
        self.script = script
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen()
        self.port = self.server.getsockname()[1]
        self.received: list[bytes] = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                connection.settimeout(5)
                try:
                    header = connection.recv(8, socket.MSG_WAITALL)
                    length = struct.unpack("<HH", header[4:])[1] if len(header) == 8 else 0
                    payload = connection.recv(length, socket.MSG_WAITALL) if length else b""
                except OSError:
                    continue
                self.received.append(header + payload)
                reply = self.script(payload)
                if reply is not None:
                    with contextlib.suppress(OSError):
                        connection.sendall(reply)

    def close(self) -> None:
        self.server.close()


class HostTests(unittest.TestCase):
    def test_outcomes(self) -> None:
        answers = {
            b"first": runner.frame(runner.answer_bytes("handed-over", ID, "1")),
            b"empty": runner.frame(b""),
            b"badmagic": b"KSMT\x01\x00\x05\x00hello",
            b"badversion": b"KSMS\x02\x00\x00\x00",
            b"toolong": b"KSMS\x01\x00\x01\x10",
            b"short": runner.frame(b"hello")[:-2],
            b"headeronly": b"KSM",
            b"close": None,
        }
        service = FakeService(lambda payload: answers[payload])
        self.addCleanup(service.close)
        host = runner.Host(service.port)
        exchange = host.exchange(b"first", seconds=3)
        self.assertEqual((exchange.outcome, runner.parse_answer(exchange.payload).kind), ("answered", "handed-over"))
        self.assertEqual(host.answer(b"first", 3).identifier, ID)
        self.assertEqual(host.exchange(b"empty", seconds=3).outcome, "not-taken")
        for name in ("badmagic", "badversion", "toolong"):
            self.assertEqual(host.exchange(name.encode(), seconds=3).outcome, "bad-header", name)
        for name in ("short", "headeronly", "close"):
            self.assertEqual(host.exchange(name.encode(), seconds=1).outcome, "no-answer", name)
        self.assertEqual(service.received[0], runner.frame(b"first"))
        with self.assertRaises(runner.Failure):
            host.answer(b"close", 1)
        service.close()
        self.assertEqual(runner.Host(service.port).exchange(b"first", seconds=1).outcome, "connect-failed")

    def test_a_refused_stream_ends_with_no_byte(self) -> None:
        service = FakeService(lambda payload: None)
        self.addCleanup(service.close)
        received, closed, elapsed = runner.raw_stream(service.port, runner.frame(b"x"), 3)
        self.assertEqual((received, closed), (b"", True))
        self.assertLess(elapsed, 3)
        talker = FakeService(lambda payload: runner.frame(b"y"))
        self.addCleanup(talker.close)
        received, closed, _ = runner.raw_stream(talker.port, runner.frame(b"x"), 1)
        self.assertEqual(received, runner.frame(b"y"))
        silent = socket.socket()
        silent.bind(("127.0.0.1", 0))
        silent.listen()
        self.addCleanup(silent.close)
        received, closed, elapsed = runner.raw_stream(silent.getsockname()[1], b"x", 1)
        self.assertEqual((received, closed), (b"", False))
        self.assertGreaterEqual(elapsed, 0.9)
        dead = socket.socket()
        dead.bind(("127.0.0.1", 0))
        port = dead.getsockname()[1]
        dead.close()
        with self.assertRaises(runner.Failure):
            runner.raw_stream(port, b"x", 1)


class AdbServerTests(unittest.TestCase):
    """The client of the adb server's own protocol, against a fake that answers as the server does."""

    def serve(self, answers: dict[str, bytes]) -> int:
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        self.addCleanup(server.close)

        def run() -> None:
            while True:
                try:
                    connection, _ = server.accept()
                except OSError:
                    return
                with connection:
                    connection.settimeout(3)
                    try:
                        while True:
                            length = connection.recv(4, socket.MSG_WAITALL)
                            if len(length) < 4:
                                break
                            service = connection.recv(int(length, 16), socket.MSG_WAITALL).decode()
                            reply = answers.get(service, b"FAIL0004nope")
                            if reply == b"HANG":
                                connection.recv(1)
                                break
                            connection.sendall(reply)
                    except OSError:
                        pass

        threading.Thread(target=run, daemon=True).start()
        return server.getsockname()[1]

    def test_okay_fail_and_silence(self) -> None:
        port = self.serve({"host:transport:dev:1": b"OKAY", "vsock:3:5555": b"OKAY", "vsock:3:6000": b"HANG",
                           "vsock:3:7000": b"FAIL0007refused"})

        def ask(serial: str, vsock_port: int, seconds: float = 2) -> str:
            return runner.open_vsock_through_adbd(serial, vsock_port, seconds, port)

        self.assertEqual(ask("dev:1", 5555), "OKAY")
        self.assertEqual(ask("dev:1", 7000), "FAIL")
        self.assertEqual(ask("dev:1", 5556), "FAIL")
        self.assertEqual(ask("dev:1", 6000, 1), "TIMEOUT")
        self.assertEqual(ask("other", 5555), "FAIL")


class StartFailureTests(unittest.TestCase):
    """start_guest owns the emulator it spawned until it returns: whatever fails after the spawn stops it."""

    MARKER = "sms-start-failure-test"

    def start_and_fail(self, forward: object = 12345, **patched: object) -> list[subprocess.Popen]:
        """Runs start_guest with the launcher's steps replaced; returns the spawned children left running."""
        boot = runner.boot_android
        children: list[subprocess.Popen] = []
        real_popen = subprocess.Popen

        def spawn(command, *args, **kwargs):
            process = real_popen(command, *args, **kwargs)
            if self.MARKER in " ".join(map(str, command)):
                children.append(process)
            return process

        options = SimpleNamespace(instance=None, release=None, emulator=None, adb_port=5599, cpus=2,
                                  memory="2G", boot_timeout=5)
        steps = {
            "wait_for_adb": mock.DEFAULT,
            "wait_for_boot_completed": True,
            "provision_guest": mock.DEFAULT,
        }
        steps.update(patched)
        with tempfile.TemporaryDirectory(prefix="uml-sms-t-") as private, contextlib.ExitStack() as stack:
            directory = Path(private)
            stack.enter_context(mock.patch.object(boot, "parse_arguments", return_value=SimpleNamespace(
                emulator="fake", release="fake")))
            stack.enter_context(mock.patch.object(boot, "resolve_executable", return_value=sys.executable))
            stack.enter_context(mock.patch.object(boot, "release_path", return_value=directory))
            stack.enter_context(mock.patch.object(boot.android_instance, "read_release", return_value=object()))
            stack.enter_context(mock.patch.object(boot, "plan_start", return_value=object()))
            stack.enter_context(mock.patch.object(boot.android_instance, "apply"))
            stack.enter_context(mock.patch.object(boot.android_instance, "booted"))
            stack.enter_context(mock.patch.object(boot, "data_capacity", return_value=1))
            stack.enter_context(mock.patch.object(boot, "disconnect_adb"))
            stack.enter_context(mock.patch.object(boot, "emulator_command", return_value=[
                sys.executable, "-c", f"import time; time.sleep(120)  # {self.MARKER}"]))
            if isinstance(forward, BaseException):
                stack.enter_context(mock.patch.object(runner, "vsock_forward_port", side_effect=forward))
            else:
                stack.enter_context(mock.patch.object(runner, "vsock_forward_port", return_value=forward))
            for name, effect in steps.items():
                if isinstance(effect, BaseException):
                    stack.enter_context(mock.patch.object(boot, name, side_effect=effect))
                elif effect is mock.DEFAULT:
                    stack.enter_context(mock.patch.object(boot, name))
                else:
                    stack.enter_context(mock.patch.object(boot, name, return_value=effect))
            stack.enter_context(mock.patch.object(runner.subprocess, "Popen", side_effect=spawn))
            try:
                runner.start_guest(options, "adb", directory)
            except (runner.Failure, runner.boot_android.LauncherError):
                pass
            else:
                self.fail("start_guest returned although the step failed")
            finally:
                alive = [child for child in children if child.poll() is None]
                for child in alive:
                    child.kill()
                for child in children:
                    child.wait(timeout=10)
        return alive

    def test_a_failure_after_the_spawn_leaves_no_emulator(self) -> None:
        boot = runner.boot_android
        cases = {
            "the forward is never announced": {"forward": runner.Failure("injected: no forward")},
            "adb never answers": {"wait_for_adb": boot.LauncherError("injected: waiting for adb")},
            "Android never boots": {"wait_for_boot_completed": False},
            "provisioning fails": {"provision_guest": boot.LauncherError("injected: provisioning")},
        }
        for name, patched in cases.items():
            with self.subTest(name):
                alive = self.start_and_fail(**patched)
                self.assertEqual([], alive, "the emulator it spawned was left running")


class ProbeSourceTests(unittest.TestCase):
    def test_the_probe_sources_parse_and_name_what_the_runner_calls(self) -> None:
        sources = sorted(PROBE.glob("**/*.java"))
        self.assertEqual([path.name for path in sources], ["CommandReceiver.java", "ReceivedReceiver.java",
                                                         "VsockProbe.java"])
        manifest = (PROBE / "app/AndroidManifest.xml").read_text()
        self.assertIn(f'package="{runner.PROBE_PACKAGE}"', manifest)
        for name in ("RECEIVE_SMS", "MANAGE_VIRTUAL_MACHINE", "BROADCAST_SMS", "Telephony.SMS_RECEIVED",
                     ".CommandReceiver", ".ReceivedReceiver", 'android:debuggable="true"'):
            self.assertIn(name, manifest)
        for name in ('"vsock"', '"vm"', '"reset"', "vsock.txt", "vm.txt", "socket: errno="):
            self.assertIn(name, "".join(path.read_text() for path in sources))
        javac = jdk_tool("javac")
        if javac is None:
            self.skipTest("no JDK on PATH")
        with tempfile.TemporaryDirectory(prefix="sms-probe-") as classes:
            self.assertEqual(self.syntax_errors(javac, classes, sources), [])
            broken = Path(classes) / "Broken.java"
            broken.write_text("class Broken { int x = ; }\n")
            self.assertEqual(len(self.syntax_errors(javac, classes, [broken])), 1, "a syntax error must be seen")

    # What javac says of a name that Android's classes would have resolved: not a syntax error.
    UNRESOLVED = re.compile(r"cannot find symbol|package \S+ does not exist|does not override or implement a method")

    def syntax_errors(self, javac: str, classes: str, sources: list[Path]) -> list[str]:
        """The errors of a compile that are not unresolved names. The Android classes are not on the host. A JDK of 17
        or later stops after parsing with the options below (the older option name is for the JDKs before it, which
        ignore both); JDK 11 goes on and names every unresolved class, which this filters out."""
        compiled = subprocess.run(
            [javac, "-proc:none", "-XDshould-stop.ifNoError=PARSE", "-XDshould-stop.ifError=PARSE", "-d", classes,
             *(str(path) for path in sources)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120,
            check=False)
        errors = [line.split(" error: ", 1)[1] for line in compiled.stdout.splitlines() if " error: " in line]
        if compiled.returncode != 0 and not errors:
            self.fail(compiled.stdout)
        return [error for error in errors if not self.UNRESOLVED.search(error)]

    def test_the_build_script_names_the_probe_and_its_dex(self) -> None:
        script = (PROBE / "build-apk.sh").read_text()
        self.assertIn("AndariumSmsProbe.apk", script)
        self.assertIn("vsockprobe.dex", script)
        self.assertIn(runner.PROBE_PACKAGE, script)
        syntax = subprocess.run(["bash", "-n", str(PROBE / "build-apk.sh")], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        self.assertEqual(syntax.returncode, 0, syntax.stdout)

    def test_the_verifier_keeps_the_probe_out_of_an_image(self) -> None:
        verifier = (TESTS.parent / "android/lineage-24/tools/verify-target-files.py").read_text()
        self.assertIn('"AndariumSmsProbe"', verifier)


if __name__ == "__main__":
    unittest.main()
