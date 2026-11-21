"""独立实验单测；不读取或修改既有网络实现。"""

import contextlib
import copy
import io
import socket
import threading
import time
import unittest
from unittest import mock

from tools import network_udp_wait_probe as probe


class SocketProxy:
    """仅用于注入 bind/收包故障，仍由被测线程创建和关闭真实 socket。"""

    def __init__(self, sock, fail_bind=False, fail_receive=False):
        self.sock = sock
        self.fail_bind = fail_bind
        self.fail_receive = fail_receive

    def __getattr__(self, name):
        return getattr(self.sock, name)

    def bind(self, address):
        if self.fail_bind:
            raise OSError("injected bind failure")
        return self.sock.bind(address)

    def recvfrom(self, size):
        if self.fail_receive:
            raise OSError("injected receive failure")
        return self.sock.recvfrom(size)


class ProbeTests(unittest.TestCase):
    def keep_worker(self, worker):
        def cleanup():
            worker.request_stop()
            self.assertTrue(worker.join(), "测试 worker 未退出")
        self.addCleanup(cleanup)
        return worker

    def keep_fixture(self, fixture):
        def cleanup():
            fixture.request_stop()
            self.assertTrue(fixture.join(), "测试 fixture 未退出")
        self.addCleanup(cleanup)
        return fixture

    def check_case(self, result):
        self.assertTrue(result["passed"], result["failures"])
        for name in ("worker", "fixture"):
            state = result[name]
            self.assertFalse(state["alive"])
            self.assertEqual(state["created"], result["sessions"] * 2)
            self.assertEqual(state["created"], state["closed"])
            self.assertEqual(state["errors"], [])
            for row in state["slots"]:
                self.assertEqual((row["created"], row["closed"]), (1, 1))
                self.assertEqual(row["send_errors"], 0)
                self.assertEqual(row["receive_errors"], 0)

    def test_percentiles_empty(self):
        self.assertEqual(probe.percentiles([]), {
            "count": 0, "p50_ns": None, "p95_ns": None, "p99_ns": None, "max_ns": None})

    def test_percentiles_nearest_rank(self):
        values = list(range(100, 0, -1))
        self.assertEqual(probe.percentiles(values), {
            "count": 100, "p50_ns": 50, "p95_ns": 95, "p99_ns": 99, "max_ns": 100})
        self.assertEqual(values[0], 100)
        self.assertEqual(probe.percentiles([7])["p99_ns"], 7)

    def test_cli_defaults(self):
        args = probe.parse_args(["--label", "unit_ASCII-1"])
        self.assertEqual(args.rounds, 3)
        self.assertEqual(args.sessions, [1, 2, 3])
        self.assertEqual(args.modes, ["sleep", "select"])

    def test_cli_invalid_parameters(self):
        invalid = [[], ["--label", "../escape"], ["--label", "中文"],
                   ["--label", "a.b"], ["--label", ""], ["--label", "a" * 65],
                   ["--label", "x", "--rounds", "0"],
                   ["--label", "x", "--rounds", "101"],
                   ["--label", "x", "--sessions", "0"],
                   ["--label", "x", "--sessions", "1", "1"],
                   ["--label", "x", "--modes", "select", "select"],
                   ["--label", "x", "--modes", "poll"]]
        for args in invalid:
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    probe.parse_args(args)

    def test_invalid_worker_and_fixture(self):
        for sessions, mode in ((0, "select"), (4, "sleep"), (True, "select"), (1, "poll")):
            with self.assertRaises(ValueError):
                probe.Worker(sessions, mode)
        with self.assertRaises(ValueError):
            probe.Fixture([], "idle", duration=0.010)
        with self.assertRaises(ValueError):
            probe.run_case(1, "select", "bad")

    def test_ab_ba_plan_seed_independent(self):
        plan = list(probe.case_plan(2, [1], ["sleep", "select"]))
        self.assertEqual([p[2] for p in plan[:4]], ["sleep", "select", "select", "sleep"])
        self.assertEqual([p[2] for p in plan[8:10]], ["select", "sleep"])
        self.assertEqual(len(plan), 16)
        self.assertEqual({p[3] for p in plan}, set(probe.SCENARIOS))

    def test_idle_no_packets_external_stop_both_modes(self):
        for mode in probe.MODES:
            with self.subTest(mode=mode):
                result = probe.run_case(1, mode, "idle")
                self.check_case(result)
                self.assertTrue(result["idle_stop_wait_boundary"])
                self.assertEqual(result["sent"], 0)
                self.assertEqual(result["echoed"], 0)
                self.assertEqual(result["rtt"]["count"], 0)
                worker = result["worker"]
                self.assertGreater(worker["timeouts"], 0)
                self.assertGreater(worker["wait_requested_ns"], 0)
                self.assertGreater(worker["wait_actual_ns"], 0)
                # join 是看门狗；不把 select 5ms 宣称为 stop 硬上界。
                self.assertIsNotNone(worker["stop_to_finally_ns"])

    def test_last_only_all_six_slots_waited(self):
        for mode in probe.MODES:
            with self.subTest(mode=mode):
                result = probe.run_case(3, mode, "last_only")
                self.check_case(result)
                self.assertEqual([r["sent"] for r in result["fixture"]["slots"]], [0, 0, 0, 0, 0, 12])
                self.assertEqual(result["worker"]["slots"][0]["received"], 0)
                self.assertEqual(result["worker"]["slots"][-1]["echoed"], 12)

    def test_rotation_pressure_sparse_slots_complete(self):
        for mode in probe.MODES:
            with self.subTest(mode=mode):
                result = probe.run_case(3, mode, "mixed")
                self.check_case(result)
                counts = result["worker"]["rotation_counts"]
                self.assertGreater(min(counts), 0)
                self.assertLessEqual(max(counts) - min(counts), 1)
                for row in result["fixture"]["slots"][1:]:
                    self.assertEqual(row["sent"], result["fixture_waves"])
                    self.assertEqual(row["sent"], row["echoed"])
                    self.assertEqual((row["missing"], row["duplicates"]), (0, 0))
                    self.assertGreater(row["max_service_gap_ns"], 0)

    def test_stop_under_continuous_source_not_lossless_claim(self):
        for mode in probe.MODES:
            with self.subTest(mode=mode):
                result = probe.run_case(2, mode, "stop_load")
                self.check_case(result)
                self.assertFalse(result["lossless_asserted"])
                self.assertTrue(result["source_active_at_stop_confirmation"])
                self.assertGreaterEqual(result["fixture"]["source_stopped_ns"],
                                        result["stop_confirmation_ns"])
                for row in result["fixture"]["slots"]:
                    self.assertEqual(row["missing"], row["sent"] - row["echoed"])
                    self.assertEqual(row["unconfirmed_at_stop"],
                                     row["sent_before_stop"] - row["acked_before_stop"])

    def test_worker_partial_bind_failure_closes_all_created(self):
        owners = []
        closes = []

        class OwnedSocket(SocketProxy):
            def close(self):
                closes.append(threading.get_ident())
                return self.sock.close()

        def factory(*args):
            owners.append(threading.get_ident())
            return OwnedSocket(socket.socket(*args), fail_bind=len(owners) == 3)

        worker = self.keep_worker(probe.Worker(3, "select", socket_factory=factory))
        self.assertFalse(worker.start())
        self.assertTrue(worker.join())
        state = worker.snapshot()
        self.assertEqual((state["created"], state["closed"]), (3, 3))
        self.assertTrue(state["errors"])
        self.assertEqual(owners, closes)
        self.assertNotIn(threading.get_ident(), owners)
        self.assertFalse(state["alive"])

    def test_worker_socket_creation_failure(self):
        calls = []

        def factory(*args):
            calls.append(1)
            if len(calls) == 2:
                raise OSError("injected creation failure")
            return socket.socket(*args)

        worker = self.keep_worker(probe.Worker(1, "select", socket_factory=factory))
        self.assertFalse(worker.start())
        self.assertTrue(worker.join())
        state = worker.snapshot()
        self.assertEqual((state["created"], state["closed"]), (1, 1))
        self.assertTrue(state["errors"])

    def test_startup_timeout_is_failure_and_cleans(self):
        entered = threading.Event()

        def factory(*args):
            entered.set()
            # 受控启动延迟有上界，不创建无人能结束的阻塞。
            threading.Event().wait(0.030)
            return socket.socket(*args)

        worker = self.keep_worker(probe.Worker(1, "select", socket_factory=factory))
        self.assertFalse(worker.start(timeout=0.001))
        self.assertTrue(entered.is_set())
        self.assertTrue(worker.join())
        state = worker.snapshot()
        self.assertIn("worker startup timeout", state["errors"])
        self.assertEqual(state["created"], state["closed"])
        self.assertFalse(state["alive"])

    def test_stop_idempotent_and_restart_rejected(self):
        worker = self.keep_worker(probe.Worker(1, "select"))
        self.assertTrue(worker.start())
        self.assertTrue(worker.wait_for_wait())
        worker.request_stop()
        first = worker.snapshot()["stop_requested_ns"]
        worker.request_stop()
        self.assertTrue(worker.join())
        worker.request_stop()
        self.assertEqual(worker.snapshot()["stop_requested_ns"], first)
        with self.assertRaises(RuntimeError):
            worker.start()
        fresh = self.keep_worker(probe.Worker(1, "select"))
        self.assertTrue(fresh.start())
        fresh.request_stop()
        self.assertTrue(fresh.join())
        self.assertEqual(fresh.snapshot()["errors"], [])

    def test_stop_before_start_not_normal_success(self):
        worker = self.keep_worker(probe.Worker(1, "select"))
        worker.request_stop()
        self.assertFalse(worker.start())
        self.assertTrue(worker.join())
        self.assertEqual(worker.snapshot()["created"], 0)
        self.assertTrue(worker.snapshot()["errors"])

    def test_snapshot_cannot_mutate_worker(self):
        worker = self.keep_worker(probe.Worker(1, "select"))
        self.assertTrue(worker.start())
        state = worker.snapshot()
        state["slots"][0]["closed"] = 999
        state["errors"].append("fake")
        state["rotation_counts"][0] = -1
        self.assertNotEqual(worker.snapshot()["slots"][0]["closed"], 999)
        self.assertNotIn("fake", worker.snapshot()["errors"])
        self.assertNotEqual(worker.snapshot()["rotation_counts"][0], -1)

    def test_worker_receive_fault_cannot_pass(self):
        def factory(*args):
            return SocketProxy(socket.socket(*args), fail_receive=True)

        def worker_factory(sessions, mode):
            return probe.Worker(sessions, mode, socket_factory=factory)

        result = probe.run_case(1, "sleep", "idle", worker_factory=worker_factory)
        self.assertFalse(result["passed"])
        self.assertTrue(result["worker"]["errors"])
        self.assertEqual(result["worker"]["created"], result["worker"]["closed"])
        self.assertFalse(result["worker"]["alive"])
        self.assertGreater(result["worker"]["slots"][0]["receive_errors"], 0)

    def test_fixture_partial_bind_failure_cleanup(self):
        calls = []

        def factory(*args):
            calls.append(1)
            return SocketProxy(socket.socket(*args), fail_bind=len(calls) == 2)

        fixture = self.keep_fixture(probe.Fixture(
            [("127.0.0.1", 9)] * 2, "idle", socket_factory=factory))
        self.assertFalse(fixture.start())
        self.assertTrue(fixture.join())
        state = fixture.snapshot()
        self.assertEqual((state["created"], state["closed"]), (2, 2))
        self.assertTrue(state["errors"])
        self.assertFalse(state["alive"])
        with self.assertRaises(RuntimeError):
            fixture.start()

    def test_sample_bound_reports_overflow_not_missing(self):
        def fixture_factory(*args, **kwargs):
            return probe.Fixture(*args, sample_limit=3, **kwargs)

        result = probe.run_case(1, "select", "last_only", fixture_factory=fixture_factory)
        self.check_case(result)
        row = result["fixture"]["slots"][-1]
        self.assertEqual(row["rtt"]["count"], 3)
        self.assertEqual(row["sample_overflow"], 9)
        self.assertEqual(row["echoed"], 12)
        self.assertEqual(row["missing"], 0)

    def test_slow_send_is_exposed_without_changing_round_trip(self):
        class SlowSend(SocketProxy):
            def __init__(self, sock):
                super().__init__(sock)
                self.first = True

            def sendto(self, payload, peer):
                if self.first:
                    self.first = False
                    time.sleep(0.030)
                return self.sock.sendto(payload, peer)

        def fixture_factory(*args, **kwargs):
            return probe.Fixture(*args, socket_factory=lambda *a: SlowSend(socket.socket(*a)), **kwargs)

        result = probe.run_case(1, "select", "last_only", fixture_factory=fixture_factory)
        self.check_case(result)
        row = result["fixture"]["slots"][-1]
        self.assertGreaterEqual(row["send_call_max_ns"], 20_000_000)
        self.assertLessEqual(len(row["slowest_samples"]), 8)
        first = next(item for item in row["slowest_samples"] if item["seq"] == 0)
        self.assertGreaterEqual(first["send_call_ns"], 20_000_000)
        for item in row["slowest_samples"]:
            self.assertEqual(item["rtt_ns"], item["pre_send_ns"] +
                             item["send_call_ns"] + item["after_send_return_ns"])
            for key in ("pre_send_ns", "send_call_ns", "after_send_return_ns", "receive_call_ns"):
                self.assertGreaterEqual(item[key], 0)
        self.assertEqual(row["rtt"]["max_ns"], row["slowest_samples"][0]["rtt_ns"])

    def test_missing_duplicate_invalid_and_io_errors_fail_gate(self):
        valid = probe.run_case(1, "select", "mixed")
        self.check_case(valid)
        for key in ("missing", "duplicates", "invalid", "send_errors", "receive_errors", "tracking_overflow"):
            with self.subTest(key=key):
                broken = copy.deepcopy(valid)
                broken["fixture"]["slots"][1][key] += 1
                self.assertTrue(probe.evaluate_case(broken))
        broken = copy.deepcopy(valid)
        broken["fixture"]["slots"][1]["echoed"] -= 1
        self.assertTrue(probe.evaluate_case(broken))

    def test_watchdog_failure_never_normal_pass(self):
        class FalseWatchdog(probe.Worker):
            def join(self, timeout=1.0):
                super().join(timeout)
                return False

        result = probe.run_case(1, "select", "idle", worker_factory=FalseWatchdog)
        self.assertFalse(result["passed"])
        self.assertIn("worker join(1s) watchdog failed", result["failures"])
        self.assertFalse(result["worker"]["alive"])
        self.assertFalse(result["fixture"]["alive"])

    def test_select_failure_cleanup_and_not_success(self):
        real_select = probe.select.select

        def injected(*args):
            if threading.current_thread().name == "udp-wait-worker":
                raise OSError("injected select failure")
            return real_select(*args)

        with mock.patch.object(probe.select, "select", side_effect=injected):
            result = probe.run_case(1, "select", "idle")
        self.assertFalse(result["passed"])
        self.assertFalse(result["worker"]["alive"])
        self.assertEqual(result["worker"]["created"], result["worker"]["closed"])
        self.assertTrue(result["worker"]["errors"])

    def test_fixture_rejects_non_loopback(self):
        for addresses in ([], [("0.0.0.0", 9)] * 2,
                          [("192.0.2.1", 9)] * 2, [("127.0.0.1", 0)] * 2):
            with self.subTest(addresses=addresses), self.assertRaises(ValueError):
                probe.Fixture(addresses, "idle")

    def test_stop_load_checkpoint_cannot_hide_missing_sparse_packet(self):
        result = probe.run_case(2, "select", "stop_load")
        self.check_case(result)
        self.assertGreater(result["fixture"]["post_confirmation_sent"], 0)
        for row in result["fixture"]["slots"]:
            self.assertEqual(row["checkpoint_unconfirmed"], 0)
            self.assertEqual(row["checkpoint_sent"], row["checkpoint_acked"])
        broken = copy.deepcopy(result)
        broken["fixture"]["slots"][-1]["checkpoint_acked"] -= 1
        self.assertTrue(probe.evaluate_case(broken))

    def test_real_duplicate_and_wrong_slot_receipts_fail(self):
        class BadEcho(SocketProxy):
            def sendto(self, payload, peer):
                packet = probe.json.loads(payload)
                wrong = probe.json.dumps([packet[0] + 1, packet[1], packet[2]]).encode("ascii")
                self.sock.sendto(wrong, peer)
                self.sock.sendto(payload, peer)
                return self.sock.sendto(payload, peer)

        def factory(sessions, mode):
            return probe.Worker(sessions, mode, socket_factory=lambda *a: BadEcho(socket.socket(*a)))

        result = probe.run_case(1, "select", "last_only", worker_factory=factory)
        self.assertFalse(result["passed"])
        row = result["fixture"]["slots"][-1]
        self.assertEqual(row["echoed"], 12)
        self.assertEqual(row["duplicates"], 12)
        self.assertEqual(row["invalid"], 12)
        self.assertFalse(result["worker"]["alive"])
        self.assertFalse(result["fixture"]["alive"])

    def test_fixture_receive_fault_fails_and_cleans(self):
        def factory(*args, **kwargs):
            return probe.Fixture(*args, socket_factory=lambda *a:
                                 SocketProxy(socket.socket(*a), fail_receive=True), **kwargs)

        result = probe.run_case(1, "select", "last_only", fixture_factory=factory)
        self.assertFalse(result["passed"])
        self.assertTrue(result["fixture"]["errors"])
        self.assertEqual(result["fixture"]["created"], result["fixture"]["closed"])
        self.assertFalse(result["fixture"]["alive"])
        self.assertGreater(result["fixture"]["slots"][-1]["receive_errors"], 0)

    def test_nonblocking_send_fault_counted_and_fails(self):
        class BlockedSend(SocketProxy):
            def sendto(self, payload, peer):
                raise BlockingIOError("injected nonblocking send")

        def factory(sessions, mode):
            return probe.Worker(sessions, mode, socket_factory=lambda *a: BlockedSend(socket.socket(*a)))

        result = probe.run_case(1, "select", "last_only", worker_factory=factory)
        self.assertFalse(result["passed"])
        self.assertEqual(result["worker"]["slots"][-1]["send_errors"], 12)
        self.assertEqual(result["missing"], 12)
        self.assertFalse(result["worker"]["alive"])
        self.assertFalse(result["fixture"]["alive"])

    def test_worker_socket_operations_remain_on_owner(self):
        operations = []

        class OwnedSocket(SocketProxy):
            def record(self, name):
                operations.append((name, threading.get_ident()))

            def bind(self, address):
                self.record("bind")
                return self.sock.bind(address)

            def setblocking(self, flag):
                self.record("nonblocking")
                return self.sock.setblocking(flag)

            def recvfrom(self, size):
                self.record("recv")
                return self.sock.recvfrom(size)

            def sendto(self, payload, peer):
                self.record("send")
                return self.sock.sendto(payload, peer)

            def close(self):
                self.record("close")
                return self.sock.close()

        def factory(sessions, mode):
            def create(*args):
                operations.append(("create", threading.get_ident()))
                return OwnedSocket(socket.socket(*args))
            return probe.Worker(sessions, mode, socket_factory=create)

        result = probe.run_case(1, "select", "last_only", worker_factory=factory)
        self.check_case(result)
        self.assertEqual(len({owner for _, owner in operations}), 1)
        self.assertNotIn(threading.get_ident(), {owner for _, owner in operations})
        self.assertEqual({name for name, _ in operations},
                         {"create", "bind", "nonblocking", "recv", "send", "close"})

    def test_budget_hits_are_recorded(self):
        class SlowReceive(SocketProxy):
            def recvfrom(self, size):
                packet = self.sock.recvfrom(size)
                time.sleep(0.001)
                return packet

        def factory(sessions, mode):
            return probe.Worker(sessions, mode, socket_factory=lambda *a: SlowReceive(socket.socket(*a)))

        result = probe.run_case(1, "select", "last_only", worker_factory=factory)
        self.check_case(result)
        self.assertGreater(result["worker"]["budget_hits"], 0)

    def test_fixture_startup_timeout_cleanup(self):
        def create(*args):
            threading.Event().wait(0.030)
            return socket.socket(*args)

        fixture = self.keep_fixture(probe.Fixture(
            [("127.0.0.1", 9)] * 2, "idle", socket_factory=create))
        self.assertFalse(fixture.start(timeout=0.001))
        self.assertTrue(fixture.join())
        state = fixture.snapshot()
        self.assertIn("fixture startup timeout", state["errors"])
        self.assertEqual(state["created"], state["closed"])
        self.assertFalse(state["alive"])

    def test_cancel_propagates_after_owned_threads_cleanup(self):
        for interrupt in (KeyboardInterrupt, SystemExit):
            with self.subTest(interrupt=interrupt.__name__):
                workers, fixtures = [], []

                def worker_factory(sessions, mode):
                    worker = probe.Worker(sessions, mode)
                    workers.append(worker)
                    return worker

                class CancelFixture(probe.Fixture):
                    def start(self, timeout=1.0):
                        if not super().start(timeout):
                            raise RuntimeError("fixture failed before cancellation")
                        raise interrupt("injected cancellation")

                def fixture_factory(*args, **kwargs):
                    fixture = CancelFixture(*args, **kwargs)
                    fixtures.append(fixture)
                    return fixture

                with self.assertRaises(interrupt):
                    probe.run_case(1, "select", "mixed",
                                   worker_factory=worker_factory,
                                   fixture_factory=fixture_factory)
                for owned in workers + fixtures:
                    self.assertTrue(owned.join())
                    state = owned.snapshot()
                    self.assertFalse(state["alive"])
                    self.assertEqual(state["created"], state["closed"])
                    self.assertEqual(state["errors"], [])

    def test_main_cancellation_saves_evidence_and_stops_matrix(self):
        class MemoryResult(io.StringIO):
            def close(self):
                self.captured = self.getvalue()
                super().close()

        stream = MemoryResult()
        with mock.patch.object(probe.Path, "is_dir", return_value=True), \
                mock.patch.object(probe.Path, "open", return_value=stream), \
                mock.patch.object(probe, "run_case", side_effect=KeyboardInterrupt("cancel")) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(probe.main(["--label", "cancelled", "--rounds", "3"]), 1)
        self.assertEqual(run.call_count, 1)
        report = probe.json.loads(stream.captured)
        self.assertFalse(report["passed"])
        self.assertEqual(len(report["cases"]), 1)
        self.assertTrue(report["cases"][0]["errors"])
        self.assertIn("KeyboardInterrupt", report["errors"][0])

    def test_main_refuses_overwrite_without_running_cases(self):
        with mock.patch.object(probe.Path, "is_dir", return_value=True), \
                mock.patch.object(probe.Path, "open", side_effect=FileExistsError), \
                mock.patch.object(probe, "run_case") as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(probe.main(["--label", "existing"]), 2)
        run.assert_not_called()

    def test_main_retains_case_evidence_on_unexpected_failure(self):
        class MemoryResult(io.StringIO):
            def close(self):
                self.captured = self.getvalue()
                super().close()

        stream = MemoryResult()
        with mock.patch.object(probe.Path, "is_dir", return_value=True), \
                mock.patch.object(probe.Path, "open", return_value=stream), \
                mock.patch.object(probe, "run_case", side_effect=RuntimeError("injected case fault")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(probe.main(["--label", "evidence", "--rounds", "1"]), 1)
        report = probe.json.loads(stream.captured)
        self.assertFalse(report["passed"])
        self.assertEqual(len(report["cases"]), 1)
        self.assertFalse(report["cases"][0]["passed"])
        self.assertTrue(report["cases"][0]["errors"])


if __name__ == "__main__":
    unittest.main()
