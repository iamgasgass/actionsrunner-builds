#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""`ipad-automation.py watch` keeps a device's UI automation host serving.

A host whose runner iOS ended is replaced by a new one the moment it stops
serving when xcodebuild's relaunch of the runner initialized, because the
system still holds the approval and nobody is needed at the device. The watch
fails, once and for good, when the device asks for approval, or when the log
does not say that it did not. Every test runs the real script (its
supervisor included) against `automation_fakes.FakeDevice`, an `xcrun` and an
`xcodebuild` that are files in a scratch folder, so no call reaches a device or
Xcode; the rules about time run on a `ManualClock` that only the test moves.
The watch's waits are scaled down for the tests that run real processes; each
test names the rule it pins.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import warnings

sys.path.insert(0, str(Path(__file__).resolve().parent))
import automation_shards  # noqa: E402
from automation_fakes import (  # noqa: E402
    FakeDevice, LAUNCH_FAILED_BLOCK, LOST_BLOCK)

SCRIPT = Path(__file__).resolve().parents[3] / "Kernarium/scripts/ipad-automation.py"
SPEC = importlib.util.spec_from_file_location("ipad_automation", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
automation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(automation)

# The watch's real bounds, scaled so that a test takes seconds. HEARTBEAT_STALE
# stays well above the fake host's 0.1 s beat, and a test that does not wait
# for it to pass raises it further.
SCALED = {
    "WATCH_POLL": 0.1, "WATCH_PULL_EVERY": 0.3, "HEARTBEAT_STALE": 6.0,
    "WATCH_GONE_AGE": 1.0, "WATCH_RUNNER_WAIT": 4.0, "WATCH_BUSY_LIMIT": 1000,
    "WATCH_ATTEMPTS": 4, "WATCH_BACKOFF": (0.05, 0.05, 0.05),
    "WATCH_COMMAND_WAIT": 30, "WATCH_ALIVE_FRESH": 2.0, "WATCH_END_WAIT": 20,
    "SUPERVISOR_TERM_WAIT": 5, "CHILD_TERM_WAIT": 1, "FOREIGN_SETTLE": 0.6, "SEND_LIVENESS_EVERY": 0.5,
    "WATCH_UNKNOWN_LIMIT": 4.0,
}
SECONDS = 3 * 3600
# A `start` that is killed between spawning the supervisor and publishing its
# pid, as the reviewer's probe makes one: it pauses there, and the test kills it.
CRASH_STARTER = """
import importlib.util, os, pathlib, sys, time
spec = importlib.util.spec_from_file_location("ipad_automation", sys.argv[1])
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
real = a.write_json
def gated(path, data):
    if pathlib.Path(path).name == "host.json" and data.get("supervisor"):
        (pathlib.Path(os.environ["FAKE_ROOT"]) / "before-pid-publication").write_text("x")
        time.sleep(60)
    return real(path, data)
a.write_json = gated
a.launch_host(a.parse(sys.argv[2:]))
"""
PROMPT = (
    "2026-11-13 16:04:14.424136+0900 KernariumAutomation-Runner[11111:2222222] "
    "[Default] Failed to initialize for UI testing: Error Domain="
    'com.apple.dt.XCTest.XCTFuture Code=1000 "Timed out while enabling '
    'automation mode." UserInfo={NSLocalizedDescription=Timed out while '
    "enabling automation mode.}")


class ManualClock:
    """Time that moves only when the code under test waits or a test says so.

    A wait advances both clocks and also yields the processor for a moment, so
    that the real processes the watch looks at get to run."""

    def __init__(self) -> None:
        self.mono = 5000.0
        self.wall = 1_800_000_000.0
        self.waited = 0.0
        self.hooks: list = []

    def monotonic(self) -> float:
        return self.mono

    def time(self) -> float:
        return self.wall

    def advance(self, seconds: float) -> None:
        self.mono += seconds
        self.wall += seconds

        for hook in list(self.hooks):
            hook(self)

    def suspend(self, seconds: float) -> None:
        """The Mac sleeps: the wall clock moves, the monotonic one does not."""
        self.wall += seconds

    def sleep(self, seconds: float) -> None:
        self.waited += seconds
        if self.waited > 1000:
            raise RuntimeError("the code under test waits without a bound")
        self.advance(seconds)
        time.sleep(0.01)

    def wait(self, event: threading.Event, seconds: float) -> bool:
        if event.is_set():
            return True
        self.sleep(seconds)
        return event.is_set()


class Running:
    """A `watch` running in a thread of the test."""

    def __init__(self, options, stop: threading.Event) -> None:
        self.stop = stop
        self.code: int | None = None
        self.thread = threading.Thread(target=self.run, args=(options,), daemon=True)
        self.thread.start()

    def run(self, options) -> None:
        self.code = automation.command_watch(options, self.stop)

    def join(self, seconds: float = 30) -> int | None:
        self.thread.join(seconds)
        return None if self.thread.is_alive() else self.code

    def end(self) -> int | None:
        self.stop.set()
        return self.join()


class WatchTestCase(unittest.TestCase):
    def setUp(self) -> None:
        # A watch that ends leaves the hosts it started running; the device's
        # cleanup ends them, after their Popen objects are gone.
        warnings.simplefilter("ignore", ResourceWarning)
        self.device = FakeDevice()
        self.addCleanup(self.device.cleanup)
        environment = mock.patch.dict(os.environ, self.device.environment)
        environment.start()
        self.addCleanup(environment.stop)
        self.messages: list[str] = []
        self.patch(automation, "log", self.messages.append)
        for name, value in SCALED.items():
            self.patch(automation, name, value)
        self.launches: list = []
        self.watches: list[Running] = []
        self.addCleanup(self.reap)

    def patch(self, target, name: str, value) -> None:
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tune(self, **constants) -> None:
        for name, value in constants.items():
            self.patch(automation, name, value)

    def reap(self) -> None:
        for watch in self.watches:
            watch.end()
        for launch in self.launches:
            automation.end_host({"nonce": launch.nonce}, launch.process, 2)

    def options(self, *command: str):
        return automation.parse([
            "--device", self.device.udid, "--state-dir", str(self.device.state_dir),
            "--derived-data", str(self.device.derived), *command])

    def reports(self) -> list[str]:
        return ["--device-reports-dir", str(self.device.reports),
                "--leave-device-reports"]

    def watch_options(self, *extra: str):
        return self.options("watch", "--hours", "3", "--wait", "20",
                            *self.reports(), *extra)

    def run_watch(self, *extra: str) -> Running:
        watch = Running(self.watch_options(*extra), threading.Event())
        self.watches.append(watch)
        return watch

    def start_host(self, hours: float = 1):
        """A host the way `start` makes one, serving before it returns."""
        launch = automation.launch_host(
            self.options("start", "--hours", str(hours), *self.reports()))
        self.launches.append(launch)
        self.device.wait(lambda: self.device.serving(launch.nonce), 30,
                         "the first host serves")
        return launch

    def watch_over_host(self, *extra: str) -> str:
        """A host the way `start` makes one, and a watch that follows it: the
        watch replaces a host it has seen serve. Returns the host's nonce; the
        watch is `self.last_watch`."""
        host = self.start_host(hours=3)
        self.last_watch = self.run_watch(*extra)
        self.wait_record(state=automation.WATCHING)
        return host.nonce

    def record(self) -> dict:
        return automation.read_watch_record(self.options("status"))

    def wait_record(self, **expected) -> dict:
        def held():
            record = self.record()
            return record if all(record.get(key) == value
                                 for key, value in expected.items()) else None
        return self.device.wait(held, 30, f"the watch record says {expected}")

    def nonces(self) -> list[str]:
        return [item["nonce"] for item in self.device.invocations()]

    def watching(self, restarts: int) -> str:
        """Waits until the watch has the host that is its restart number
        `restarts`, and returns its nonce."""
        record = self.wait_record(state=automation.WATCHING, restarts=restarts)
        return record["host"]

    def progress(self, count: int = 3) -> None:
        """Waits until the watch has seen the host's heartbeat advance `count`
        more times (its record's alive_at moves each time): it has looked at
        the host that often, and whatever it did, it did by then."""
        last = [self.record().get("alive_at")]
        seen = [0]

        def moved() -> bool:
            now = self.record().get("alive_at")
            if now != last[0]:
                last[0] = now
                seen[0] += 1
            return seen[0] >= count
        self.device.wait(moved, 60, "the watch sees the heartbeat advance")

    def invoked(self, count: int) -> None:
        self.assertEqual(len(self.device.invocations()), count, self.messages)


class AdoptionTests(WatchTestCase):
    def test_a_serving_host_is_adopted_and_left_alone(self) -> None:
        # Rule: the watch never stops or restarts a host that serves.
        self.tune(HEARTBEAT_STALE=30)
        host = self.start_host()
        # Nothing but the heartbeat says which host this is, as for a host
        # that something else started.
        (self.device.state_dir / self.device.udid / "host.json").unlink()
        watch = self.run_watch()
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], host.nonce)
        self.assertEqual(record["restarts"], 0)
        self.progress()
        self.invoked(1)
        self.assertIsNone(host.process.poll())
        self.assertTrue(self.device.serving(host.nonce))
        self.assertEqual(watch.end(), 0)
        self.assertEqual(self.record()["state"], automation.STOPPED)
        # Ending the watch alone leaves the host as it was.
        self.assertIsNone(host.process.poll())
        self.assertTrue(self.device.serving(host.nonce))

    def test_the_last_beat_of_a_host_that_just_ended_is_not_a_host(self) -> None:
        # Rule: adoption needs a heartbeat that advances between two reads. The
        # last beat of a host that ended a moment ago still looks recent, and
        # adopting it would leave the device without a host until it aged out.
        self.tune(HEARTBEAT_STALE=60)
        host = self.start_host()
        self.device.control(host.nonce, "die")
        self.device.wait(lambda: host.process.poll() is not None, 15,
                         "the host ended")
        self.run_watch()
        record = self.wait_record(state=automation.WATCHING)
        self.assertNotEqual(record["host"], host.nonce)
        self.assertEqual(record["restarts"], 1)
        self.invoked(2)

    def test_a_host_that_is_still_starting_is_waited_for(self) -> None:
        # Rule: a `start` in flight is not taken over; the owner may be
        # approving it, and a second host would put a second prompt up.
        self.tune(HEARTBEAT_STALE=30)
        self.device.scenarios([{"kind": "serve", "hold": True}])
        launch = automation.launch_host(
            self.options("start", "--hours", "1", *self.reports()))
        self.launches.append(launch)
        self.device.wait(lambda: self.device.invocations()
                         and automation.recorded_supervisor(
                             automation.local_record(self.options("status"))),
                         30, "the supervisor runs the held host")
        watch = self.run_watch()
        self.device.wait(lambda: any("waiting for it" in message
                                     for message in self.messages), 30,
                         "the watch waits for the host")
        self.invoked(1)
        self.assertEqual(self.record()["state"], automation.STARTING)
        self.assertIsNone(launch.process.poll())
        self.device.control(launch.nonce, "go")
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], launch.nonce)
        self.progress()
        self.invoked(1)
        self.assertEqual(watch.end(), 0)

    def test_a_device_with_nothing_to_read_is_not_a_device_without_a_host(self) -> None:
        # Rule (R3): the watch starts a host only for one it has seen. A device
        # whose heartbeat cannot be read (a host that never was, or a read that
        # fails) is a device it cannot tell about: it says so after the bound,
        # replaced nothing, and ends with its own status.
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_WATCH_CANNOT_OBSERVE,
                         self.messages)
        record = self.record()
        self.assertEqual(record["state"], automation.CANNOT_OBSERVE)
        self.assertIn("nothing was replaced", record["detail"])
        self.assertEqual(self.device.invocations(), [])


class ReplacementTests(WatchTestCase):
    def test_a_host_that_ends_is_replaced_with_the_watchs_options(self) -> None:
        # Rule: a host that stops serving is replaced at once, with the watch's
        # own options (here --hours 3 against the first host's 1).
        host = self.start_host(hours=1)
        self.run_watch()
        self.wait_record(state=automation.WATCHING)
        self.assertEqual(self.device.invocations()[0]["seconds"], 3600)
        self.device.control(host.nonce, "die")
        new = self.watching(restarts=1)
        invocations = self.device.invocations()
        self.assertEqual([item["nonce"] for item in invocations], [host.nonce, new])
        replacement = invocations[1]
        self.assertEqual(replacement["seconds"], SECONDS)
        supervisor = replacement["supervisor"]
        self.assertIn(f"--seconds {SECONDS}", supervisor)
        # Each collection of the device's reports gets a directory of its own
        # beneath the one configured.
        self.assertIn(f"--device-reports-dir {self.device.reports}/host-", supervisor)
        self.assertIn("--leave-device-reports", supervisor)
        self.assertIn(f"--state-dir {self.device.state_dir}", supervisor)
        self.assertIn(f"platform=iOS,id={self.device.udid}", replacement["argv"])
        self.assertTrue(self.device.serving(new))
        self.assertIn("supervisor ended", self.record()["last_end"]["reason"])
        self.device.wait(lambda: host.process.poll() is not None, 15,
                         "the first host's supervisor has ended")

    def test_the_host_the_watch_starts_is_watched_too(self) -> None:
        # Rule: the replacement is watched like the host before it.
        first = self.watch_over_host()
        self.device.control(first, "die")
        second = self.watching(restarts=1)
        self.device.control(second, "die")
        third = self.watching(restarts=2)
        self.assertEqual(len({first, second, third}), 3)
        self.assertEqual(self.nonces(), [first, second, third])

    def test_a_silent_host_is_replaced_when_its_heartbeat_goes_stale(self) -> None:
        # Rule: with the processes alive and nothing logged, a host whose
        # heartbeat stops is replaced after HEARTBEAT_STALE, and ended.
        self.tune(HEARTBEAT_STALE=2.0)
        first = self.watch_over_host()
        self.device.control(first, "silent")
        began = time.monotonic()
        second = self.watching(restarts=1)
        self.assertGreater(time.monotonic() - began, 1.0)
        old = self.device.invocations()[0]
        self.device.wait(lambda: not self.device.alive(old["pid"]), 15,
                         "the silent xcodebuild is ended")
        self.assertIn("heartbeat", self.record()["last_end"]["reason"])
        self.assertTrue(self.device.serving(second))

    def test_a_host_whose_supervisor_alone_ended_still_serves(self) -> None:
        # Rule: the processes only hurry the verdict. A runner that keeps
        # beating serves, whatever happened to its supervisor.
        self.tune(HEARTBEAT_STALE=30)
        first = self.watch_over_host()
        supervisor = self.device.invocations()[0]["ppid"]
        os.kill(supervisor, 9)
        self.device.wait(lambda: not self.device.alive(supervisor), 10,
                         "the supervisor ends")
        # Each read the watch makes from here on is one that the supervisor's
        # end makes quick, and none of them may end the host.
        self.progress(10)
        self.assertTrue(self.device.serving(first))
        self.assertEqual(self.record()["restarts"], 0)
        self.invoked(1)

    def test_a_busy_host_is_not_a_dead_one(self) -> None:
        # Rule: a command that runs long leaves the heartbeat fresh, because
        # the host beats from a queue no command blocks, and the host is left
        # alone; only a command past WATCH_BUSY_LIMIT is a hung host.
        self.tune(WATCH_BUSY_LIMIT=1000, HEARTBEAT_STALE=2.0)
        first = self.watch_over_host()
        self.device.control(first, "busy")
        self.device.wait(lambda: (self.device.heartbeat() or {}).get("command"),
                         10, "the heartbeat shows the command")
        self.progress(10)
        self.assertTrue(self.device.serving(first))
        self.invoked(1)

    def test_a_host_stuck_in_one_command_is_replaced(self) -> None:
        self.tune(WATCH_BUSY_LIMIT=1.5)
        first = self.watch_over_host()
        self.device.control(first, "busy")
        second = self.watching(restarts=1)
        self.assertNotEqual(first, second)
        self.assertIn("hung", self.record()["last_end"]["reason"])

    def test_a_host_that_reaches_its_lifetime_is_replaced(self) -> None:
        # Rule: a host whose own lifetime (--hours) ended is replaced too.
        first = self.watch_over_host()
        self.device.control(first, "lifetime")
        self.watching(restarts=1)
        self.assertIn("lifetime", self.record()["last_end"]["reason"])

    def test_a_failed_read_does_not_end_a_serving_host(self) -> None:
        # Rule (R3): a heartbeat that cannot be read is not a heartbeat that
        # stopped. The fake host beats on while every read fails for far longer
        # than HEARTBEAT_STALE, and the watch leaves it alone.
        self.tune(HEARTBEAT_STALE=1.0, WATCH_GONE_AGE=0.5, WATCH_UNKNOWN_LIMIT=1000)
        host = self.start_host()
        self.run_watch()
        self.wait_record(state=automation.WATCHING)
        real = automation.host_state
        failures = []
        failing = threading.Event()
        failing.set()

        def host_state(options, timeout=60):
            if failing.is_set() and threading.current_thread().name != "MainThread":
                failures.append(time.monotonic())
                return None
            return real(options, timeout)
        self.patch(automation, "host_state", host_state)
        self.device.wait(lambda: len(failures) >= 1 and
                         failures[-1] - failures[0] > 3 * automation.HEARTBEAT_STALE,
                         60, "reads fail for longer than the heartbeat bound")
        failing.clear()
        self.progress()
        self.invoked(1)
        self.assertTrue(self.device.serving(host.nonce))
        self.assertEqual(self.record()["restarts"], 0)

    def test_a_watch_that_cannot_read_a_serving_host_leaves_it_alone(self) -> None:
        # Rule (R3, the startup case): a watch that starts over a host that has
        # served for an hour, and whose every read fails, is a watch that does
        # not know the host is gone. It replaces nothing and ends with the
        # status that says so; the host beats on.
        host = self.start_host()
        record = automation.local_record(self.options("status"))
        record["started"] = time.time() - 3600
        automation.write_json(self.device.state_dir / self.device.udid / "host.json",
                              record)
        self.device.unreachable(True)
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_WATCH_CANNOT_OBSERVE,
                         self.messages)
        self.device.unreachable(False)
        self.assertEqual(self.record()["state"], automation.CANNOT_OBSERVE)
        self.assertIsNone(host.process.poll())
        self.assertTrue(self.device.serving(host.nonce))
        self.assertLess(self.device.silent_for(), 2)
        self.invoked(1)


class FailureTests(WatchTestCase):
    def test_the_approval_prompt_fails_the_watch_once(self) -> None:
        # Rule: when the device asks for approval the watch ends that attempt,
        # records it, exits non-zero and does not try again. The signal is
        # XCTest's own line; a new watch starts nothing until a `start` served.
        self.tune(HEARTBEAT_STALE=3.0)
        self.device.scenarios([{"kind": "serve"}, {"kind": "approval"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        invocations = self.device.invocations()
        self.assertEqual(len(invocations), 2)
        record = self.record()
        self.assertEqual(record["state"], automation.NEEDS_APPROVAL)
        self.assertIn("start", record["detail"])
        self.assertGreater(record["since"], 0)
        self.assertFalse(self.device.alive(invocations[1]["ppid"]))
        status = automation.watch_summary(self.options("status"))
        self.assertFalse(status["running"])
        self.assertEqual(status["meaning"], "needs approval at the device")
        self.assertIn("observed", status["approval"])
        # A second watch does not start a host either.
        self.assertEqual(self.run_watch().join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)
        self.assertEqual(self.record()["state"], automation.NEEDS_APPROVAL)
        # A `start` the owner approved ends the refusal. The first host's last
        # heartbeat still counts as serving for HEARTBEAT_STALE.
        self.device.wait(lambda: self.device.silent_for() > automation.HEARTBEAT_STALE,
                         30, "the first host's heartbeat goes stale")
        self.device.scenarios([{"kind": "serve"}])
        self.assertEqual(automation.command_start(self.options(
            "start", "--hours", "1", *self.reports())), 0)
        third = self.device.invocations()[-1]
        self.assertEqual(self.record()["state"], automation.STOPPED)
        self.assertNotIn("approval", automation.watch_summary(self.options("status")))
        again = self.run_watch()
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], third["nonce"])
        self.assertEqual(again.end(), 0)

    def test_a_cancelled_authentication_fails_the_watch_like_the_timeout(self) -> None:
        # Rule (R1/R2): the device's own failure when the owner's
        # authentication for UI automation was cancelled (by the system, here)
        # is the approval signal too: exit 4, no retry, the latch kept.
        self.tune(HEARTBEAT_STALE=3.0)
        self.device.scenarios([{"kind": "serve"},
                               {"kind": "approval", "signal": "authentication"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)
        self.assertEqual(self.record()["state"], automation.NEEDS_APPROVAL)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "observed")
        self.assertIn("LocalAuthentication", latch["detail"])
        self.assertEqual(self.run_watch().join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)

    def test_start_says_a_cancelled_authentication_was_not_approved(self) -> None:
        self.device.scenarios([{"kind": "approval", "signal": "authentication"}])
        status = automation.command_start(self.options(
            "start", "--hours", "1", "--wait", "30", *self.reports()))
        self.assertEqual(status, automation.EXIT_NO_HOST)
        self.assertTrue(any("approval it asked for was not given" in message
                            for message in self.messages), self.messages)

    def test_a_relaunched_runner_the_device_would_not_approve_ends_the_watch(self) -> None:
        # Rule (R1): a host served, its runner died, and xcodebuild started the
        # runner again; that runner may ask the device for its approval. The
        # watch does not start a host that would put the same prompt up
        # again: it exits 4, with the latch, having started nothing. Whether
        # the failure line came before it looked (observed) or not (possible:
        # the log says nothing of how the runner's initialization went, and
        # nothing is not taken for safe) makes no difference to what it does.
        for failure, kind in (("authentication", "observed"),
                              ("authentication-localized", "observed"),
                              ("timeout", "observed"), ("quiet", "possible")):
            with self.subTest(failure):
                self.setUp()
                self.device.scenarios([{"kind": "serve"}])
                first = self.watch_over_host()
                watch = self.last_watch
                self.device.control(first, f"relaunch-{failure}")
                self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL,
                                 self.messages)
                self.invoked(1)
                self.assertEqual(self.record()["state"], automation.NEEDS_APPROVAL)
                latch = automation.ApprovalLatch(self.options("status")).read()
                self.assertEqual(latch["kind"], kind)
                self.assertEqual(self.record()["restarts"], 0)
                self.assertEqual(self.run_watch().join(), automation.EXIT_NEEDS_APPROVAL)
                self.invoked(1)

    def test_a_relaunched_runner_that_initialized_is_replaced_at_once(self) -> None:
        # Rule (round 4): xcodebuild started the runner again and the log shows
        # it initialized (the restart notice, then the totals of a run of no
        # tests): the system still held the approval, a new host serves with
        # nobody at the device, so there is no approval risk. The watch
        # replaces the host without a latch and keeps watching.
        self.device.scenarios([{"kind": "serve"}, {"kind": "serve"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "relaunch-initialized")
        second = self.watching(restarts=1)
        self.assertNotEqual(first, second)
        self.assertIsNone(watch.code)
        self.invoked(2)
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())
        self.assertTrue(self.device.serving(second))
        self.assertTrue(any("initialized" in line and "replacing the host" in line
                            for line in self.messages), self.messages)
        self.assertFalse(self.device.alive(self.device.invocations()[0]["ppid"]))

    def test_the_replacement_of_an_initialized_relaunch_that_fails_ends_the_watch(self) -> None:
        # Rule (round 4, the residual case): one replacement per death. When
        # the replacement itself fails to initialize, the watch ends with
        # needs-approval as it always did, and starts no third host.
        self.device.scenarios([{"kind": "serve"}, {"kind": "approval"},
                               {"kind": "serve"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "relaunch-initialized")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(2)
        self.assertEqual(self.record()["state"], automation.NEEDS_APPROVAL)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "observed")
        self.assertEqual(latch["nonce"], self.device.invocations()[1]["nonce"])

    def test_a_relaunch_that_initialized_and_a_later_one_that_failed_needs_the_owner(self) -> None:
        # Rule (round 4, the mixed case): one relaunched runner initialized and
        # the runner started again after it failed to initialize. The failure
        # is the owner's to answer: the watch exits 4 and starts nothing.
        for failure in ("timeout", "authentication"):
            with self.subTest(failure):
                self.setUp()
                self.device.scenarios([{"kind": "serve"}, {"kind": "serve"}])
                first = self.watch_over_host()
                watch = self.last_watch
                self.device.control(first, f"relaunch-initialized-then-{failure}")
                self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL,
                                 self.messages)
                self.invoked(1)
                latch = automation.ApprovalLatch(self.options("status")).read()
                self.assertEqual(latch["kind"], "observed")
                self.assertEqual(latch["nonce"], first)

    def test_a_log_cut_in_the_middle_of_the_relaunch_is_not_taken_for_safe(self) -> None:
        # Rule (round 4, an unknown): the relaunched runner came up and
        # xcodebuild's restart notice is there, but the totals that show the
        # run are not. A runner that is still starting may be waiting for a
        # prompt that nobody answers, and a host started now would put a
        # second one up: the watch records "possible", exits 4, and starts
        # nothing. Only a log that shows the whole pattern lets it restart.
        self.device.scenarios([{"kind": "serve"}, {"kind": "serve"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "relaunch-restarting")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(1)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "possible")
        self.assertEqual(latch["nonce"], first)

    def test_a_watch_that_takes_over_after_an_initialized_relaunch_replaces_the_host(self) -> None:
        # Rule (round 4): the watch that follows a host did not see the death;
        # the log it reads shows the relaunch initialized, so the stale
        # heartbeat is a dead host to replace, not one that waits for the
        # owner.
        self.device.scenarios([{"kind": "serve"}, {"kind": "serve"}])
        host = self.start_host()
        self.device.control(host.nonce, "relaunch-initialized")
        self.device.wait(lambda: host.process.poll() is not None, 20,
                         "xcodebuild ends and the supervisor with it")
        watch = self.run_watch()
        second = self.watching(restarts=1)
        self.assertNotEqual(host.nonce, second)
        self.assertIsNone(watch.code)
        self.invoked(2)
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())

    def test_a_relaunched_runner_whose_outcome_comes_late_is_not_retired_unrecorded(self) -> None:
        # Rule (R1, sequence 1): the relaunched runner's approval outcome
        # arrives long after the watch has decided (here 8 s after the runner
        # came up, and the watch ends it in about a second). The watch records
        # that the device may have been asked BEFORE it ends the runner, and
        # starts no second host that would put a second prompt up.
        self.device.scenarios([{"kind": "serve", "relaunch_after": 8}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "relaunch-authentication")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(1)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "possible")
        self.assertEqual(latch["nonce"], first)
        self.assertFalse(self.device.alive(self.device.invocations()[0]["ppid"]))

    def test_a_takeover_reads_what_a_relaunched_runner_said_not_an_old_heartbeat(self) -> None:
        # Rule (R1, sequence 2): the old test left a heartbeat, the relaunched
        # runner logged the failed authentication and exited, and a new watch
        # takes over. The heartbeat that stands still is not a host that serves,
        # and the log's failure is not suppressed by it: nothing is started.
        host = self.start_host()
        self.device.control(host.nonce, "relaunch-authentication")
        self.device.wait(lambda: host.process.poll() is not None, 20,
                         "the relaunch fails and the supervisor ends")
        self.assertIn("LocalAuthentication", host.log_path.read_text())
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(1)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "observed")
        self.assertEqual(latch["nonce"], host.nonce)

    def test_a_producer_killed_before_it_says_how_initialization_went_is_not_retried(self) -> None:
        # Rule (R1, sequence 3): the replacement's runner came up and xcodebuild
        # was killed before the device's outcome reached the log. The watch does
        # not take that for an ordinary failure: it records that the device may
        # have been asked, exits 4 and starts no second host.
        self.device.scenarios([{"kind": "serve"}, {"kind": "early-death"},
                               {"kind": "serve"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(2)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "possible")
        self.assertEqual(latch["nonce"], self.device.invocations()[1]["nonce"])
        self.assertEqual(self.run_watch().join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)

    def test_a_runner_that_comes_up_and_never_serves_may_have_asked_for_approval(self) -> None:
        # Rule (R1): a runner that is up and silent for WATCH_RUNNER_WAIT is
        # not shown to have asked for nothing, and is not retried: the
        # watch ends it, records "possible" and exits 4.
        self.tune(WATCH_RUNNER_WAIT=1.0)
        self.device.scenarios([{"kind": "serve"}, {"kind": "up-silent"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(2)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "possible")
        for item in self.device.invocations():
            self.assertFalse(self.device.alive(item["ppid"]))

    def test_a_start_that_fails_before_any_runner_is_not_tried_again(self) -> None:
        # Rule: a launch whose runner never came up (xcodebuild ended with an
        # error, no device) asked nothing of the device; it ends the watch with
        # its own state and no latch, and no second host is started after one
        # death.
        self.device.scenarios([{"kind": "serve"}, {"kind": "exit", "status": 70}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_WATCH_GAVE_UP, self.messages)
        self.invoked(2)
        record = self.record()
        self.assertEqual(record["state"], automation.START_FAILED)
        self.assertIn("status 70", record["detail"])
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())

    def test_a_runner_that_does_not_come_up_in_time_asked_nothing(self) -> None:
        # The runner is the first thing that can ask for an approval; one that
        # never came up cannot have.
        self.device.scenarios([{"kind": "serve"}, {"kind": "no-runner"}])
        self.tune(WATCH_RUNNER_WAIT=1.0)
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_WATCH_GAVE_UP, self.messages)
        self.invoked(2)
        self.assertIn("did not come up", self.record()["detail"])
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())

    def test_a_missing_device_is_retried_a_bounded_number_of_times(self) -> None:
        # Rule: a start that is refused before anything starts is tried a few
        # times with a short backoff, then ends the watch; never an endless loop.
        calls = []
        real = automation.check_report_slots

        def refuse(options, processes):
            if options.command == "watch":
                calls.append(1)
                return False
            return real(options, processes)
        self.patch(automation, "check_report_slots", refuse)
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_WATCH_GAVE_UP)
        self.assertEqual(len(calls), automation.WATCH_ATTEMPTS)
        self.invoked(1)
        record = self.record()
        self.assertEqual(record["state"], automation.START_FAILED)
        self.assertIn("report store", record["detail"])

    def test_no_built_host_ends_the_watch_at_once(self) -> None:
        # Rule: a failure that trying again cannot change is not retried.
        first = self.watch_over_host()
        watch = self.last_watch
        for run in (self.device.derived / "Build/Products").glob("*.xctestrun"):
            run.unlink()
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_WATCH_GAVE_UP)
        self.assertEqual(self.record()["state"], automation.CANNOT_START)
        self.assertIn("run `build` first", self.record()["detail"])
        self.invoked(1)

    def test_too_many_restarts_in_an_hour_end_the_watch(self) -> None:
        # Rule: more than --max-restarts replacements in an hour end the watch
        # with a state of its own, and a new watch inside that hour does too.
        self.tune(HEARTBEAT_STALE=2.0)
        first = self.watch_over_host("--max-restarts", "2")
        watch = self.last_watch
        self.device.control(first, "die")
        second = self.watching(restarts=1)
        self.device.control(second, "die")
        third = self.watching(restarts=2)
        self.device.control(third, "die")
        self.assertEqual(watch.join(), automation.EXIT_WATCH_GAVE_UP)
        record = self.record()
        self.assertEqual(record["state"], automation.RESTART_STORM)
        self.assertIn("bound is 2", record["detail"])
        self.invoked(3)
        again = self.run_watch("--max-restarts", "2")
        self.assertEqual(again.join(), automation.EXIT_WATCH_GAVE_UP)
        self.invoked(3)
        self.assertEqual(self.record()["state"], automation.RESTART_STORM)

    def test_restarts_older_than_an_hour_do_not_count(self) -> None:
        # Rule: only replacements inside the window count. Two old ones, with
        # a bound of two, would end the watch before it starts a host.
        host = self.start_host()
        self.device.control(host.nonce, "die")
        self.device.wait(lambda: host.process.poll() is not None, 15, "the host ended")
        directory = self.device.state_dir / self.device.udid
        old = time.time() - 2 * automation.WATCH_STORM_WINDOW
        (directory / "watch.json").write_text(json.dumps(
            {"state": automation.STOPPED, "restart_times": [old, old + 1]}))
        watch = self.run_watch("--max-restarts", "2")
        self.watching(restarts=1)
        self.assertEqual(watch.end(), 0)


class OneWatchTests(WatchTestCase):
    def test_a_second_watch_for_the_device_refuses(self) -> None:
        # Rule: one watch per device and state directory.
        self.tune(HEARTBEAT_STALE=30)
        host = self.start_host()
        first = self.run_watch()
        self.wait_record(state=automation.WATCHING)
        status = automation.watch_summary(self.options("status"))
        self.assertTrue(status["running"])
        self.assertEqual(status["pid"], os.getpid())
        second = Running(self.watch_options(), threading.Event())
        self.watches.append(second)
        self.assertEqual(second.join(10), automation.EXIT_WATCH_LOCKED)
        self.assertEqual(self.record()["state"], automation.WATCHING)
        self.assertEqual(first.end(), 0)
        self.assertFalse(automation.watch_summary(self.options("status"))["running"])
        third = self.run_watch()
        self.assertEqual(self.wait_record(state=automation.WATCHING)["host"], host.nonce)
        self.assertEqual(third.end(), 0)


class CommandTests(WatchTestCase):
    def ping(self, results: list, timeout: int = 20) -> threading.Thread:
        def send() -> None:
            try:
                results.append(automation.send(
                    self.options("ping"), {"op": "ping"}, timeout))
            except automation.NoHost as error:
                results.append(error)
        thread = threading.Thread(target=send, daemon=True)
        thread.start()
        return thread

    def test_a_command_waits_through_a_replacement(self) -> None:
        # Rule: a command sent while the watch is starting a host waits for it
        # and is answered by it.
        self.device.scenarios([{"kind": "serve"}, {"kind": "serve", "hold": True}])
        first = self.watch_over_host()
        self.device.control(first, "die")
        self.wait_record(state=automation.RESTARTING)
        self.device.wait(lambda: len(self.device.invocations()) == 2, 15,
                         "the replacement starts")
        results: list = []
        thread = self.ping(results)
        self.device.wait(lambda: any("its watch is starting" in message
                                     for message in self.messages), 15,
                         "the command says it waits")
        self.assertEqual(results, [])
        second = self.device.invocations()[1]["nonce"]
        self.device.control(second, "go")
        thread.join(30)
        self.assertEqual(len(results), 1, self.messages)
        self.assertEqual(results[0]["nonce"], second)

    def test_a_command_waits_for_a_host_that_stopped_beating(self) -> None:
        # Rule: the watch may not have noticed a host that stopped beating
        # yet; a command is sent only while the watch has seen the heartbeat
        # advance lately, and is answered by the successor.
        self.tune(HEARTBEAT_STALE=3.0, WATCH_ALIVE_FRESH=1.0)
        first = self.watch_over_host()
        self.device.control(first, "silent")
        # The command goes only when the watch has seen a beat lately, in its
        # own record: wait until that is no longer so, and the watch has not
        # yet ended the host.
        self.device.wait(lambda: time.time() - self.record().get("alive_at", 0)
                         > automation.WATCH_ALIVE_FRESH + 0.2, 10,
                         "the watch has not seen the host beat lately")
        results: list = []
        self.ping(results).join(30)
        self.assertEqual(len(results), 1, self.messages)
        second = self.device.invocations()[-1]["nonce"]
        self.assertNotEqual(second, first)
        self.assertEqual(results[0]["nonce"], second)

    def test_a_command_is_not_held_back_by_the_devices_clock(self) -> None:
        # Rule (R3): freshness is the watch's own observation, in the Mac's
        # time. A device whose clock is hours off beats as it always did, and a
        # command is sent at once.
        self.tune(HEARTBEAT_STALE=30)
        host = self.start_host()
        self.run_watch()
        self.wait_record(state=automation.WATCHING)
        self.progress()
        state = self.device.heartbeat()
        self.assertIsNotNone(state)
        real = automation.host_state
        self.patch(automation, "host_state", lambda options, timeout=60: dict(
            real(options, timeout) or {}, time=time.time() + 7200))
        results: list = []
        self.ping(results).join(30)
        self.assertEqual(len(results), 1, self.messages)
        self.assertEqual(results[0]["nonce"], host.nonce)
        self.assertFalse(any("waiting up to" in message for message in self.messages))

    def test_a_command_still_fails_without_a_watch(self) -> None:
        # Rule: with no watch running, a command to a host that ended fails
        # with status 3 as before.
        host = self.start_host()
        self.device.control(host.nonce, "die")
        self.tune(HEARTBEAT_STALE=1.5)
        self.device.wait(lambda: not self.device.serving(), 10, "the host ended")
        self.assertEqual(automation.main([
            "--device", self.device.udid, "--state-dir", str(self.device.state_dir),
            "--timeout", "5", "ping"]), automation.EXIT_NO_HOST)
        self.assertNotIn("replacing", " ".join(self.messages))

    def test_a_command_gives_up_when_the_replacement_is_not_made(self) -> None:
        # Rule: the wait is bounded. The replacement never serves here.
        self.tune(WATCH_COMMAND_WAIT=2, WATCH_RUNNER_WAIT=30)
        self.device.scenarios([{"kind": "serve"}, {"kind": "up-silent"}])
        first = self.watch_over_host()
        self.device.control(first, "die")
        self.wait_record(state=automation.RESTARTING)
        self.device.wait(lambda: len(self.device.invocations()) == 2, 15,
                         "the replacement starts")
        results: list = []
        self.ping(results).join(20)
        self.assertEqual(len(results), 1)
        self.assertIsInstance(results[0], automation.NoHost)
        self.assertIn("still being replaced", str(results[0]))

    def test_a_command_lost_to_a_replacement_gets_the_no_host_result(self) -> None:
        # Rule (D): a command pushed to a host that has just ended is not
        # replayed to its successor, which clears the inbox: the sender is told
        # the host was replaced, and does not wait out its whole timeout. The
        # dead host's last beat is made to count for ever, so that only the
        # replacement can tell the sender; the wait before sending is made to
        # pass, as when the watch has not yet noticed.
        self.tune(HEARTBEAT_STALE=3600, SEND_LIVENESS_EVERY=2.0)
        self.patch(automation, "wait_for_replacement", lambda options, clock=None: None)
        first = self.watch_over_host()
        self.device.control(first, "die")
        self.device.wait(lambda: not self.device.serving(first), 10,
                         "the host ended")
        results: list = []
        self.ping(results, timeout=3).join(60)
        self.assertEqual(len(results), 1, self.messages)
        self.assertIsInstance(results[0], automation.NoHost)
        self.assertIn("replaced", str(results[0]))
        self.assertNotIn("no result", str(results[0]))
        self.assertEqual(self.device.heartbeat()["served"], 0)


class ClockBoundTests(unittest.TestCase):
    """What the watch does with time, run on a clock the test moves."""

    def setUp(self) -> None:
        self.scratch = __import__("tempfile").TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.clock = ManualClock()
        self.messages: list[str] = []
        for name, value in (("log", self.messages.append),):
            patcher = mock.patch.object(automation, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def options(self, *command: str):
        return automation.parse(["--device", "00000000-0000000000000000",
                                 "--state-dir", self.scratch.name, *command])

    def record(self, **fields) -> None:
        directory = Path(self.scratch.name) / "00000000-0000000000000000"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "watch.json").write_text(json.dumps(fields))

    def test_the_command_wait_is_a_hard_bound_with_no_device_read(self) -> None:
        # Rule (R9): a command waits at most WATCH_COMMAND_WAIT for a
        # replacement, however slow the device is: the wait makes no device
        # read at all, so no read can carry it past the bound.
        options = self.options("ping")
        self.record(state=automation.STARTING, alive_at=0)

        def never(*arguments, **keywords):
            raise AssertionError("the wait read the device")
        with mock.patch.object(automation, "watcher_pid", lambda options: 1), \
                mock.patch.object(automation, "host_state", never), \
                mock.patch.object(automation, "pull", never):
            began = self.clock.monotonic()
            with self.assertRaises(automation.NoHost):
                automation.wait_for_replacement(options, self.clock)
        waited = self.clock.monotonic() - began
        self.assertGreaterEqual(waited, automation.WATCH_COMMAND_WAIT)
        self.assertLessEqual(waited, automation.WATCH_COMMAND_WAIT + 2)

    def test_questions_about_processes_never_carry_the_wait_past_its_bound(self) -> None:
        # Rule (R9, the reviewer's probe): each lookup of the watch's identity
        # can block, and the deadline starts before the first. Every one is
        # given what is left of it, an expired deadline fails the command even
        # when the record has just turned ready, and nothing outlasts the bound
        # by more than the 0.1 s a lookup is always given.
        options = self.options("ping")
        clock = self.clock
        asked = []

        def watcher(_):
            allowed = automation.query_timeout(10)
            asked.append(allowed)
            clock.advance(allowed)     # a lookup that takes as long as it may
            return 77

        def record(_):
            if clock.monotonic() - began >= 176:
                return {"state": automation.WATCHING, "alive_at": clock.time()}
            return {"state": automation.STARTING, "alive_at": 0}
        began = clock.monotonic()
        with mock.patch.object(automation, "watcher_pid", watcher), \
                mock.patch.object(automation, "read_watch_record", record):
            with self.assertRaises(automation.NoHost):
                automation.wait_for_replacement(options, clock)
        self.assertLessEqual(clock.monotonic() - began, automation.WATCH_COMMAND_WAIT + 0.2)
        self.assertLess(min(asked), 10)
        # A record that is ready in time is accepted.
        began = clock.monotonic()
        with mock.patch.object(automation, "watcher_pid", lambda options: 77), \
                mock.patch.object(automation, "read_watch_record", lambda options: {
                    "state": automation.WATCHING, "alive_at": clock.time()}):
            automation.wait_for_replacement(options, clock)
        self.assertEqual(clock.monotonic() - began, 0)

    def test_a_budget_gives_a_process_question_what_is_left(self) -> None:
        self.assertEqual(automation.query_timeout(10), 10)
        left = [3.0]
        with automation.Budget(lambda: left[0]):
            self.assertEqual(automation.query_timeout(10), 3.0)
            left[0] = -5
            self.assertEqual(automation.query_timeout(10), 0.1)
            with mock.patch.object(automation.subprocess, "run") as run:
                run.return_value = mock.Mock(returncode=1, stdout="")
                automation.process_instance(1)
            self.assertEqual(run.call_args.kwargs["timeout"], 0.1)
        self.assertEqual(automation.query_timeout(10), 10)

    def test_the_reads_of_a_command_never_outlast_its_own_wait(self) -> None:
        # Rule (R9): each device read of `send` is given what is left of the
        # command's own wait (at most 60 s), not a flat 60 s that could carry it
        # past its deadline.
        options = self.options("ping")
        timeouts = []

        def read(options, *arguments, **keywords):
            timeouts.append(arguments[-1] if arguments else keywords["timeout"])
            return None

        def state(options, timeout=60):
            timeouts.append(timeout)
            return {"nonce": "n" * 32, "time": time.time()}
        with mock.patch.object(automation, "wait_for_replacement",
                               lambda options, clock=None: None), \
                mock.patch.object(automation, "host_state", state), \
                mock.patch.object(automation, "push", lambda *a, **k: None), \
                mock.patch.object(automation, "pull", lambda options, source, destination, timeout=60: (
                    timeouts.append(timeout), False)[1]):
            with self.assertRaises(automation.NoHost):
                automation.send(options, {"op": "ping"}, 20, self.clock)
        self.assertTrue(timeouts)
        self.assertLessEqual(max(timeouts), 50)
        # Near the end of the wait, a read is given only what remains of it.
        self.assertLessEqual(min(timeouts), 2)

    def test_a_command_goes_once_the_watch_has_seen_the_host_beat(self) -> None:
        options = self.options("ping")
        self.record(state=automation.WATCHING, alive_at=0)

        def beat(clock) -> None:
            if clock.monotonic() - 5000 >= 10:
                self.record(state=automation.WATCHING, alive_at=clock.time())
        self.clock.hooks.append(beat)
        with mock.patch.object(automation, "watcher_pid", lambda options: 1):
            automation.wait_for_replacement(options, self.clock)
        self.assertGreaterEqual(self.clock.monotonic() - 5000, 10)
        self.assertLess(self.clock.monotonic() - 5000, 14)

    def test_a_start_that_waits_longer_than_the_watch_is_waited_for(self) -> None:
        # Rule (R4): the wait the starting `start` recorded is the one the
        # watch honours, not the watch's own --wait.
        options = self.options("watch", "--wait", "10")
        directory = Path(self.scratch.name) / "00000000-0000000000000000"
        directory.mkdir(parents=True)
        (directory / "host.json").write_text(json.dumps({
            "supervisor": 1, "nonce": "n" * 32, "log": str(directory / "x.log"),
            "started": self.clock.time() - 400, "wait": 600}))
        watch = automation.Watch(options, threading.Event(), self.clock)
        with mock.patch.object(automation, "host_state", lambda *a, **k: None), \
                mock.patch.object(automation, "recorded_supervisor", lambda r: 1):
            before = self.clock.time()
            watch.settle_last_launch()
        # 600 s of its own, 400 elapsed: about 200 s remain, not the 14 of
        # the watch's own bounds.
        self.assertGreater(self.clock.time() - before, 150)


class FastClock(ManualClock):
    """A clock whose waits cost no real time: for a watch that runs for hours
    of the policy's time in a moment of the test's."""

    def sleep(self, seconds: float) -> None:
        self.advance(seconds)


class VerdictBoundaryTests(unittest.TestCase):
    """The policy's boundaries after a verdict, as the reviewer's final probe
    drew them, on a clock that costs nothing: a host that stopped beating is
    given a verdict, and what the watch does next rests on what it can show."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.options = automation.parse(
            ["--device", "synthetic", "--state-dir", self.tmp.name, "watch"])
        self.clock = FastClock()
        self.log = Path(self.tmp.name) / "host.log"
        self.log.write_text(automation.RUNNER_UP_LINE + "\n")
        self.record = {"nonce": "same-launch", "log": str(self.log),
                       "supervisor": None, "started": 0, "wait": 20}
        self.state = {"nonce": "same-launch", "time": 10000, "started": 9000,
                      "deadline": 20000, "finished": False}
        self.patch(automation, "log", lambda _: None)
        self.patch(automation, "local_record", lambda _: dict(self.record))
        self.patch(automation, "recorded_supervisor", lambda _: None)
        self.patch(automation, "host_state",
                   lambda *args, **kwargs: dict(self.state))
        self.watch = automation.Watch(self.options, clock=self.clock)
        scan = automation.LogScan(self.log)
        scan.read()
        self.watch.observer = automation.HostObserver(
            self.options, "same-launch", dict(self.state), scan=scan, clock=self.clock)
        self.clock.advance(3)
        self.assertIsNone(self.watch.observer.check())
        self.clock.advance(3)
        self.reason = self.watch.observer.check()
        self.assertIsNotNone(self.reason)

    def patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        result = patcher.start()
        self.addCleanup(patcher.stop)
        return result

    def assert_lock_free(self) -> None:
        descriptor = os.open(automation.state_dir(self.options) / "launch.lock",
                             os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(descriptor)

    def test_fresh_progress_a_new_start_and_a_failed_read_drop_the_verdict(self) -> None:
        # Rule (R3, R4): the verdict rests on a heartbeat that has not moved; a
        # beat, another launch's record or a read that fails each drop it with
        # nothing signalled and nothing launched, the launch lock released.
        for kind in ("progress", "published", "unreadable"):
            with self.subTest(kind):
                state, record = dict(self.state), dict(self.record)
                if kind == "progress":
                    self.state["time"] += 1
                if kind == "published":
                    self.record["nonce"] = "another-launch"
                read = (mock.patch.object(automation, "host_state", return_value=None)
                        if kind == "unreadable" else mock.patch.object(
                            automation, "host_state",
                            side_effect=lambda *x, **y: dict(self.state)))
                with read, mock.patch.object(self.watch, "end_all") as end, \
                        mock.patch.object(automation, "launch_host") as launch:
                    self.assertEqual(self.watch.replace(self.reason), automation.AGAIN)
                end.assert_not_called()
                launch.assert_not_called()
                self.assert_lock_free()
                self.state, self.record = state, record

    def test_an_existing_latch_refuses_a_launch_and_releases_the_lock(self) -> None:
        self.watch.latch.set("possible", "same-launch", self.log,
                             "earlier unresolved approval")
        with mock.patch.object(self.watch, "end_all") as end, \
                mock.patch.object(automation, "launch_host") as launch:
            self.assertEqual(self.watch.replace(self.reason), 4)
        end.assert_not_called()
        launch.assert_not_called()
        self.assert_lock_free()

    def test_a_relaunch_is_latched_before_cleanup_even_if_cleanup_crashes(self) -> None:
        with self.log.open("a") as stream:
            stream.write(automation.RUNNER_UP_LINE + "\n")

        def crash(verdict, remainder):
            self.assertEqual(self.watch.latch.read()["kind"], "possible")
            raise RuntimeError("interrupted after the durable latch")
        with mock.patch.object(self.watch, "end_all", crash), \
                mock.patch.object(automation, "launch_host") as launch:
            with self.assertRaises(RuntimeError):
                self.watch.replace(self.reason)
        launch.assert_not_called()
        self.assert_lock_free()
        successor = automation.Watch(self.options, clock=self.clock)
        self.assertEqual(successor.latch.read()["kind"], "possible")

    def test_a_relaunch_that_shows_initialized_only_during_cleanup_stays_recorded(self) -> None:
        # Rule (round 4): the relaunched runner's log was cut when the watch
        # looked (a risk, recorded before anything is ended), and the rest of
        # the pattern arrives while the host is ended. What was not known when
        # the risk was recorded does not undo it: the watch exits 4 and starts
        # nothing, as it would for a log that never said.
        with self.log.open("a") as stream:
            stream.write(automation.RUNNER_UP_LINE + "\n")

        def cleanup(verdict, remainder):
            self.assertEqual(self.watch.latch.read()["kind"], "possible")
            with self.log.open("a") as stream:
                stream.write("Restarting after unexpected exit, crash, or test timeout\n"
                             "\t Executed 0 tests, with 0 failures (0 unexpected)\n")
            return automation.ENDED
        with mock.patch.object(self.watch, "end_all", cleanup), \
                mock.patch.object(automation, "launch_host") as launch:
            self.assertEqual(self.watch.replace(self.reason), 4)
        self.assertEqual(self.watch.latch.read()["kind"], "possible")
        launch.assert_not_called()
        self.assert_lock_free()

    def test_a_relaunch_that_initialized_is_replaced_without_a_latch(self) -> None:
        # Rule (round 4): the log shows the whole pattern, so the host is ended
        # and its replacement launched, with nothing recorded.
        with self.log.open("a") as stream:
            stream.write(automation.RUNNER_UP_LINE + "\n"
                         "Restarting after unexpected exit, crash, or test timeout\n"
                         "\t Executed 0 tests, with 0 failures (0 unexpected)\n")
        launch = automation.Launch(mock.Mock(), self.log, "new-launch")
        with mock.patch.object(self.watch, "end_all", return_value=automation.ENDED), \
                mock.patch.object(automation, "launch_host", return_value=launch) as started, \
                mock.patch.object(self.watch, "await_launch",
                                  return_value=("failed", "the one started host failed")):
            self.assertEqual(self.watch.replace(self.reason), 5)
        self.assertEqual(started.call_count, 1)
        self.assertIsNone(self.watch.latch.read())
        self.assert_lock_free()

    def test_an_approval_line_that_appears_during_cleanup_is_latched(self) -> None:
        def cleanup(verdict, remainder):
            with self.log.open("a") as stream:
                stream.write("Failed to initialize for UI testing: Error Domain="
                             'com.apple.LocalAuthentication Code=-4 "localized"\n')
            return automation.ENDED
        with mock.patch.object(self.watch, "end_all", cleanup), \
                mock.patch.object(automation, "launch_host") as launch:
            self.assertEqual(self.watch.replace(self.reason), 4)
        self.assertEqual(self.watch.latch.read()["kind"], "observed")
        launch.assert_not_called()
        self.assert_lock_free()

    def test_the_launch_lock_is_released_before_the_wait_for_a_published_host(self) -> None:
        launch = automation.Launch(mock.Mock(), self.log, "new-launch")

        def await_launch(value):
            self.assertIs(value, launch)
            self.assert_lock_free()
            return ("failed", "the one started host failed")
        with mock.patch.object(self.watch, "end_all", return_value=automation.ENDED), \
                mock.patch.object(automation, "launch_host",
                                  return_value=launch) as started, \
                mock.patch.object(self.watch, "await_launch", await_launch):
            self.assertEqual(self.watch.replace(self.reason), 5)
        self.assertEqual(started.call_count, 1)
        self.assert_lock_free()

    def test_a_finished_snapshot_followed_only_by_failed_reads_ends_unknown(self) -> None:
        # Rule (R3, the reviewer's final probe): one snapshot that says the host
        # finished, then reads that all fail. The verdict it gave is cached and
        # every turn of the loop drops it for want of a fresh read, but the
        # bound on how long the heartbeat may stay unreadable applies all the
        # same: the watch ends with the cannot-observe status, and nothing was
        # ended or started.
        watch = automation.Watch(self.options, clock=self.clock)
        first = [dict(self.state, finished=True)]
        limit = self.clock.monotonic() + automation.WATCH_UNKNOWN_LIMIT + 20
        # (the bound of the probe stops a watch that does not end by itself)
        self.clock.hooks.append(
            lambda clock: watch.stop.set() if clock.monotonic() > limit + 600 else None)
        with mock.patch.object(automation, "host_state",
                               lambda *args, **kwargs: first.pop() if first else None), \
                mock.patch.object(automation, "end_host") as end, \
                mock.patch.object(automation, "launch_host") as launch:
            result = watch.run()
        self.assertEqual(result, automation.EXIT_WATCH_CANNOT_OBSERVE)
        self.assertEqual(watch.record.data.get("state"), automation.CANNOT_OBSERVE)
        self.assertLess(self.clock.monotonic(), limit + 600)
        end.assert_not_called()
        launch.assert_not_called()
        self.assert_lock_free()

    def test_an_approval_failure_in_the_last_launch_is_latched_without_a_heartbeat(self) -> None:
        # Rule (R1, the reviewer's final probe): the last launch's own log says
        # the device asked and nobody answered. The watch records that whether
        # or not it can read a heartbeat; it starts nothing, and ends with the
        # cannot-observe status naming the recorded approval.
        with self.log.open("a") as stream:
            stream.write("Failed to initialize for UI testing: Error Domain="
                         'com.apple.LocalAuthentication Code=-2 "localized"\n')
        watch = automation.Watch(self.options, clock=self.clock)
        with mock.patch.object(automation, "host_state", return_value=None), \
                mock.patch.object(automation, "end_host") as end, \
                mock.patch.object(automation, "launch_host") as launch:
            self.assertEqual(watch.run(), automation.EXIT_WATCH_CANNOT_OBSERVE)
        latch = watch.latch.read()
        self.assertIsNotNone(latch, "the approval failure was not recorded")
        self.assertEqual(latch["kind"], "observed")
        self.assertEqual(latch["nonce"], "same-launch")
        self.assertIn("approval", watch.record.data.get("detail", ""))
        end.assert_not_called()
        launch.assert_not_called()


class OverrunClock(FastClock):
    """A fast clock whose next wait can take longer than it asked."""

    def __init__(self) -> None:
        super().__init__()
        self.extra = 0.0

    def sleep(self, seconds: float) -> None:
        extra, self.extra = self.extra, 0.0
        self.advance(seconds + extra)


class StallTests(unittest.TestCase):
    """The watch says when its loop was not scheduled: a turn that starts more
    than WATCH_STALL after the one before it is logged, with the gap and where
    the time went. It is what names a stall such as a watch that made no poll
    for over an hour while the Mac idled with its display off."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.options = automation.parse(
            ["--device", "synthetic", "--state-dir", self.tmp.name, "watch"])
        self.clock = OverrunClock()
        self.messages: list[str] = []
        for name, value in (("log", self.messages.append),
                            ("local_record", lambda _: {})):
            patcher = mock.patch.object(automation, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def late(self) -> list[str]:
        return [message for message in self.messages if "poll loop" in message]

    def run_turns(self, *turns, replace=None) -> None:
        """Runs the watch's loop; each turn is what the observer's check does
        in that turn (it may take time, and returns a reason or None). The
        watch ends when the turns are over."""
        script = list(turns)
        del self.messages[:]
        self.watch = automation.Watch(self.options, clock=self.clock)

        def check(observer):
            if not script:
                self.watch.stop.set()
                return None
            return script.pop(0)(self.clock)
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(automation.HostObserver, "check", check))
            if replace is not None:
                stack.enter_context(mock.patch.object(self.watch, "replace", replace))
            self.assertEqual(self.watch.run(), 0)

    @staticmethod
    def quiet(clock):
        return None

    @staticmethod
    def stalled(seconds: float):
        """The wait after this turn takes `seconds` longer than asked."""
        return lambda clock: setattr(clock, "extra", seconds)

    @staticmethod
    def works(seconds: float):
        """This turn's read of the device takes `seconds`."""
        return lambda clock: clock.advance(seconds)

    def test_a_loop_that_was_not_scheduled_says_so_with_the_gap(self) -> None:
        # Rule: one line, with the gap, for the turn that started late; the
        # turns on time say nothing.
        self.run_turns(*[self.quiet] * 5, self.stalled(4800), *[self.quiet] * 5)
        self.assertEqual(len(self.late()), 1, self.messages)
        message = self.late()[0]
        self.assertIn("did not run for 4802.0 s by the monotonic clock", message)
        self.assertIn("4802.0 s by the wall clock", message)
        self.assertIn(f"a poll comes every {automation.WATCH_POLL} s", message)
        self.assertIn("its wait took 4802.0 s and the rest of the turn 0.0 s", message)

    def test_polls_on_time_say_nothing(self) -> None:
        self.run_turns(*[self.quiet] * 40)
        self.assertEqual(self.late(), [])

    def test_the_bound_is_well_above_the_period(self) -> None:
        # Rule: a gap of exactly the bound is on time; one more is not.
        period = automation.WATCH_POLL
        self.assertGreaterEqual(automation.WATCH_STALL, 5 * period)
        self.run_turns(self.quiet, self.stalled(automation.WATCH_STALL - period),
                       self.quiet, self.quiet)
        self.assertEqual(self.late(), [])
        self.run_turns(self.quiet, self.stalled(automation.WATCH_STALL - period + 0.5),
                       self.quiet, self.quiet)
        self.assertEqual(len(self.late()), 1, self.messages)

    def test_each_late_turn_is_told_once(self) -> None:
        self.run_turns(self.quiet, self.stalled(100), self.quiet, self.quiet,
                       self.stalled(200), self.quiet, self.quiet)
        self.assertEqual(len(self.late()), 2, self.messages)
        self.assertIn("102.0 s", self.late()[0])
        self.assertIn("202.0 s", self.late()[1])

    def test_a_read_that_held_the_turn_is_told_apart_from_a_wait_that_did(self) -> None:
        # Rule: the line says where the time went, so that a read of the device
        # that timed out is not taken for a loop that was not run.
        self.run_turns(self.quiet, self.works(60), self.quiet, self.quiet)
        self.assertEqual(len(self.late()), 1, self.messages)
        self.assertIn("its wait took 2.0 s and the rest of the turn 60.0 s",
                      self.late()[0])

    def test_a_sleep_of_the_mac_is_named_by_the_wall_clock(self) -> None:
        # The monotonic clock stops while the Mac sleeps; the wall clock does
        # not, and a turn that starts after the sleep is late by it.
        self.run_turns(self.quiet, lambda clock: clock.suspend(3600), self.quiet,
                       self.quiet)
        self.assertEqual(len(self.late()), 1, self.messages)
        self.assertIn("2.0 s by the monotonic clock and 3602.0 s by the wall clock",
                      self.late()[0])

    def test_a_stall_after_a_verdict_that_did_not_stand_is_still_told(self) -> None:
        # Rule: the time spent in a replacement is not a poll's, but the wait
        # after it is. When the verdict no longer stands (AGAIN) and the wait
        # that follows overruns, the next turn tells it: the baseline is set
        # at the end of the replacement, not deleted.
        def again(reason):
            self.clock.advance(100)
            self.clock.extra = 4800
            return automation.AGAIN
        self.run_turns(self.quiet, lambda clock: "dead", self.quiet, self.quiet,
                       replace=again)
        self.assertEqual(len(self.late()), 1, self.messages)
        self.assertIn("did not run for 4802.0 s by the monotonic clock",
                      self.late()[0])
        self.assertIn("its wait took 4802.0 s", self.late()[0])

    def test_a_replacement_is_not_a_late_turn(self) -> None:
        # Rule: a replacement takes minutes and is not a poll; the turn after
        # it is not late for it.
        def replacement(reason):
            self.clock.advance(100)
        self.run_turns(self.quiet, lambda clock: "dead", self.quiet, self.quiet,
                       replace=replacement)
        self.assertEqual(self.late(), [])


class ObserverTests(unittest.TestCase):
    """When a host is dead, from what a scripted device shows, on a clock the
    test moves (the real WATCH_ constants; no host process runs)."""

    UDID = "00000000-0000000000000000"

    def setUp(self) -> None:
        self.scratch = __import__("tempfile").TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.clock = ManualClock()
        self.device_clock = 40_000.0   # the device's own clock, hours off the Mac's
        self.beating = True
        self.readable = True
        self.command: float | None = None
        self.nonce = "a" * 32
        self.reads = 0
        self.other: dict | None = None
        self.gone = False
        for name, value in (("host_state", self.read), ("log", lambda message: None)):
            patcher = mock.patch.object(automation, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.options = automation.parse(
            ["--device", self.UDID, "--state-dir", self.scratch.name, "status"])
        process = mock.Mock()
        process.poll = lambda: 1 if self.gone else None
        self.observer = automation.HostObserver(
            self.options, self.nonce, self.state(), process, None, self.clock)

    def state(self) -> dict:
        state = {"nonce": self.nonce, "time": self.device_clock, "started": 39_000.0,
                 "deadline": 99_999.0, "served": 0, "finished": False}
        if self.command is not None:
            state.update(command="wait", commandStarted=self.command)
        return state

    def read(self, options, timeout=60):
        self.reads += 1
        if not self.readable:
            return None
        if self.other is not None:
            return self.other
        return self.state()

    def run_for(self, seconds: float, step: float = 2.0):
        """Runs the watch's loop for `seconds` of the clock; the first verdict
        and when it came, or (None, seconds)."""
        began = self.clock.monotonic()
        while self.clock.monotonic() - began < seconds:
            if self.beating:
                self.device_clock += step
            reason = self.observer.check()
            if reason is not None:
                return reason, self.clock.monotonic() - began
            self.clock.advance(step)
        return None, seconds

    def test_a_beating_host_is_alive_whatever_the_devices_clock_says(self) -> None:
        # The device's clock is hours off the Mac's: only progress counts.
        self.assertEqual(self.run_for(600), (None, 600))

    def test_a_host_that_stops_beating_is_dead_after_the_heartbeat_bound(self) -> None:
        self.run_for(30)
        self.beating = False
        reason, after = self.run_for(120)
        self.assertIn("has not advanced", reason)
        self.assertGreaterEqual(after, automation.HEARTBEAT_STALE - 2)
        self.assertLessEqual(after, automation.HEARTBEAT_STALE
                             + 2 * (automation.WATCH_PULL_EVERY + 2))

    def test_a_host_whose_supervisor_ended_is_dead_after_a_few_seconds(self) -> None:
        self.run_for(30)
        self.beating = False
        self.gone = True
        reason, after = self.run_for(60)
        self.assertIn("supervisor ended", reason)
        self.assertLessEqual(after, automation.WATCH_GONE_AGE + 6)

    def test_a_beating_host_whose_supervisor_ended_is_alive(self) -> None:
        self.gone = True
        self.assertEqual(self.run_for(300), (None, 300))

    def test_reads_that_fail_are_not_a_death(self) -> None:
        # Rule (R3): the host beats on while no read works, for far longer
        # than the bound; the watch says nothing, and says how long it is blind.
        self.run_for(30)
        self.readable = False
        self.assertEqual(self.run_for(1000), (None, 1000))
        self.assertGreater(self.observer.blind_for(), 900)
        self.readable = True
        self.assertEqual(self.run_for(60), (None, 60))
        self.assertEqual(self.observer.blind_for(), 0)

    def test_a_host_that_died_while_unreadable_is_dead_when_read_again(self) -> None:
        # A read that works and shows the beat it showed long ago is evidence.
        self.run_for(30)
        self.readable = False
        self.beating = False
        self.run_for(100)
        self.readable = True
        reason, _ = self.run_for(60)
        self.assertIn("has not advanced", reason)

    def test_a_sleep_of_the_mac_is_not_a_death(self) -> None:
        # Rule (R3): the monotonic clock stops while the Mac sleeps, so the
        # last read looks young to it and the wall clock moves hours. A beating
        # host is not declared dead on waking; and a read is the first thing
        # made on waking.
        self.run_for(30)
        self.observer.pull()   # the last read is as young as it can be
        reads = self.reads
        self.clock.suspend(6 * 3600)
        self.device_clock += 6 * 3600
        self.assertIsNone(self.observer.check())
        self.assertEqual(self.reads, reads + 1)
        self.assertEqual(self.run_for(60), (None, 60))

    def test_a_host_that_did_not_survive_the_sleep_is_dead_after_the_bound(self) -> None:
        # The silence seen before the sleep (10 s of it here) does not count
        # towards the bound: the host is measured again from the wake.
        self.run_for(30)
        self.beating = False
        self.run_for(10)
        self.clock.suspend(6 * 3600)
        reason, after = self.run_for(120)
        self.assertIn("has not advanced", reason)
        self.assertGreaterEqual(after, automation.HEARTBEAT_STALE - 2)

    def test_a_command_longer_than_the_busy_limit_is_a_hung_host(self) -> None:
        self.run_for(10)
        self.command = self.device_clock
        reason, after = self.run_for(automation.WATCH_BUSY_LIMIT + 100, 10)
        self.assertIn("hung", reason)
        self.assertGreaterEqual(after, automation.WATCH_BUSY_LIMIT - 10)

    def test_a_command_gets_its_own_longer_deadline(self) -> None:
        # Rule (C): a sender waiting 4000 s for its command, which the host may
        # run that long, is not waiting on a hung host at 1800 s.
        self.run_for(10)
        self.command = self.device_clock
        with automation.Inflight(self.options, "wait", 4000):
            reason, after = self.run_for(automation.WATCH_BUSY_LIMIT + 1000, 10)
            self.assertIsNone(reason)
            reason, after = self.run_for(2000, 10)
        self.assertIn("hung", reason)

    def test_a_sender_that_is_gone_does_not_extend_the_deadline(self) -> None:
        directory = Path(self.scratch.name) / self.UDID / "inflight"
        directory.mkdir(parents=True)
        (directory / "gone.json").write_text(json.dumps(
            {"pid": os.getpid(), "start": "Mon Jan  1 00:00:00 2001", "limit": 9000}))
        (directory / "dead.json").write_text(json.dumps(
            {"pid": 2 ** 22 + 12345, "start": "x", "limit": 9000}))
        for command in ("gone", "dead", "live", "../live"):
            self.assertEqual(automation.inflight_limit(self.options, command), 0)
        with automation.Inflight(self.options, "live", 4000):
            self.assertEqual(automation.inflight_limit(self.options, "live"), 4000)
            self.assertEqual(automation.inflight_limit(self.options, "../live"), 0)
        self.assertEqual(automation.inflight_limit(self.options, "live"), 0)

    def test_a_late_delivery_of_the_last_beat_is_not_silence(self) -> None:
        # Rule (R3, the reviewer's probe): the supervisor has just ended, and a
        # quick read samples the last beat before the next one and delivers it 30
        # s later, in which time the host beat on. A read counts from the moment
        # it started: the transfer is not silence, and no verdict follows.
        self.run_for(30)
        self.gone = True
        delivered = []

        def delayed(options, timeout=60):
            # The sample is the beat the watch already has: the next one has
            # not been written yet when it is taken.
            snapshot = dict(self.state(), time=self.observer.beat)
            self.clock.advance(30)
            self.device_clock += 30
            delivered.append(1)
            return snapshot
        with mock.patch.object(automation, "host_state", delayed):
            self.assertIsNone(self.observer.check())
        self.assertTrue(delivered)
        # The next read shows the beats that came meanwhile.
        self.clock.advance(2)
        self.assertEqual(self.run_for(60), (None, 60))

    def test_death_needs_three_reads_in_a_row_that_all_showed_the_same_beat(self) -> None:
        # Rule (R3): one read, or two, however long after the first they come,
        # is not evidence that no beat came between them.
        self.run_for(30)
        self.beating = False
        self.observer.pull()
        self.clock.advance(100)
        self.assertIsNone(self.observer.check())      # the second read
        self.clock.advance(automation.WATCH_PULL_EVERY)
        self.assertIn("has not advanced", self.observer.check())   # the third

    def test_a_read_that_fails_starts_the_count_again(self) -> None:
        # Rule (R3): unknown resets the count, however many reads showed the
        # same beat before it.
        self.run_for(30)
        self.beating = False
        for _ in range(2):
            self.observer.pull()
            self.clock.advance(60)
        self.readable = False
        self.observer.pull()
        self.clock.advance(60)
        self.readable = True
        self.observer.pull()
        self.clock.advance(60)
        # The read that worked after the failure and this one are two reads, not
        # three (the ones before the failure do not count).
        self.assertIsNone(self.observer.check())
        self.clock.advance(automation.WATCH_PULL_EVERY)
        self.assertIn("has not advanced", self.observer.check())

    def test_a_watch_that_has_just_started_reasons_like_one_that_has_run_a_day(self) -> None:
        # Rule (R3): before it follows any host, a read that fails is unknown
        # and the count never starts: nothing is concluded, however long it
        # lasts, and the time it has been blind is told.
        fresh = automation.HostObserver(self.options, None, None, None, None, self.clock)
        self.readable = False
        for _ in range(500):
            self.assertIsNone(fresh.check())
            self.clock.advance(2)
        self.assertGreater(fresh.blind_for(), 900)
        self.assertIsNone(fresh.nonce)
        self.readable = True
        self.assertIsNone(fresh.check())
        self.assertEqual(fresh.nonce, self.nonce)
        self.assertEqual(fresh.blind_for(), 0)
        # It follows the host it can read, and needs the same evidence of its end.
        self.beating = False
        reason = None
        for _ in range(100):
            self.clock.advance(2)
            reason = fresh.check()
            if reason:
                break
        self.assertIn("has not advanced", reason)

    def test_another_senders_wait_does_not_extend_the_running_commands_deadline(self) -> None:
        # Rule (C, the reviewer's probe): a short command hangs and its sender
        # has given up; another command with a 4000 s wait queues behind it. The
        # hung command runs under its own sender's deadline, which is gone.
        self.run_for(10)
        self.command = self.device_clock - 2500
        self.clock.advance(automation.WATCH_PULL_EVERY)
        with automation.Inflight(self.options, "unrelated-long", 4000):
            self.assertIn("hung", self.observer.check())
        # The sender of the command the heartbeat names does extend it.
        self.clock.advance(automation.WATCH_PULL_EVERY)
        with automation.Inflight(self.options, "wait", 4000):
            self.assertIsNone(self.observer.check())

    def test_another_host_is_followed_only_once_it_advances(self) -> None:
        # What an earlier host left behind does not move; a new host does.
        other = {"nonce": "b" * 32, "time": 100.0, "started": 90.0,
                 "deadline": 99_999.0, "served": 0, "finished": False}
        self.other = other
        self.run_for(10)
        self.assertEqual(self.observer.nonce, "a" * 32)
        self.other = dict(other, time=104.0)
        self.run_for(6)
        self.assertEqual(self.observer.nonce, "b" * 32)


class SettleTests(WatchTestCase):
    """What the watch makes of a launch's log, and when."""

    def launched(self, *extra: str):
        launch = automation.launch_host(self.options(
            "start", "--hours", "1", *extra, *self.reports()))
        self.launches.append(launch)
        return launch

    def test_an_approval_line_that_arrives_during_a_slow_read_is_not_lost(self) -> None:
        # Rule (R1): a read that takes its whole allowed time carries the
        # attempt past the runner's deadline, and XCTest's line arrives in it;
        # the attempt rereads the log before it says what happened.
        clock = ManualClock()
        self.device.scenarios([{"kind": "up-silent"}])
        real = automation.host_state
        reads = []

        def slow(options, timeout=60):
            record = automation.local_record(options)
            log = Path(record.get("log", "/nonexistent"))
            if log.exists() and automation.RUNNER_UP_LINE in log.read_text():
                reads.append(1)
                # The read after the one that saw the runner come up: the
                # runner's deadline is set by then, and this read passes it.
                if len(reads) == 2:
                    with open(log, "a") as handle:
                        handle.write(PROMPT + "\n")
                    clock.advance(100)
            return real(options, timeout)
        self.patch(automation, "host_state", slow)
        launch = self.launched()
        outcome = automation.Watch(self.watch_options(), threading.Event(),
                                   clock).await_launch(launch)
        self.assertEqual(outcome[0], "approval", outcome)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "observed")

    def test_an_approval_line_that_arrives_as_the_host_is_ended_is_not_lost(self) -> None:
        # Rule (R1): the host's last words come while it is ended; the attempt
        # that ended it rereads the log after, and the latch says what it read.
        clock = ManualClock()
        self.device.scenarios([{"kind": "up-silent"}])
        real_end = automation.end_host

        def end(record, process=None, wait=None, remainder=None, directory=None):
            with open(record["log"], "a") as handle:
                handle.write(PROMPT + "\n")
            return real_end(record, process, 2, remainder, directory)
        self.patch(automation, "end_host", end)
        self.tune(WATCH_RUNNER_WAIT=1.0)
        launch = self.launched()
        outcome = automation.Watch(self.watch_options(), threading.Event(),
                                   clock).await_launch(launch)
        self.assertEqual(outcome[0], "approval", outcome)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "observed")

    def dead_host_then(self, scenario: dict, **launch_options):
        """A host that ended (so that the heartbeat the watch reads is the stale
        one of a host that served), and then a launch of `scenario` that a watch
        that is gone began: its record is the last launch's."""
        self.tune(HEARTBEAT_STALE=2.0)
        old = self.start_host()
        self.device.control(old.nonce, "die")
        self.device.wait(lambda: old.process.poll() is not None, 15,
                         "the old host ended")
        self.device.scenarios([scenario])
        return old

    def test_a_previous_attempts_approval_survives_a_watch_that_ended_mid_attempt(self) -> None:
        # Rule (R1): a watch killed during an attempt leaves its state
        # "starting"; that attempt's own log already says the device asked. The
        # next watch reads it before it launches anything.
        self.dead_host_then({"kind": "approval", "after": 0.1})
        launch = automation.launch_host(self.options(
            "start", "--hours", "1", *self.reports()), record=lambda nonce, path: (
            automation.WatchRecord(self.options("status")).update(
                state=automation.STARTING, pending={
                    "nonce": nonce, "log": str(path), "time": time.time(),
                    "replacement": True})))
        self.launches.append(launch)
        self.device.wait(lambda: automation.APPROVAL_TIMEOUT_LINE in
                         launch.log_path.read_text(), 30, "the host's log says it")
        self.device.wait(lambda: launch.process.poll() is not None, 30,
                         "the supervisor ended")
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(2)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "observed")

    def test_a_host_ended_before_it_could_say_whether_the_device_asked_counts(self) -> None:
        # Rule (R1): a watch killed while its runner was up and silent, and its
        # supervisor with it, left no line and no exit status. The device may
        # be asking: the next watch does not start another host.
        self.dead_host_then({"kind": "up-silent"})
        launch = self.launched("--wait", "30")
        self.device.wait(lambda: automation.RUNNER_UP_LINE in
                         launch.log_path.read_text(), 30, "the runner is up")
        os.killpg(launch.process.pid, signal.SIGKILL)
        self.device.wait(lambda: launch.process.poll() is not None, 10,
                         "the supervisor ended")
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(2)
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "possible")

    def stopped_attempt(self, wait_for_runner: bool):
        """An attempt whose watch is stopped, by the first read of the host's
        heartbeat that has the runner's line in the log behind it (or by the
        first read at all), as `stop --force` would end it."""
        stop = threading.Event()
        watch = automation.Watch(self.watch_options(), stop, ManualClock())

        def read(options, timeout=60):
            log = Path(automation.local_record(options).get("log", "/nonexistent"))
            if not wait_for_runner or (log.exists() and
                                       automation.RUNNER_UP_LINE in log.read_text()):
                stop.set()
            return None
        self.patch(automation, "host_state", read)
        return watch.await_launch(self.launched())

    def test_a_host_stopped_once_its_runner_was_up_counts(self) -> None:
        # Rule (R1): `stop` during an attempt ends the producer before it could
        # print; once the runner was up that may have been the prompt.
        self.device.scenarios([{"kind": "up-silent"}])
        self.assertEqual(self.stopped_attempt(True), ("stopped",))
        latch = automation.ApprovalLatch(self.options("status")).read()
        self.assertEqual(latch["kind"], "possible")

    def test_a_host_stopped_before_its_runner_came_up_does_not(self) -> None:
        self.device.scenarios([{"kind": "no-runner"}])
        self.assertEqual(self.stopped_attempt(False), ("stopped",))
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())

    def test_a_pending_replacement_is_waited_for_not_taken_for_a_ghost(self) -> None:
        # Rule (R1): the host that ended a moment ago still has a recent last
        # beat; a replacement that a watch started and that ended is still
        # coming up. The next watch waits for that replacement, and starts no
        # third host and ends none.
        self.tune(HEARTBEAT_STALE=60)
        old = self.start_host()
        self.device.scenarios([{"kind": "serve", "hold": True}])
        self.device.control(old.nonce, "die")
        self.device.wait(lambda: old.process.poll() is not None, 15,
                         "the old host ended")
        pending = automation.launch_host(self.options(
            "start", "--hours", "1", *self.reports()), record=lambda nonce, path: (
            automation.WatchRecord(self.options("status")).update(
                state=automation.RESTARTING, pending={
                    "nonce": nonce, "log": str(path), "time": time.time(),
                    "replacement": True})))
        self.launches.append(pending)
        self.device.wait(lambda: len(self.device.invocations()) == 2, 15,
                         "the replacement starts")
        watch = self.run_watch()
        self.device.wait(lambda: any("waiting for it" in message
                                     for message in self.messages), 30,
                         "the watch waits for the replacement")
        self.invoked(2)
        self.assertIsNone(pending.process.poll())
        self.device.control(pending.nonce, "go")
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], pending.nonce)
        self.invoked(2)
        self.assertEqual(watch.end(), 0)


class ApprovalLatchTests(WatchTestCase):
    def fail_for_approval(self) -> None:
        self.tune(HEARTBEAT_STALE=2.0)
        self.device.scenarios([{"kind": "serve"}, {"kind": "approval"}])
        first = self.watch_over_host()
        watch = self.last_watch
        self.device.control(first, "die")
        self.assertEqual(watch.join(), automation.EXIT_NEEDS_APPROVAL, self.messages)
        self.invoked(2)
        # The host's own log, which a later watch could read the refusal from
        # again, is no longer what the record points at: only the latch is left.
        (self.device.state_dir / self.device.udid / "host.json").unlink()

    def test_the_refusal_survives_a_watch_that_is_stopped(self) -> None:
        # Rule (R2): a watch that starts and is stopped at once, before it has
        # read the device, must not clear the refusal for the next one.
        self.fail_for_approval()
        stopped = threading.Event()
        stopped.set()
        again = Running(self.watch_options(), stopped)
        self.watches.append(again)
        self.assertEqual(again.join(), 0)
        self.assertEqual(self.record()["state"], automation.STOPPED)
        third = self.run_watch()
        self.assertEqual(third.join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)

    def test_the_refusal_survives_a_watch_that_fails(self) -> None:
        # Rule (R2): a watch that raises ends in the state "error".
        self.fail_for_approval()
        with mock.patch.object(automation, "host_state",
                               side_effect=RuntimeError("boom")):
            self.assertEqual(self.run_watch().join(),
                             automation.EXIT_FAILED)
        self.assertEqual(self.record()["state"], automation.WATCH_ERROR)
        self.assertEqual(self.run_watch().join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)

    def test_the_refusal_survives_a_watch_that_was_killed(self) -> None:
        # Rule (R2): SIGKILL leaves the record "starting".
        self.fail_for_approval()
        automation.WatchRecord(self.options("status")).update(
            state=automation.STARTING, detail="")
        self.assertEqual(self.run_watch().join(), automation.EXIT_NEEDS_APPROVAL)
        self.invoked(2)

    def test_only_a_host_that_serves_clears_it(self) -> None:
        # A serving host that a watch finds (a `start` by another route) does.
        self.fail_for_approval()
        self.tune(HEARTBEAT_STALE=30)
        self.device.scenarios([{"kind": "serve"}])
        self.device.wait(lambda: self.device.silent_for() > 2.5, 30,
                         "the first host's last beat is old")
        host = self.start_host()
        again = self.run_watch()
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], host.nonce)
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())
        self.assertEqual(again.end(), 0)


class LaunchTests(WatchTestCase):
    def test_a_watch_does_not_retire_under_a_start_that_is_bringing_up_a_host(self) -> None:
        # Rule (R4, the reviewer's gated probe): a `start` that has checked that
        # no watch runs and is in the report preflight, which can take minutes,
        # holds the launch lock. A watch that reaches its verdict on the old
        # host then waits for the lock, and once the `start` has published its
        # host it drops the verdict: it neither ends the `start`'s host nor
        # starts another beside it. (The old host's death is what the watch
        # judged.)
        old = self.start_host()
        self.device.control(old.nonce, "die")
        self.device.wait(lambda: old.process.poll() is not None, 15,
                         "the old host ended")
        self.device.wait(lambda: self.device.silent_for() > automation.HEARTBEAT_STALE,
                         30, "the old host's last beat is stale")
        self.device.scenarios([{"kind": "serve", "hold": True}])
        inside = threading.Event()
        release = threading.Event()
        real = automation.check_report_slots
        first = []

        def preflight(options, processes):
            if not first:
                first.append(1)
                inside.set()
                release.wait(60)
            return real(options, processes)
        self.patch(automation, "check_report_slots", preflight)
        started: list[int] = []
        thread = threading.Thread(target=lambda: started.append(
            automation.command_start(self.options(
                "start", "--hours", "1", "--wait", "40", *self.reports()))),
            daemon=True)
        thread.start()
        self.assertTrue(inside.wait(30))
        self.tune(HEARTBEAT_STALE=1.5)
        watch = self.run_watch()
        self.device.wait(lambda: any("another launch" in message
                                     for message in self.messages), 30,
                         "the watch waits for the `start`'s launch")
        self.invoked(1)
        release.set()
        self.device.wait(lambda: len(self.device.invocations()) == 2, 30,
                         "the `start`'s host runs")
        self.device.wait(lambda: any("a start was published meanwhile" in message
                                     for message in self.messages), 30,
                         "the watch drops its verdict")
        nonce = self.device.invocations()[1]["nonce"]
        self.assertTrue(self.device.alive(self.device.invocations()[1]["ppid"]))
        self.invoked(2)
        self.device.control(nonce, "go")
        thread.join(60)
        self.assertEqual(started, [0], self.messages)
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], nonce)
        self.invoked(2)
        self.assertTrue(self.device.serving(nonce))
        self.assertEqual(watch.end(), 0)

    def test_a_stop_during_the_report_preflight_starts_nothing(self) -> None:
        # Rule (R4): cancellation is checked again after the preflight and
        # before the supervisor is spawned.
        old = self.start_host()
        self.device.control(old.nonce, "die")
        self.device.wait(lambda: old.process.poll() is not None, 15,
                         "the old host ended")
        stop = threading.Event()
        real = automation.check_report_slots

        def preflight(options, processes):
            result = real(options, processes)
            stop.set()
            return result
        self.patch(automation, "check_report_slots", preflight)
        watch = Running(self.watch_options(), stop)
        self.watches.append(watch)
        self.assertEqual(watch.join(), 0, self.messages)
        self.invoked(1)
        self.assertEqual(self.record()["state"], automation.STOPPED)
        self.assertEqual(len(list((self.device.state_dir / self.device.udid).glob("host-*.log"))), 1)

    def test_the_host_record_is_whole_before_the_supervisor_starts(self) -> None:
        # Rule (R4): host.json is written atomically, and before the
        # supervisor that a reader would look for exists; the recorded wait is
        # the starter's own.
        seen = []
        real = automation.subprocess.Popen

        def popen(arguments, *positional, **keywords):
            if "_supervise" in arguments:
                seen.append(json.loads((self.device.state_dir / self.device.udid
                                        / "host.json").read_text()))
            return real(arguments, *positional, **keywords)
        self.patch(automation.subprocess, "Popen", popen)
        moved = []
        real_replace = os.replace
        self.patch(automation.os, "replace", lambda source, target: (
            moved.append(Path(target).name), real_replace(source, target))[1])
        launch = automation.launch_host(self.options(
            "start", "--hours", "1", "--wait", "77", *self.reports()))
        self.launches.append(launch)
        # Moved into place both times, never written in place.
        self.assertEqual(moved.count("host.json"), 2)
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0]["nonce"], launch.nonce)
        self.assertIsNone(seen[0]["supervisor"])
        self.assertEqual(seen[0]["wait"], 77)
        final = automation.local_record(self.options("status"))
        self.assertEqual(final["supervisor"], launch.process.pid)
        self.assertFalse(list((self.device.state_dir / self.device.udid).glob("host.json.*")))

    def test_a_record_that_ended_before_it_knew_the_pid_still_finds_the_supervisor(self) -> None:
        launch = self.start_host()
        record = automation.local_record(self.options("status"))
        record["supervisor"] = None
        self.assertEqual(automation.recorded_supervisor(record), launch.process.pid)

    def test_each_collection_of_reports_gets_a_directory_of_its_own(self) -> None:
        # Rule (R8): the collector refuses a destination that exists, and a
        # watch collects again and again. With report checks on, each
        # collection (the launch's and the supervisor's, two hosts over) goes
        # to a new directory beneath the configured one; the real destination
        # checks run, against a report store that is full every time.
        reports = automation.ios_device_reports

        class Store:
            copies = 0
            listings = 0

            def listing(self):
                # A collection counts the store, moves everything, and counts
                # again: the store is full each time it is first counted.
                Store.listings += 1
                if Store.listings % 2 == 0:
                    return []
                return [reports.ListedFile(f"JetsamEvent-2000-01-01-000000.{i}.ips", 1)
                        for i in range(25)]

            def resolve_udid(self):
                return "00000000-0000000000000000"

            def require_mover(self):
                pass

            def copy_verified(self, files, directory):
                Store.copies += 1

            def remove_all(self, udid, directory):
                pass
        spawned = []

        class Process:
            pid = 99999

        real = automation.subprocess.Popen

        def popen(arguments, *positional, **keywords):
            if "_supervise" in arguments:
                spawned.append(arguments)
                return Process()
            return real(arguments, *positional, **keywords)
        base = self.device.root / "kept-reports"
        options = self.options("watch", "--hours", "1", "--device-reports-dir", str(base))
        self.assertFalse(options.leave_device_reports)
        with mock.patch.object(reports, "DeviceStore", lambda device: Store()), \
                mock.patch.object(automation.subprocess, "Popen", popen):
            automation.launch_host(options)
            automation.launch_host(options)
            for arguments in spawned:
                supervised = automation.parse(arguments[arguments.index("--device") :])
                self.assertTrue(automation.check_report_slots(
                    supervised, automation.REPORT_PROCESSES), self.messages)
        self.assertEqual(Store.copies, 4)
        self.assertEqual(len(list(base.iterdir())), 4)
        self.assertFalse(any("already exists" in message for message in self.messages))


class CleanupTests(WatchTestCase):
    def test_a_replacement_ends_the_whole_of_a_host_that_ignores_sigterm(self) -> None:
        # Rule (R5): the supervisor stays until its children are gone. The
        # xcodebuild of this host ignores SIGTERM; the replacement waits for it
        # to be ended, and nothing of the first host is left beside the second.
        self.tune(HEARTBEAT_STALE=2.0)
        self.device.scenarios([{"kind": "serve", "stubborn": True}, {"kind": "serve"}])
        first = self.watch_over_host()
        old = self.device.invocations()[0]
        self.device.control(first, "silent")
        second = self.watching(restarts=1)
        self.assertNotEqual(first, second)
        self.assertFalse(self.device.alive(old["pid"]))
        self.assertFalse(self.device.alive(old["ppid"]))
        self.assertEqual(automation.group_members(old["ppid"]), [])

    def test_an_orphaned_xcodebuild_is_ended_by_its_nonce(self) -> None:
        # Rule (R5): the supervisor of an adopted host is gone and its
        # xcodebuild lives on, ignoring SIGTERM. The record's nonce, which the
        # run's result bundle name carries, shows it is the host's: it is ended
        # with SIGKILL, and only then does the replacement start.
        self.tune(HEARTBEAT_STALE=2.0)
        self.device.scenarios([{"kind": "serve", "stubborn": True}, {"kind": "serve"}])
        host = self.start_host()
        old = self.device.invocations()[0]
        os.kill(old["ppid"], signal.SIGKILL)
        self.device.wait(lambda: not self.device.alive(old["ppid"]), 10,
                         "the supervisor ends")
        self.assertTrue(self.device.alive(old["pid"]))
        self.device.control(host.nonce, "silent")
        self.run_watch()
        second = self.watching(restarts=1)
        self.assertNotEqual(second, host.nonce)
        self.assertFalse(self.device.alive(old["pid"]))

    def test_an_unrelated_group_under_a_reused_pid_is_left_alone(self) -> None:
        # Rule (R5): no member of the group shows the record's nonce.
        decoy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(lambda: (decoy.kill(), decoy.wait()))
        self.assertEqual(
            automation.end_host({"supervisor": decoy.pid, "nonce": "f" * 32}),
            automation.FOREIGN)
        self.assertIsNone(decoy.poll())

    def test_a_group_whose_leader_began_after_the_host_is_another_group(self) -> None:
        # Rule (R5): the supervisor's pid was reused by a process that leads a
        # group of its own and started after the host did; the host's group, which
        # that pid named, is gone, so nothing of the host remains. A leader older
        # than the host is not shown to be another.
        decoy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(lambda: (decoy.kill(), decoy.wait()))
        self.assertEqual(automation.end_host(
            {"supervisor": decoy.pid, "nonce": "f" * 32,
             "started": time.time() - 3600}), automation.ENDED)
        self.assertIsNone(decoy.poll())
        self.assertEqual(automation.end_host(
            {"supervisor": decoy.pid, "nonce": "f" * 32,
             "started": time.time() + 3600}), automation.FOREIGN)
        self.assertIsNone(decoy.poll())

    def test_what_cannot_be_shown_gone_stops_the_watch_with_the_remainder(self) -> None:
        # Rule (R5): fail closed. Nothing starts beside a host that cannot be
        # ended, one whose remainder is not shown to be the host's, or one whose
        # processes cannot be listed: each ends the watch with the remainder
        # status, naming what is left.
        for result in (automation.STUCK, automation.FOREIGN, automation.UNKNOWN):
            with self.subTest(result):
                self.setUp()
                self.tune(HEARTBEAT_STALE=2.0)
                first = self.watch_over_host()
                watch = self.last_watch

                def end(record, process=None, wait=None, remainder=None, directory=None, result=result):
                    if remainder is not None:
                        remainder.append((4242, "a helper of the host"))
                    return result
                self.patch(automation, "end_host", end)
                self.device.control(first, "silent")
                self.assertEqual(watch.join(), automation.EXIT_WATCH_REMAINDER,
                                 self.messages)
                self.assertEqual(self.record()["state"], automation.REMAINDER)
                self.assertIn("4242", self.record()["detail"])
                self.assertIn(result, self.record()["detail"])
                self.invoked(1)

    def test_a_helper_that_survives_its_hosts_end_is_ended_with_the_host(self) -> None:
        # Rule (R5, the reviewer's orphan probe): the supervisor was killed, and
        # a helper in the group that carries no nonce ignores SIGTERM. The
        # nonce-bearing xcodebuild shows the group is the host's; that is held
        # through the call, so the helper is ended with SIGKILL, and the result
        # is ENDED only because the group was listed and is empty.
        fake = self.device.bin / "xcodebuild"
        source = fake.read_text()
        needle = '    child = subprocess.Popen(["sleep", "3600"]).pid'
        self.assertIn(needle, source)
        helper = ("import signal,time,pathlib,sys; "
                  "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                  "pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(120)")
        fake.write_text(source.replace(
            needle, "    child = subprocess.Popen([sys.executable, '-c', "
            + repr(helper) + ", os.path.join(root, 'helper-ready')]).pid"))
        self.device.scenarios([{"kind": "serve", "child": True}])
        host = self.start_host()
        helper_pid = self.device.invocations()[0]["child"]
        self.device.wait(lambda: (self.device.root / "helper-ready").exists(), 10,
                         "the helper is up")
        os.kill(host.process.pid, signal.SIGKILL)
        host.process.wait(timeout=10)
        result = automation.end_host(automation.local_record(self.options("status")),
                                     wait=1)
        self.assertEqual(result, automation.ENDED)
        self.assertFalse(self.device.alive(helper_pid))
        self.assertEqual(automation.group_members(host.process.pid), [])

    def test_a_member_that_has_just_exited_does_not_make_its_group_foreign(self) -> None:
        # macOS refuses a signal to a process that has exited and is not reaped
        # yet: that is a group about to be empty, not one the watch may not
        # signal. A group that stays, and refuses, is FOREIGN.
        record = {"supervisor": 123456, "nonce": "owned"}
        member = [(123456, "_supervise --nonce owned")]
        with mock.patch.object(automation, "group_members",
                               side_effect=[member, member, []]), \
                mock.patch.object(automation.os, "killpg",
                                  side_effect=PermissionError):
            self.assertEqual(automation.end_host(record, wait=1), automation.ENDED)
        left: list = []
        with mock.patch.object(automation, "group_members", return_value=member), \
                mock.patch.object(automation.os, "killpg",
                                  side_effect=PermissionError):
            self.assertEqual(automation.end_host(record, wait=1, remainder=left),
                             automation.FOREIGN)
        self.assertEqual(left, member)

    def orphaned_after_a_starter_crash(self):
        """The real sequence of the reviewer's probe: a starter that has
        spawned the supervisor and is killed (SIGKILL) before it publishes the
        supervisor's pid; the host serves; later the supervisor and xcodebuild
        die and a helper of theirs stays in the group. Returns the host's
        invocation and the helper's pid."""
        self.device.scenarios([{"kind": "serve", "child": True}, {"kind": "serve"}])
        starter = subprocess.Popen(
            [sys.executable, "-I", "-c", CRASH_STARTER, str(SCRIPT),
             "--device", self.device.udid, "--state-dir", str(self.device.state_dir),
             "--derived-data", str(self.device.derived), "start", *self.reports()],
            env=self.device.environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        self.addCleanup(lambda: (starter.kill(), starter.wait()))
        self.device.wait(lambda: (self.device.root / "before-pid-publication").exists(),
                         30, "the starter has spawned the supervisor")
        self.device.wait(lambda: self.device.invocations() and self.device.serving(
            self.device.invocations()[0]["nonce"]), 30, "the host serves")
        old = self.device.invocations()[0]
        helper = old["child"]

        def end_helper() -> None:
            try:
                os.kill(helper, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.addCleanup(end_helper)
        self.assertIsNone(automation.local_record(self.options("status"))["supervisor"])
        starter.kill()
        starter.wait(timeout=10)
        os.kill(old["ppid"], signal.SIGKILL)
        os.kill(old["pid"], signal.SIGKILL)
        self.device.wait(lambda: not self.device.alive(old["ppid"])
                         and not self.device.alive(old["pid"]), 10,
                         "the supervisor and xcodebuild ended")
        self.assertTrue(self.device.alive(helper))
        return old, helper

    def test_a_group_whose_identity_was_lost_with_its_starter_is_not_launched_beside(self) -> None:
        # Rule (R5, the reviewer's final probe): the record has no supervisor pid
        # and nothing that carries the nonce is left, but a helper is. That the
        # watch finds no nonce-bearing process proves nothing about the group:
        # it stops with the remainder status and starts no host beside the
        # helper. The supervisor's own published identity names the group; what
        # carries no nonce is not shown to be the host's, so it is left alone.
        old, helper = self.orphaned_after_a_starter_crash()
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_WATCH_REMAINDER, self.messages)
        self.assertEqual(self.record()["state"], automation.REMAINDER)
        self.assertIn(str(helper), self.record()["detail"])
        self.invoked(1)
        self.assertTrue(self.device.alive(helper))

    def test_a_group_that_nothing_names_is_unknown_not_empty(self) -> None:
        # Rule (R5): with the supervisor's identity file gone too, nothing names
        # the group at all: UNKNOWN, status 8, no launch, the helper untouched.
        old, helper = self.orphaned_after_a_starter_crash()
        (self.device.state_dir / self.device.udid
         / f"supervisor-{old['nonce']}.json").unlink(missing_ok=True)
        watch = self.run_watch()
        self.assertEqual(watch.join(), automation.EXIT_WATCH_REMAINDER, self.messages)
        self.assertIn(automation.UNKNOWN, self.record()["detail"])
        self.invoked(1)
        self.assertTrue(self.device.alive(helper))

    def test_the_group_of_a_host_is_found_by_what_names_it(self) -> None:
        directory = self.device.state_dir
        directory.mkdir(parents=True, exist_ok=True)
        rows = [(10, 10, "S", "python3 xcodebuild -resultBundlePath a/host-" + "n" * 32
                 + ".xcresult"), (11, 12, "S", "sleep 3600")]
        with mock.patch.object(automation, "process_table", return_value=rows):
            # Nothing names a host: nothing to end.
            self.assertEqual(automation.host_group({}, None), (None, True))
            # A pid in the record, or a process that carries the nonce.
            self.assertEqual(automation.host_group(
                {"nonce": "n" * 32, "supervisor": 77}, None), (77, True))
            self.assertEqual(automation.host_group({"nonce": "n" * 32}, None), (10, True))
            # A zombie that carries it is the remains of a process, not a group.
            with mock.patch.object(automation, "process_table", return_value=[
                    (13, 13, "Z", "python3 xcodebuild -resultBundlePath a/host-"
                     + "w" * 32 + ".xcresult")]):
                self.assertEqual(automation.host_group({"nonce": "w" * 32}, None),
                                 (None, False))
            # Nothing carries it, and no identity was published: not empty, not
            # known.
            self.assertEqual(automation.host_group({"nonce": "m" * 32}, None),
                             (None, False))
            self.assertEqual(automation.host_group({"nonce": "m" * 32}, None, directory),
                             (None, False))
            # The supervisor published its own.
            automation.write_json(automation.supervisor_identity_path(directory, "m" * 32),
                                  {"pid": 40, "pgid": 40, "nonce": "m" * 32})
            self.assertEqual(automation.host_group({"nonce": "m" * 32}, None, directory),
                             (40, True))
        with mock.patch.object(automation, "process_table", return_value=None):
            self.assertEqual(automation.host_group({"nonce": "k" * 32}, None),
                             (None, False))
            self.assertEqual(automation.end_host({"nonce": "k" * 32}), automation.UNKNOWN)
        with mock.patch.object(automation, "process_table", return_value=rows):
            self.assertEqual(automation.end_host({"nonce": "z" * 32}), automation.UNKNOWN)

    def test_a_record_naming_launchds_pid_names_no_host(self) -> None:
        # Only a record that has no pid at all can stand for a host spawned and
        # not yet recorded; pid 1 was never a started supervisor's.
        with mock.patch.object(automation, "process_table", return_value=[]):
            self.assertEqual(automation.host_group(
                {"nonce": "n" * 32, "supervisor": 1}, None), (None, True))
            self.assertEqual(automation.end_host({"nonce": "n" * 32, "supervisor": 1}),
                             automation.ENDED)
            self.assertEqual(automation.end_host({"nonce": "n" * 32}),
                             automation.UNKNOWN)

    def test_a_launch_keeps_the_identity_of_the_last_host_and_drops_older_ones(self) -> None:
        directory = self.device.state_dir / self.device.udid
        directory.mkdir(parents=True, exist_ok=True)
        for nonce in ("a" * 32, "b" * 32, "c" * 32):
            automation.write_json(automation.supervisor_identity_path(directory, nonce),
                                  {"pgid": 5, "nonce": nonce})
        automation.write_json(directory / "host.json", {"nonce": "b" * 32, "supervisor": 5})
        launch = automation.launch_host(self.options("start", "--hours", "1", *self.reports()))
        self.launches.append(launch)
        self.device.wait(lambda: self.device.serving(launch.nonce), 30, "the host serves")
        names = sorted(path.name for path in directory.glob("supervisor-*.json"))
        self.assertEqual(names, sorted(f"supervisor-{nonce}.json"
                                       for nonce in ("b" * 32, launch.nonce)))

    def test_a_supervisor_publishes_its_identity_before_it_spawns_anything(self) -> None:
        host = self.start_host()
        published = automation.read_json(automation.supervisor_identity_path(
            self.device.state_dir / self.device.udid, host.nonce))
        self.assertEqual(published["pid"], host.process.pid)
        self.assertEqual(published["pgid"], host.process.pid)
        self.assertEqual(published["nonce"], host.nonce)
        # Before the supervisor spawned xcodebuild.
        self.assertLessEqual(published["started"], self.device.invocations()[0]["time"])

    def test_a_group_that_cannot_be_listed_is_not_an_empty_one(self) -> None:
        # Rule (R5): a failed listing is not a group with nothing in it.
        record = {"supervisor": 123456, "nonce": "owned"}
        with mock.patch.object(automation, "group_members",
                               side_effect=[[(123456, "_supervise --nonce owned")], None]), \
                mock.patch.object(automation.os, "killpg") as kill:
            self.assertEqual(automation.end_host(record, wait=1), automation.UNKNOWN)
        self.assertEqual(kill.call_count, 1)
        with mock.patch.object(automation, "group_members", return_value=None):
            self.assertEqual(automation.end_host(record, wait=1), automation.UNKNOWN)
        with mock.patch.object(automation, "process_table", return_value=None):
            self.assertEqual(automation.end_host({"nonce": "owned"}), automation.UNKNOWN)


class CountingTests(WatchTestCase):
    def test_a_replacement_made_across_a_watch_crash_still_counts(self) -> None:
        # Rule (R7): the watch that launched the replacement ended before the
        # host served; the next watch adopts it, and it counts, once. With a
        # bound of one, the next end is a restart storm, not another host.
        self.tune(HEARTBEAT_STALE=2.0)
        host = automation.launch_host(self.options(
            "start", "--hours", "1", *self.reports()), record=lambda nonce, path: (
            automation.WatchRecord(self.options("status")).update(
                state=automation.RESTARTING, pending={
                    "nonce": nonce, "log": str(path), "time": time.time(),
                    "replacement": True})))
        self.launches.append(host)
        self.device.wait(lambda: self.device.serving(host.nonce), 30, "it serves")
        watch = self.run_watch("--max-restarts", "1")
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], host.nonce)
        self.assertEqual(record["restarts"], 1)
        self.assertEqual(len(record["restart_times"]), 1)
        self.assertIsNone(record["pending"])
        self.device.control(host.nonce, "die")
        self.assertEqual(watch.join(), automation.EXIT_WATCH_GAVE_UP)
        self.assertEqual(self.record()["state"], automation.RESTART_STORM)
        self.invoked(1)

    def test_the_replacement_is_recorded_before_its_host_starts(self) -> None:
        # Rule (R7): a watch killed after the launch but before the host serves
        # must leave the replacement on record: the watch's own record names
        # the nonce already when the supervisor is spawned.
        seen = []
        real = automation.subprocess.Popen

        def popen(arguments, *positional, **keywords):
            if "_supervise" in arguments:
                seen.append((arguments[arguments.index("--nonce") + 1],
                             self.record().get("pending")))
            return real(arguments, *positional, **keywords)
        first = self.watch_over_host()
        self.patch(automation.subprocess, "Popen", popen)
        self.device.control(first, "die")
        second = self.watching(restarts=1)
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0][0], second)
        self.assertEqual(seen[0][1]["nonce"], second)
        self.assertEqual(seen[0][1]["replacement"], True)
        self.assertIsNone(self.record()["pending"])

    def test_a_pending_replacement_of_another_host_is_not_counted(self) -> None:
        self.tune(HEARTBEAT_STALE=30)
        automation.WatchRecord(self.options("status")).update(
            pending={"nonce": "c" * 32, "log": "x", "time": time.time(),
                     "replacement": True})
        host = self.start_host()
        self.run_watch()
        record = self.wait_record(state=automation.WATCHING)
        self.assertEqual(record["host"], host.nonce)
        self.assertEqual(record["restarts"], 0)
        self.assertIsNone(record["pending"])


class LockOwnerTests(WatchTestCase):
    """`stop` signals the process that holds this device's lock, as the lock
    file names it, and no other."""

    def hold(self, **identity) -> int:
        directory = self.device.state_dir / self.device.udid
        directory.mkdir(parents=True, exist_ok=True)
        fd = os.open(directory / "watch.lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.addCleanup(os.close, fd)
        os.ftruncate(fd, 0)
        os.pwrite(fd, json.dumps(identity).encode(), 0)
        return fd

    def decoy(self) -> subprocess.Popen:
        # Looks like a watch of this script to a check of the command line.
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)", "watch",
             "ipad-automation.py"], stdin=subprocess.DEVNULL)
        self.addCleanup(lambda: (process.kill(), process.wait()))
        deadline = time.monotonic() + 10
        while True:
            instance = automation.process_instance(process.pid)
            if instance is not None and "time.sleep" in instance[1]:
                return process
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)

    def stop_with(self, signals: list) -> bool:
        self.tune(WATCH_END_WAIT=0.5)
        self.patch(automation, "signal_watcher", signals.append)
        return automation.end_watch(self.options("stop", "--force"))

    def identity(self, process, **changes) -> dict:
        identity = {"pid": process.pid,
                    "start": automation.process_instance(process.pid)[0],
                    "device": self.device.udid,
                    "state": os.path.realpath(self.device.state_dir / self.device.udid)}
        identity.update(changes)
        return identity

    def test_a_pid_that_was_reused_is_not_signalled(self) -> None:
        # Rule (R6): the lock is held by a new watch that has not written its
        # pid yet; the file still names a watch that ended, whose pid is now
        # another process: a watch for another device here.
        process = self.decoy()
        self.hold(**self.identity(process, start="Mon Jan  1 00:00:00 2001"))
        signals: list = []
        self.assertFalse(self.stop_with(signals))
        self.assertEqual(signals, [])
        self.assertIsNone(process.poll())

    def test_a_watch_of_another_device_is_not_signalled(self) -> None:
        process = self.decoy()
        self.hold(**self.identity(process, device="another-device"))
        signals: list = []
        self.assertFalse(self.stop_with(signals))
        self.assertEqual(signals, [])

    def test_a_watch_of_another_state_directory_is_not_signalled(self) -> None:
        process = self.decoy()
        self.hold(**self.identity(process, state="/somewhere/else"))
        signals: list = []
        self.assertFalse(self.stop_with(signals))
        self.assertEqual(signals, [])

    def test_the_holder_the_file_names_is_signalled(self) -> None:
        process = self.decoy()
        self.hold(**self.identity(process))
        signals: list = []
        self.assertFalse(self.stop_with(signals))   # the lock stays held
        self.assertEqual(signals, [process.pid])


class StopTests(WatchTestCase):
    def end_by_event(self, watch: Running):
        """Stands for the SIGTERM `stop --force` sends: in this process the
        watch is a thread, so the signal sets its stop event."""
        self.patch(automation, "signal_watcher", lambda pid: watch.stop.set())
        self.patch(automation, "watcher_is_a_watch", lambda pid: True)

    def test_a_deliberate_stop_is_not_undone(self) -> None:
        # Rule: `stop --force` ends the watch before the host, so the watch
        # does not start the host again: the host is told to stop only once the
        # watch has been signalled and has ended.
        first = self.watch_over_host()
        watch = self.last_watch
        self.end_by_event(watch)
        order = []
        real = automation.send

        def send(options, command, timeout):
            order.append((command["op"], watch.stop.is_set(),
                          automation.watcher_pid(options) is None))
            return real(options, command, timeout)
        self.patch(automation, "send", send)
        self.assertEqual(automation.command_stop(
            self.options("stop", "--force")), 0)
        self.assertEqual(order, [("stop", True, True)])
        self.assertEqual(watch.join(), 0)
        self.assertEqual(self.record()["state"], automation.STOPPED)
        self.device.wait(lambda: not self.device.alive(
            self.device.invocations()[0]["pid"]), 15, "the host ended")
        self.assertFalse(self.device.serving())
        self.assertEqual(self.nonces(), [first])

    def test_a_stop_that_cannot_name_the_hosts_group_fails(self) -> None:
        # Rule (R5): a record that names no supervisor and a nonce nothing
        # carries does not show the host gone; `stop --force` says so, and
        # fails, rather than reporting a host stopped that may still run.
        directory = self.device.state_dir / self.device.udid
        directory.mkdir(parents=True, exist_ok=True)
        automation.write_json(directory / "host.json", {
            "supervisor": None, "nonce": "e" * 32, "log": str(directory / "x.log"),
            "started": time.time() - 60, "seconds": 3600, "wait": 20})
        self.patch(automation, "send", mock.Mock(side_effect=automation.NoHost("no host")))
        with mock.patch.object(automation, "process_table", return_value=[]):
            self.assertEqual(automation.command_stop(self.options("stop", "--force")),
                             automation.EXIT_FAILED)
        self.assertTrue(any("could not be listed" in line for line in self.messages))

    def test_a_stop_without_force_is_refused_and_the_watch_runs_on(self) -> None:
        self.tune(HEARTBEAT_STALE=30)
        host = self.start_host()
        self.run_watch()
        self.wait_record(state=automation.WATCHING)
        self.assertEqual(automation.command_stop(self.options("stop")),
                         automation.EXIT_FAILED)
        self.progress()
        self.assertTrue(self.device.serving(host.nonce))
        self.assertTrue(automation.watch_summary(self.options("status"))["running"])

    def test_a_watch_that_will_not_end_keeps_the_host(self) -> None:
        # Rule: if the watch cannot be ended the host stays, as stopping it
        # would only have the watch start it again.
        self.tune(WATCH_END_WAIT=1)
        host = self.start_host()
        self.run_watch()
        self.wait_record(state=automation.WATCHING)
        self.patch(automation, "signal_watcher", lambda pid: None)
        self.patch(automation, "watcher_is_a_watch", lambda pid: True)
        self.assertEqual(automation.command_stop(self.options("stop", "--force")),
                         automation.EXIT_FAILED)
        self.assertTrue(self.device.serving(host.nonce))

    def test_start_is_refused_while_a_watch_runs(self) -> None:
        # Rule: a second host beside the watch's would ask for approval.
        self.tune(HEARTBEAT_STALE=30)
        self.start_host()
        self.run_watch()
        self.wait_record(state=automation.WATCHING)
        before = len(self.device.invocations())
        self.assertEqual(automation.command_start(self.options(
            "start", *self.reports())), automation.EXIT_FAILED)
        self.assertEqual(len(self.device.invocations()), before)
        self.assertTrue(any("watch is running" in message for message in self.messages))


class StatusTests(WatchTestCase):
    def test_status_shows_the_watch_and_its_last_end(self) -> None:
        first = self.watch_over_host()
        self.device.control(first, "die")
        self.watching(restarts=1)
        status = automation.watch_summary(self.options("status"))
        self.assertTrue(status["running"])
        self.assertEqual(status["pid"], os.getpid())
        self.assertEqual(status["state"], automation.WATCHING)
        self.assertEqual(status["restarts"], 1)
        self.assertIn("reason", status["last_end"])
        self.assertGreater(status["last_end"]["time"], 0)

    def test_a_watch_that_ended_without_a_word_is_shown_as_not_running(self) -> None:
        directory = self.device.state_dir / self.device.udid
        directory.mkdir(parents=True)
        (directory / "watch.json").write_text(json.dumps(
            {"state": automation.WATCHING, "pid": 1, "restarts": 3}))
        status = automation.watch_summary(self.options("status"))
        self.assertFalse(status["running"])
        self.assertIn("without recording why", status["meaning"])


class KeepAwakeTests(WatchTestCase):
    """A running watch holds an idle-sleep assertion of its own, and nothing
    more of the Mac's power: `caffeinate -i -w <pid>` (the fake one records its
    arguments and holds until the process it is told to wait for ends)."""

    def held(self) -> dict:
        calls = self.device.caffeinated()
        self.assertEqual(len(calls), 1, calls)
        return calls[0]

    def test_a_running_watch_holds_an_idle_sleep_assertion_and_nothing_more(self) -> None:
        # Rule: idle sleep only, for this watch's own pid; never the display
        # (-d), the user's activity (-u), system sleep (-s) or a timeout.
        self.watch_over_host()
        call = self.held()
        self.assertEqual(call["argv"], ["-i", "-w", str(os.getpid())])
        self.assertTrue(self.device.alive(call["pid"]))
        self.assertEqual(self.last_watch.end(), 0)
        self.assertFalse(self.device.alive(call["pid"]))

    def test_the_assertion_ends_with_the_watch_however_it_ends(self) -> None:
        # Rule: every exit path of the watch releases it before the watch
        # returns: stopped, needs-approval, cannot-observe and an error.
        def stopped():
            self.watch_over_host()
            self.assertEqual(self.last_watch.end(), 0)

        def needs_approval():
            self.device.scenarios([{"kind": "serve"}])
            first = self.watch_over_host()
            self.device.control(first, "relaunch-quiet")
            self.assertEqual(self.last_watch.join(), automation.EXIT_NEEDS_APPROVAL,
                             self.messages)

        def cannot_observe():
            self.assertEqual(self.run_watch().join(),
                             automation.EXIT_WATCH_CANNOT_OBSERVE, self.messages)

        def error():
            def fail(watch):
                # (the fake needs a moment to start and say it is holding)
                self.device.wait(lambda: self.device.caffeinated(), 15,
                                 "the assertion is held")
                raise RuntimeError("boom")
            with mock.patch.object(automation.Watch, "run", fail):
                self.assertEqual(self.run_watch().join(), automation.EXIT_FAILED)

        for ending in (stopped, needs_approval, cannot_observe, error):
            with self.subTest(ending.__name__):
                self.setUp()
                ending()
                self.assertFalse(self.device.alive(self.held()["pid"]))

    def test_a_watch_that_does_not_get_its_lock_holds_no_assertion(self) -> None:
        self.watch_over_host()
        held = self.held()
        self.assertEqual(self.run_watch().join(), automation.EXIT_WATCH_LOCKED)
        self.assertEqual(self.device.caffeinated(), [held])
        self.assertTrue(self.device.alive(held["pid"]))

    def test_a_watch_runs_on_where_the_assertion_cannot_be_held(self) -> None:
        # Rule: holding the assertion is not a condition of watching.
        for found, said in ((None, "no caffeinate"),
                            ("/nonexistent/caffeinate", "cannot start")):
            with self.subTest(found):
                self.setUp()
                with mock.patch.object(automation.shutil, "which",
                                       return_value=found):
                    self.watch_over_host()
                self.assertEqual(self.device.caffeinated(), [])
                self.assertTrue(any(said in message for message in self.messages),
                                self.messages)
                self.assertEqual(self.last_watch.end(), 0)


class LostConnectionTests(WatchTestCase):
    """xcodebuild reports the connection to the device lost, and some seconds
    later starts the runner again by itself, a runner that cannot initialize.
    The supervisor ends xcodebuild first, so the death is a plain one."""

    def test_a_lost_connection_ends_xcodebuild_before_it_starts_the_runner_again(self) -> None:
        # Rule: the host is replaced at once, with no latch and no word of an
        # approval: only one runner ever came up. Without the supervisor's
        # rule the fake xcodebuild starts a second runner 6 s later, which is
        # an unconfirmed relaunch and ends the watch with needs-approval.
        self.device.scenarios([{"kind": "serve"}, {"kind": "serve"}])
        host = self.start_host(hours=3)
        watch = self.run_watch()
        self.wait_record(state=automation.WATCHING)
        self.device.control(host.nonce, "connection-lost")
        second = self.watching(restarts=1)
        self.assertNotEqual(second, host.nonce)
        self.assertIsNone(watch.code, self.messages)
        self.invoked(2)
        text = host.log_path.read_text()
        self.assertEqual(text.count("Running tests..."), 1, text)
        self.assertIn("the device connection was lost at ", text)
        self.assertIn("ending xcodebuild before it starts the runner again", text)
        self.assertFalse(self.device.alive(self.device.invocations()[0]["pid"]))
        self.assertIsNone(automation.ApprovalLatch(self.options("status")).read())
        self.assertIn("the device connection was lost",
                      self.record()["last_end"]["reason"])
        self.assertTrue(any("started no runner again" in message
                            for message in self.messages), self.messages)
        self.assertTrue(self.device.serving(second))

    def test_another_launch_error_does_not_end_xcodebuild(self) -> None:
        # Rule: only CoreDevice error 3 is a lost connection. A failed launch
        # (code 10002) is xcodebuild's own, and it ends by itself.
        host = self.start_host(hours=3)
        self.device.control(host.nonce, "launch-failed")
        self.device.wait(lambda: "Code: 10002" in host.log_path.read_text(), 15,
                         "xcodebuild reports the failed launch")
        time.sleep(1.5)
        self.assertIsNone(host.process.poll())
        self.assertTrue(self.device.serving(host.nonce))
        self.assertNotIn("ending xcodebuild", host.log_path.read_text())


class RecordTests(WatchTestCase):
    """The watch's record says why the owner is needed."""

    CASES = (
        ("quiet", ("xcodebuild started the runner again at ",
                   "shows neither a restart notice nor a run of no tests",
                   "so the device may have asked for an approval nobody gave")),
        ("authentication", ("the system cancelled the approval prompt, as when "
                            "the screen locks during it",
                            "Code=-4 \"UI canceled by system.\"")),
        ("timeout", ("the approval prompt was not answered in time",
                     "Timed out while enabling automation mode")))

    def test_the_record_says_why_the_owner_is_needed(self) -> None:
        # Rule: the record `status` shows names the cause: a runner xcodebuild
        # started again that the log does not show initialized, or the
        # failure text of a device that would not enable automation (a locked
        # screen cancels the prompt), and a later watch refuses with the same
        # words.
        for failure, expected in self.CASES:
            with self.subTest(failure):
                self.setUp()
                self.device.scenarios([{"kind": "serve"}])
                first = self.watch_over_host()
                self.device.control(first, f"relaunch-{failure}")
                self.assertEqual(self.last_watch.join(),
                                 automation.EXIT_NEEDS_APPROVAL, self.messages)
                detail = self.record()["detail"]
                latch = automation.ApprovalLatch(self.options("status")).read()
                for text in expected:
                    self.assertIn(text, detail)
                    self.assertIn(text, latch["detail"])
                self.assert_ended_for(detail)
                summary = automation.watch_summary(self.options("status"))
                self.assertEqual(summary["detail"], detail)
                self.assertEqual(self.run_watch().join(),
                                 automation.EXIT_NEEDS_APPROVAL)
                self.assertIn(expected[0], self.record()["detail"])

    GENERIC = "the host that ended: its heartbeat stopped"

    def assert_ended_for(self, detail: str) -> str:
        """The record ends with the reason the watch called the host dead, as it
        recorded it in `last_end`, which is not the generic fallback; returns
        that reason."""
        reason = self.record()["last_end"]["reason"]
        self.assertTrue(detail.endswith(f"(the host that ended: {reason})"),
                        (detail, reason))
        self.assertNotIn(self.GENERIC, detail)
        self.assertNotEqual(reason, "its heartbeat stopped")
        return reason

    def test_the_record_gives_the_reason_the_host_was_called_dead_in_either_order(self) -> None:
        # Rule: the watch calls a host dead for one of two reasons when xcodebuild
        # started the runner again and the log says nothing of it: its
        # supervisor ended (xcodebuild exited), or the logged relaunch and the
        # stale heartbeat came first. Which it is depends on how soon xcodebuild
        # exits after the relaunch notice, which the test sets, and the record
        # carries that reason, not a generic one.
        orders = (
            ("the supervisor ended first", {"quiet_exit_after": 0},
             {"WATCH_GONE_AGE": 4.0},
             "the supervisor ended (xcodebuild exited with status 65)"),
            ("the relaunch was seen first", {"quiet_exit_after": 60}, {},
             "xcodebuild started the runner again, so the host's runner ended"))
        for what, scenario, constants, stem in orders:
            with self.subTest(what):
                self.setUp()
                self.tune(**constants)
                self.device.scenarios([dict(kind="serve", **scenario)])
                first = self.watch_over_host()
                self.device.control(first, "relaunch-quiet")
                self.assertEqual(self.last_watch.join(),
                                 automation.EXIT_NEEDS_APPROVAL, self.messages)
                reason = self.assert_ended_for(self.record()["detail"])
                self.assertTrue(reason.startswith(stem), reason)
                latch = automation.ApprovalLatch(self.options("status")).read()
                self.assertEqual(latch["kind"], "possible")
                self.invoked(1)

    def test_a_runner_that_never_served_is_named_with_its_time(self) -> None:
        self.tune(WATCH_RUNNER_WAIT=1.0)
        self.device.scenarios([{"kind": "serve"}, {"kind": "up-silent"}])
        first = self.watch_over_host()
        self.device.control(first, "die")
        self.assertEqual(self.last_watch.join(), automation.EXIT_NEEDS_APPROVAL,
                         self.messages)
        detail = self.record()["detail"]
        self.assertIn("a runner came up at ", detail)
        self.assertIn("that did not serve, and its log does not say why", detail)


class LogSignalTests(unittest.TestCase):
    """The lines of xcodebuild's own log the watch reads, as it prints them."""

    PROMPT = PROMPT
    RUNNER = ("2026-11-13 22:04:30.522108+0900 KernariumAutomation-Runner[11111:"
              "2222222] [Default] Running tests...")

    def scan(self, *lines: str, pid: int | None = None):
        """What the watch reads of a log; with `pid`, what the supervisor of the
        xcodebuild that has it reads."""
        with mock.patch("builtins.open", mock.mock_open(
                read_data=("\n".join(lines) + "\n").encode())):
            scan = automation.LogScan("log", xcodebuild_pid=pid)
            scan.read()
        return scan

    def test_the_prompt_timeout_is_told_from_other_initialization_failures(self) -> None:
        self.assertTrue(self.scan(self.RUNNER, self.PROMPT).approval_failure)
        other = self.PROMPT.replace("Timed out while enabling automation mode",
                                    "Timed out while loading Accessibility")
        scan = self.scan(self.RUNNER, other)
        self.assertFalse(scan.approval_failure)
        self.assertIn("Failed to initialize for UI testing", scan.init_failure)
        self.assertFalse(self.scan(self.RUNNER, "Test Suite started").approval_failure)

    def test_a_cancelled_authentication_is_an_approval_signal(self) -> None:
        # The device's failure when the owner's authentication was cancelled:
        # Domain and Code are what is matched, the description is localized.
        template = (
            "2026-11-14 00:05:00.059296+0900 KernariumAutomation-Runner[11111:"
            "2222222] [Default] Failed to initialize for UI testing: Error Domain="
            '{domain} Code={code} "{text}" UserInfo={{NSLocalizedDescription={text}}}')
        for text in ("UI canceled by system.", "认证已取消。", "Authentication was cancelled."):
            for code in ("-4", "-2"):
                with self.subTest(text=text, code=code):
                    scan = self.scan(self.RUNNER, template.format(
                        domain="com.apple.LocalAuthentication", code=code, text=text))
                    self.assertTrue(scan.approval_failure)
                    self.assertIn("LocalAuthentication", scan.describe())
        for domain, code in (("com.apple.LocalAuthentication", "-1"),
                             ("com.apple.LocalAuthentication", "-44"),
                             ("com.apple.dt.XCTest.XCTFuture", "-4"),
                             ("com.example.LocalAuthentication", "-4")):
            with self.subTest(domain=domain, code=code):
                scan = self.scan(self.RUNNER, template.format(
                    domain=domain, code=code, text="Something else."))
                self.assertFalse(scan.approval_failure)
                self.assertIn("Failed to initialize", scan.init_failure)
        # The same words outside the initialization failure are not it.
        self.assertFalse(self.scan(
            "Error Domain=com.apple.LocalAuthentication Code=-4").approval_failure)

    def test_a_runner_started_again_is_counted(self) -> None:
        self.assertEqual(self.scan(self.RUNNER).runner_up, 1)
        self.assertEqual(self.scan(self.RUNNER, "x", self.RUNNER).runner_up, 2)

    INITIALIZED = (
        "2026-11-13 23:38:22.997307+0900 KernariumAutomation-Runner[11111:2222222] "
        "[UIKit App Config] Update the Info.plist: Launch screens will soon be required.",
        "    t =      nans Interface orientation changed to Landscape Right",
        "",
        "Restarting after unexpected exit, crash, or test timeout; summary will "
        "include totals from previous launches.",
        "",
        "Test Suite 'Selected tests' started at 2026-11-13 23:38:23.798.",
        "Test Suite 'KernariumAutomation.xctest' passed at 2026-11-13 23:38:23.801.",
        "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds",
        "Test Suite 'Selected tests' passed at 2026-11-13 23:38:23.801.",
        "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.003) seconds",
        "** TEST EXECUTE FAILED **")

    def risk(self, scan, served=True):
        return automation.Watch.approval_risk([("n" * 32, scan, served)])

    def test_a_relaunched_runner_that_initialized_is_no_approval_risk(self) -> None:
        # Rule (round 4): the restart notice and then the totals of a run of no
        # tests, as xcodebuild prints them after the second "Running tests...".
        scan = self.scan(self.RUNNER, "Test Case started", self.RUNNER, *self.INITIALIZED)
        self.assertEqual(scan.runner_up, 2)
        self.assertEqual(scan.relaunches, ["initialized"])
        self.assertEqual(scan.unconfirmed_relaunches(), 0)
        self.assertIsNone(self.risk(scan))

    def test_a_relaunched_runner_that_failed_is_an_approval_risk(self) -> None:
        # Rule: the failure line (here as the device's timeout prints it, and
        # as an initialization failure that is not the approval's) is the owner's.
        failed = self.scan(self.RUNNER, self.RUNNER, self.PROMPT)
        self.assertEqual(failed.relaunches, ["failed"])
        self.assertEqual(self.risk(failed)[0], "observed")
        other = self.scan(self.RUNNER, self.RUNNER, self.PROMPT.replace(
            "Timed out while enabling automation mode", "Timed out while loading"))
        self.assertEqual(other.relaunches, ["failed"])
        self.assertEqual(self.risk(other)[0], "possible")

    def test_a_relaunch_that_initialized_then_one_that_failed_is_an_approval_risk(self) -> None:
        scan = self.scan(self.RUNNER, self.RUNNER, *self.INITIALIZED[3:8], self.RUNNER,
                         self.PROMPT)
        self.assertEqual(scan.relaunches, ["initialized", "failed"])
        self.assertEqual(self.risk(scan)[0], "observed")
        # And the other way round: the failure stands whatever else the log shows.
        scan = self.scan(self.RUNNER, self.RUNNER, self.PROMPT, self.RUNNER,
                         *self.INITIALIZED[3:8])
        self.assertEqual(scan.relaunches, ["failed", "initialized"])
        self.assertEqual(self.risk(scan)[0], "observed")

    def test_a_log_cut_inside_the_relaunch_pattern_is_not_taken_for_safe(self) -> None:
        # Rule (round 4): only the whole pattern shows the runner initialized.
        # Each prefix of it, and a runner that said nothing, is a possible
        # approval risk, as it was before the pattern was told.
        for cut in range(0, 8):
            with self.subTest(cut=cut):
                lines = self.INITIALIZED[3:3 + cut]
                scan = self.scan(self.RUNNER, self.RUNNER, *lines)
                whole = "Executed 0 tests" in "".join(lines)
                self.assertEqual(scan.unconfirmed_relaunches(), 0 if whole else 1)
                self.assertEqual(self.risk(scan) is None, whole)
        # The same lines before the restart notice, or of a first runner, do
        # not make a relaunch that initialized.
        scan = self.scan(self.RUNNER, self.INITIALIZED[7])
        self.assertEqual(scan.relaunches, [])
        scan = self.scan(self.RUNNER, self.RUNNER, self.INITIALIZED[7])
        self.assertEqual(scan.relaunches, ["pending"])
        self.assertIsNotNone(self.risk(scan))
        # Totals that are not those of a run of no tests are not the pattern.
        scan = self.scan(self.RUNNER, self.RUNNER, self.INITIALIZED[3],
                         "\t Executed 10 tests, with 0 failures (0 unexpected)")
        self.assertEqual(scan.relaunches, ["restarted"])
        # A line that is not yet complete is not taken.
        with mock.patch("builtins.open", mock.mock_open(read_data=(
                "\n".join((self.RUNNER, self.RUNNER, *self.INITIALIZED[3:7]))
                + "\n\t Executed 0 te").encode())):
            scan = automation.LogScan("log")
            scan.read()
        self.assertEqual(scan.relaunches, ["restarted"])
        self.assertIsNotNone(self.risk(scan))

    def test_only_a_runner_that_followed_a_serving_one_can_be_cleared_by_its_pattern(self) -> None:
        # Rule: the first runner of a launch that never served is a risk
        # whatever the log shows after it, as it was.
        scan = self.scan(self.RUNNER, *self.INITIALIZED[3:])
        self.assertIsNotNone(self.risk(scan, served=False))
        scan = self.scan(self.RUNNER, self.RUNNER, *self.INITIALIZED)
        self.assertIsNotNone(self.risk(scan, served=False))
        self.assertIsNone(self.risk(self.scan("Test Case started")))

    # What xcodebuild printed when the connection to the device was lost, and
    # when it could not launch a runner, in two logs of real hosts; the launch
    # report ids and the device are left out.
    XCODEBUILD = 4242
    LOST = [line.replace("{stamp}", "2026-11-15 10:34:52.158").replace("{pid}", "4242")
            for line in LOST_BLOCK]
    LAUNCH_FAILED = [line.replace("{stamp}", "2026-11-13 18:20:17.544")
                     .replace("{pid}", "4242") for line in LAUNCH_FAILED_BLOCK]
    # Lines of runs that were healthy, from the same logs.
    HEALTHY = (
        "ipad-automation: device reports (cap 25 per kind, 5 free needed): "
        "JetsamEvent 9 -> 9, Kernarium crash 0 -> 0; nothing to move",
        "Command line invocation:",
        "Writing result bundle at path:",
        RUNNER,
        "2026-11-14 13:17:44.428640+0900 KernariumAutomation-Runner[11111:2222222] "
        "[UIKit App Config] Update the Info.plist: Launch screens will soon be required.",
        "    t =      nans Interface orientation changed to Landscape Right",
        "Test Case '-[KernariumAutomation.AutomationHost testServe]' started.",
        "    t = 14549.77s     Requesting snapshot of accessibility hierarchy for app with pid 37",
        "AutomationHost: tap 01794554535041827000-ffb77e35 failed: no such element",
        "AutomationHost: tap 01794554535041827000-ffb77e35 failed: Failed to get "
        "matching snapshot: No matches found for first query match sequence: "
        "`Descendants matching type Any` -> `Elements matching predicate "
        "'label == \"x\"'`, given input label: ' '",
        "2026-11-15 10:35:31.982 xcodebuild[1:2]  IDETestOperationsObserverDebug: "
        "Failure collecting diagnostics from devices: Process exited with error 1:",
        "2026-11-15 10:35:31.999 xcodebuild[1:2] [MT] IDETestOperationsObserverDebug: "
        "76672.496 elapsed -- Testing started completed.",
        "Testing failed:",
        "Failing tests:",
        "** TEST EXECUTE FAILED **",
        *INITIALIZED)

    def test_a_lost_connection_is_told_from_xcodebuilds_block(self) -> None:
        # Rule: the connection to the device is lost when xcodebuild's launch
        # report ends in CoreDevice error 3, whose block is replayed as it was
        # printed. It is told once, at the time of the first header.
        scan = self.scan(self.RUNNER, *self.LOST)
        self.assertEqual(scan.connection_lost, "10:34:52")
        self.assertIn("the device connection was lost at 10:34:52 (CoreDevice "
                      "error 3)", scan.describe())
        self.assertEqual(scan.runner_up, 1)
        self.assertEqual(self.scan(self.RUNNER).connection_lost, None)

    def test_a_lost_connection_is_told_by_domain_and_code_not_by_description(self) -> None:
        # The description is localized like any other; the domain and the code
        # are not. The header is xcodebuild's own line in either spelling.
        for header in (self.LOST[0].replace("An error occurred while communicating "
                                            "with a remote process.", "Ein Fehler."),
                       self.LOST[0].replace("xcodebuild[4242:2] [MT] ",
                                            "xcodebuild[4242:2]  ")):
            with self.subTest(header):
                self.assertEqual(
                    self.scan(header, *self.LOST[1:],
                              pid=self.XCODEBUILD).connection_lost, "10:34:52")

    def test_nothing_but_the_whole_block_in_order_is_a_lost_connection(self) -> None:
        # Rule: no line of a healthy run, and no other CoreDevice error, ends
        # xcodebuild. The block of a failed launch (error 10002) is
        # xcodebuild's own end; its lines are consecutive too.
        header, domain, code = self.LOST[:3]
        variants = {
            "a failed launch": self.LAUNCH_FAILED,
            "no header": [line for line in self.LOST
                          if "IDELaunchReport" not in line],
            "the code without the domain": [header, code],
            "the domain without the code": [header, domain],
            "a blank line between": [header, "", domain, code],
            "another code": [header, domain, "Code: 30"],
            "another code, 13": [header, domain, "Code: 13"],
            "a code of another word": [header, domain, "Code: 3x"],
            "another domain": [header, "Domain: com.apple.Mercury.error", code],
            "an indented domain": [header, "  " + domain, code],
            "an indented code": [header, domain, "  " + code],
            "the order reversed": [code, domain, header],
            "an error of the runner": [
                "2026-11-15 10:34:52.158 KernariumAutomation-Runner[1:2] "
                "IDELaunchReport: x Finished with error: y", domain, code],
            "the words in the host's own report": [
                "AutomationHost: tap x failed: 2026-11-15 10:34:52.158 "
                "xcodebuild[4242:2] [MT] IDELaunchReport: x Finished with error: y",
                domain, code],
            "healthy lines": list(self.HEALTHY),
            # The host prints a failure's text with a prefix on its first
            # line only, so a sender's words with line breaks in them put whole
            # lines in the log: a modifier "\n" + the three lines.
            "a command's diagnostic with the lines of another xcodebuild": [
                "AutomationHost: key x failed: unknown modifier ",
                *[line.replace("[4242:", "[1:") for line in self.LOST[:3]]],
            "the block of another process, whole": [
                line.replace("[4242:", "[4243:") for line in self.LOST],
        }
        for what, lines in variants.items():
            with self.subTest(what):
                self.assertIsNone(
                    self.scan(self.RUNNER, *lines,
                              pid=self.XCODEBUILD).connection_lost)
        # A block cut after its header, with the rest read later, is the block.
        with __import__("tempfile").TemporaryDirectory() as scratch:
            path = Path(scratch) / "log"
            path.write_text("\n".join(self.LOST[:2]) + "\n")
            scan = automation.LogScan(str(path))
            scan.read()
            self.assertIsNone(scan.connection_lost)
            with open(path, "a") as handle:
                handle.write("\n".join(self.LOST[2:]) + "\n")
            scan.read()
            self.assertEqual(scan.connection_lost, "10:34:52")

    def test_only_the_xcodebuild_a_supervisor_started_can_report_the_loss(self) -> None:
        # Rule: the supervisor ends the xcodebuild it started, so the header's
        # pid must be that one's. The watch's own reading only words the record
        # and takes the block of any xcodebuild.
        for pid, told in ((self.XCODEBUILD, "10:34:52"), (self.XCODEBUILD + 1, None),
                          (1, None), (None, "10:34:52")):
            with self.subTest(pid=pid):
                self.assertEqual(
                    self.scan(self.RUNNER, *self.LOST, pid=pid).connection_lost, told)

    def test_a_line_ends_only_at_a_newline(self) -> None:
        # Rule: the log's lines are those ending in a newline. A sender's
        # words that carry another line separator (a carriage return, a form
        # feed, Unicode's line and paragraph separators, ...) do not start a
        # line of their own, so they cannot put a header at the start of one,
        # even with the right pid.
        header, rest = self.LOST[0], self.LOST[1:3]
        for separator in ("\r", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x85",
                          "\u2028", "\u2029"):
            with self.subTest(separator=separator.encode("unicode_escape")):
                text = "AutomationHost: key x failed: unknown modifier " + separator
                scan = self.scan(text + header, *rest, pid=self.XCODEBUILD)
                self.assertIsNone(scan.connection_lost)
        # A carriage return that ends a line, as a terminal's does, is a newline's.
        with mock.patch("builtins.open", mock.mock_open(read_data=(
                "\r\n".join(self.LOST) + "\r\n").encode())):
            scan = automation.LogScan("log", xcodebuild_pid=self.XCODEBUILD)
            scan.read()
        self.assertEqual(scan.connection_lost, "10:34:52")

    def test_the_record_of_a_runner_started_again_after_a_lost_connection(self) -> None:
        # Rule: what xcodebuild did by itself (older supervisors, or one that
        # was not scheduled) is told in the record: the connection lost, the
        # time of the runner started again, and what its log does not show.
        second = ("2026-11-15 10:35:10.779641+0900 KernariumAutomation-Runner"
                  "[11111:2222222] [Default] Running tests...")
        scan = self.scan(self.RUNNER, *self.LOST, second)
        risk = self.risk(scan)
        self.assertEqual(risk[0], "possible")
        self.assertIn(
            "the device connection was lost at 10:34:52 (CoreDevice error 3); "
            "xcodebuild started the runner again at 10:35:10 after the host's "
            "runner ended; its log shows neither a restart notice nor a run of "
            "no tests, so the device may have asked for an approval nobody gave",
            risk[2])
        # Cut at the restart notice, and failed for another reason.
        scan = self.scan(self.RUNNER, second, self.INITIALIZED[3])
        self.assertIn("shows the restart notice and not the run of no tests that "
                      "follows", self.risk(scan)[2])
        other = self.PROMPT.replace("Timed out while enabling automation mode",
                                    "Timed out while loading")
        scan = self.scan(self.RUNNER, second, other)
        self.assertIn("shows an initialization failure (Failed to initialize for "
                      "UI testing: ", self.risk(scan)[2])

    def test_a_launch_that_never_served_is_named_with_the_time_its_runner_came_up(self) -> None:
        scan = self.scan(self.RUNNER)
        risk = self.risk(scan, served=False)
        self.assertEqual(risk[2], "a runner came up at 22:04:30 that did not "
                                  "serve, and its log does not say why, so the "
                                  "device may have asked for an approval nobody "
                                  "gave")

    def test_the_failure_of_the_approval_is_told_with_its_cause(self) -> None:
        # Rule: the record names what went wrong with the approval (a locked
        # screen cancels the prompt: code -4), not only the device's text.
        template = (
            "2026-11-14 00:05:00.059296+0900 KernariumAutomation-Runner[11111:"
            "2222222] [Default] Failed to initialize for UI testing: Error Domain="
            'com.apple.LocalAuthentication Code={code} "{text}" UserInfo={{}}')
        for code, cause in (("-4", "the system cancelled the approval prompt, as "
                                   "when the screen locks during it"),
                            ("-2", "the owner cancelled the approval prompt")):
            with self.subTest(code):
                description = self.scan(self.RUNNER, template.format(
                    code=code, text="UI canceled by system.")).describe()
                self.assertIn(f"{cause}: Failed to initialize for UI testing: "
                              f"Error Domain=com.apple.LocalAuthentication "
                              f"Code={code}", description)
        self.assertIn("the approval prompt was not answered in time: Failed to "
                      "initialize", self.scan(self.RUNNER, self.PROMPT).describe())

    def test_the_supervisors_exit_line_is_read(self) -> None:
        scan = self.scan("ipad-automation: xcodebuild exited with status 65")
        self.assertIn("status 65", scan.describe())

    def test_a_line_is_taken_once_it_is_complete(self) -> None:
        with mock.patch("builtins.open", mock.mock_open(
                read_data=(self.RUNNER + "\n" + self.RUNNER[:30]).encode())):
            scan = automation.LogScan("log")
            scan.read()
        self.assertEqual(scan.runner_up, 1)

    def test_a_line_that_is_completed_by_a_later_read_is_taken_then(self) -> None:
        # The prompt's line arrives in two pieces, as a log written while it is
        # read can show it: the first read keeps the piece, the second has it.
        with __import__("tempfile").TemporaryDirectory() as scratch:
            path = Path(scratch) / "log"
            path.write_text(self.PROMPT[:80])
            scan = automation.LogScan(str(path))
            scan.read()
            self.assertFalse(scan.approval_failure)
            with open(path, "a") as handle:
                handle.write(self.PROMPT[80:] + "\n")
            scan.read()
            self.assertTrue(scan.approval_failure)


if __name__ == "__main__":
    automation_shards.main()
