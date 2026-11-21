"""仅限本机 UDP 的独立等待实验；不是 Godot、ENet 或生产网络实现。"""

import argparse
import json
from pathlib import Path
import re
import select
import socket
import sys
import threading
import time


SCENARIOS = ("idle", "last_only", "mixed", "stop_load")
MODES = ("sleep", "select")
DURATION = 0.320
SELECT_TIMEOUT = 0.005
SLEEP_TIMEOUT = 0.001
PUMP_BUDGET_NS = 2_000_000
PER_DIRECTION_LIMIT = 64
SAMPLE_LIMIT = 4096
SEED = 82417


def percentiles(samples):
    """nearest-rank 分位数；空样本不伪造为零延迟。"""
    values = sorted(samples)
    if not values:
        return {"count": 0, "p50_ns": None, "p95_ns": None,
                "p99_ns": None, "max_ns": None}
    n = len(values)
    return {"count": n, **{
        "p%d_ns" % p: values[max(0, (n * p + 99) // 100 - 1)]
        for p in (50, 95, 99)}, "max_ns": values[-1]}


class Worker:
    """一次性 worker；start/request_stop/join/snapshot/wait_for_wait 为外部 API。

    socket 只存在于 _run 的局部变量，外部只有不可变地址快照。
    wait_entered 是真实等待调用前的边界通知，不声称能观测内核进入时刻。
    """

    def __init__(self, sessions, mode, socket_factory=socket.socket):
        if type(sessions) is not int or sessions not in (1, 2, 3):
            raise ValueError("sessions 必须为 1、2 或 3")
        if mode not in MODES:
            raise ValueError("mode 必须为 sleep 或 select")
        self.sessions = sessions
        self.mode = mode
        self._factory = socket_factory
        self._stop = threading.Event()
        self.ready = threading.Event()
        self.done = threading.Event()
        self.wait_entered = threading.Event()
        self._lock = threading.Lock()
        self._thread = None
        self._started = False
        self._stop_ns = None
        self._external_errors = []
        self._view = {}
        self._publish(self._empty_stats())

    def _empty_stats(self):
        return {"mode": self.mode, "sessions": self.sessions,
                "created": 0, "closed": 0, "addresses": [], "errors": [],
                "iterations": 0, "budget_hits": 0, "direction_limit_hits": 0,
                "rotation_counts": [0] * (self.sessions * 2),
                "wait_calls": 0, "wait_requested_ns": 0, "wait_actual_ns": 0,
                "wait_max_ns": 0, "timeouts": 0, "wakeups": 0,
                "cpu_ns": 0, "wall_ns": 0, "cpu_wall_percent": 0.0,
                "started_ns": None, "finally_done_ns": None,
                "slots": [{"slot": i, "created": 0, "closed": 0,
                           "received": 0, "echoed": 0, "send_errors": 0,
                           "receive_errors": 0}
                          for i in range(self.sessions * 2)]}

    def _publish(self, stats):
        # 只拷贝数值和地址，不泄露 socket；锁内从不等待网络。
        view = dict(stats)
        for key in ("addresses", "errors", "rotation_counts"):
            view[key] = list(stats[key])
        view["slots"] = [dict(row) for row in stats["slots"]]
        with self._lock:
            self._view = view

    def snapshot(self):
        with self._lock:
            view = dict(self._view)
            for key in ("addresses", "errors", "rotation_counts"):
                view[key] = list(view[key])
            view["slots"] = [dict(row) for row in view["slots"]]
            view["errors"].extend(self._external_errors)
            view["stop_requested_ns"] = self._stop_ns
        end = view["finally_done_ns"]
        view["stop_to_finally_ns"] = (
            end - view["stop_requested_ns"]
            if end is not None and view["stop_requested_ns"] is not None else None)
        view["alive"] = self._thread is not None and self._thread.is_alive()
        return view

    def start(self, timeout=1.0):
        if self._started:
            raise RuntimeError("Worker 不可重复 start；restart 必须创建新实例")
        self._started = True
        self._thread = threading.Thread(target=self._run, name="udp-wait-worker", daemon=False)
        self._thread.start()
        if not self.ready.wait(timeout):
            with self._lock:
                self._external_errors.append("worker startup timeout")
            self.request_stop()
            if not self.join():
                with self._lock:
                    self._external_errors.append("worker startup watchdog failed")
            return False
        return not self.snapshot()["errors"] and not self.done.is_set()

    def request_stop(self):
        with self._lock:
            if self._stop_ns is None:
                self._stop_ns = time.monotonic_ns()
            self._stop.set()

    def join(self, timeout=1.0):
        if self._thread is not None:
            self._thread.join(timeout)
            return not self._thread.is_alive()
        return True

    def wait_for_wait(self, timeout=1.0, after=0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.done.is_set():
                return False
            if self.wait_entered.wait(min(0.010, max(0, deadline - time.monotonic()))):
                if self.snapshot()["wait_calls"] > after:
                    return True
            # 防止读取仍处于上一次等待时的 Event 造成忙等。
            self.done.wait(0.001)
        return False

    def _run(self):
        sockets = []
        stats = self._empty_stats()
        wall_start = time.monotonic_ns()
        cpu_start = time.thread_time_ns()
        stats["started_ns"] = wall_start
        try:
            for slot in stats["slots"]:
                if self._stop.is_set():
                    raise RuntimeError("初始化期间收到 stop")
                sock = self._factory(socket.AF_INET, socket.SOCK_DGRAM)
                sockets.append((slot, sock))
                stats["created"] += 1
                slot["created"] += 1
                sock.bind(("127.0.0.1", 0))
                sock.setblocking(False)
                stats["addresses"].append(sock.getsockname())
            self._publish(stats)
            self.ready.set()
            cursor = 0
            all_sockets = [sock for _, sock in sockets]
            while not self._stop.is_set():
                requested = SELECT_TIMEOUT if self.mode == "select" else SLEEP_TIMEOUT
                stats["wait_calls"] += 1
                stats["wait_requested_ns"] += int(requested * 1_000_000_000)
                self._publish(stats)
                before = time.monotonic_ns()
                self.wait_entered.set()
                try:
                    if self.mode == "select":
                        readable, _, _ = select.select(all_sockets, [], [], requested)
                    else:
                        time.sleep(requested)
                        readable = []
                finally:
                    actual = time.monotonic_ns() - before
                    self.wait_entered.clear()
                    stats["wait_actual_ns"] += actual
                    stats["wait_max_ns"] = max(stats["wait_max_ns"], actual)
                if self.mode == "select":
                    stats["wakeups" if readable else "timeouts"] += 1
                else:
                    stats["timeouts"] += 1
                if self._stop.is_set():
                    break
                stats["iterations"] += 1
                stats["rotation_counts"][cursor] += 1
                deadline = time.monotonic_ns() + PUMP_BUDGET_NS
                budget_hit = False
                # 所有槽均参与轮转，绝不只等待/服务第一个 socket。
                for offset in range(len(sockets)):
                    slot, sock = sockets[(cursor + offset) % len(sockets)]
                    handled = 0
                    while handled < PER_DIRECTION_LIMIT and not self._stop.is_set():
                        if time.monotonic_ns() >= deadline:
                            budget_hit = True
                            break
                        try:
                            data, peer = sock.recvfrom(512)
                        except BlockingIOError:
                            break
                        except OSError:
                            slot["receive_errors"] += 1
                            raise
                        slot["received"] += 1
                        handled += 1
                        try:
                            if sock.sendto(data, peer) != len(data):
                                raise OSError("UDP partial send")
                            slot["echoed"] += 1
                        except BlockingIOError:
                            slot["send_errors"] += 1
                        except OSError:
                            slot["send_errors"] += 1
                            raise
                    if handled == PER_DIRECTION_LIMIT:
                        stats["direction_limit_hits"] += 1
                    if budget_hit:
                        break
                if budget_hit:
                    stats["budget_hits"] += 1
                cursor = (cursor + 1) % len(sockets)
                self._publish(stats)
        except BaseException as exc:
            stats["errors"].append(type(exc).__name__ + ": " + str(exc))
        finally:
            self.wait_entered.clear()
            for slot, sock in sockets:
                try:
                    sock.close()
                    slot["closed"] += 1
                    stats["closed"] += 1
                except BaseException as exc:
                    stats["errors"].append("close: " + repr(exc))
            stats["cpu_ns"] = time.thread_time_ns() - cpu_start
            stats["wall_ns"] = time.monotonic_ns() - wall_start
            stats["cpu_wall_percent"] = 100 * stats["cpu_ns"] / max(1, stats["wall_ns"])
            # 完成标记位于全部 close 之后；线程退出仍必须由 join 另行确认。
            stats["finally_done_ns"] = time.monotonic_ns()
            self._publish(stats)
            self.ready.set()
            self.done.set()


class Fixture:
    """单独、非 daemon 的本机发包/校验线程；不访问 worker socket。"""

    def __init__(self, addresses, scenario, duration=DURATION, seed=SEED,
                 sample_limit=SAMPLE_LIMIT, socket_factory=socket.socket):
        if scenario not in SCENARIOS or duration < 0.300 or sample_limit < 1:
            raise ValueError("非法 fixture 参数；场景必须至少 300ms")
        self.addresses = [tuple(addr) for addr in addresses]
        if (len(self.addresses) not in (2, 4, 6)
                or any(len(addr) != 2 or addr[0] != "127.0.0.1"
                       or type(addr[1]) is not int or not 0 < addr[1] < 65536
                       for addr in self.addresses)):
            raise ValueError("fixture 仅接受 2/4/6 个本机回环 UDP 地址")
        self.scenario = scenario
        self.duration = duration
        self.seed = seed
        self.sample_limit = sample_limit
        self._factory = socket_factory
        self.ready = threading.Event()
        self.done = threading.Event()
        self.complete = threading.Event()
        self.scheduled_done = threading.Event()
        self.receipts_paused = threading.Event()
        self._pause_receipts = threading.Event()
        self._progress = threading.Event()
        self._after_stop_ns = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._thread = None
        self._view = {}
        self._external_errors = []

    def start(self, timeout=1.0):
        if self._thread is not None:
            raise RuntimeError("Fixture 不可重复 start")
        self._thread = threading.Thread(target=self._run, name="udp-wait-fixture", daemon=False)
        self._thread.start()
        if not self.ready.wait(timeout):
            with self._lock:
                self._external_errors.append("fixture startup timeout")
            self.request_stop()
            if not self.join():
                with self._lock:
                    self._external_errors.append("fixture startup watchdog failed")
            return False
        return not self.snapshot().get("errors") and not self.done.is_set()

    def pause_receipts(self, timeout=1.0):
        self._pause_receipts.set()
        return self.receipts_paused.wait(timeout) and not self.done.is_set()

    def confirm_worker_stop(self, confirmed_ns, timeout=0.250):
        # 仅传递时间标记，不传递/关闭任何 worker socket。
        with self._lock:
            self._after_stop_ns = confirmed_ns
        return self._progress.wait(timeout) and not self.done.is_set()

    def request_stop(self):
        self._stop.set()

    def join(self, timeout=1.0):
        if self._thread is None:
            return True
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def snapshot(self):
        with self._lock:
            result = json.loads(json.dumps(self._view))
            result.setdefault("errors", []).extend(self._external_errors)
        result["alive"] = self._thread is not None and self._thread.is_alive()
        return result

    def _run(self):
        sockets = []
        rows = []
        ledgers = []
        stats = {"created": 0, "closed": 0, "errors": [], "slots": [],
                 "source_started_ns": None, "source_stopped_ns": None,
                 "receipts_cutoff_ns": None, "post_confirmation_sent": 0,
                 "sending": False, "scheduled_complete": False}
        stop_at = None
        try:
            for i, address in enumerate(self.addresses):
                row = {"slot": i, "created": 0, "closed": 0, "attempted": 0,
                       "sent": 0, "echoed": 0, "duplicates": 0, "invalid": 0,
                       "send_errors": 0, "receive_errors": 0, "missing": 0,
                       "sample_overflow": 0, "tracking_overflow": 0,
                       "max_service_gap_ns": 0, "send_call_max_ns": 0,
                       "receive_call_max_ns": 0, "slowest_samples": [],
                       "rtt": percentiles([])}
                rows.append(row)
                ledger = {"pending": {}, "timings": {}, "seen": set(), "samples": [],
                          "sent_times": [], "acks": [], "last_ack": None}
                ledgers.append(ledger)
                sock = self._factory(socket.AF_INET, socket.SOCK_DGRAM)
                sockets.append(sock)
                row["created"] += 1
                stats["created"] += 1
                sock.bind(("127.0.0.1", 0))
                sock.setblocking(False)
                # 不改变操作系统 UDP 选项，也不吞掉实际接收错误。
                # stop_load 用显式回执截止分离完整性采样和关闭后的持续发送。
            start = time.monotonic()
            stats["source_started_ns"] = time.monotonic_ns()
            stats["sending"] = self.scenario != "idle"
            next_wave = start
            wave = 0
            total_waves = max(1, int(round(self.duration / 0.010)))
            self.ready.set()
            while True:
                now = time.monotonic()
                if self._pause_receipts.is_set() and not self.receipts_paused.is_set():
                    if "receipts_checkpoint_ns" not in stats:
                        stats["receipts_checkpoint_ns"] = time.monotonic_ns()
                        for row, ledger in zip(rows, ledgers):
                            row["checkpoint_sent"] = row["sent"]
                            ledger["checkpoint_pending"] = set(ledger["pending"])
                    if all(not ledger["checkpoint_pending"] for ledger in ledgers):
                        # 检查点前每包已确认；新发包仍继续，不要求整个队列瞬间全空。
                        stats["receipts_cutoff_ns"] = time.monotonic_ns()
                        for row in rows:
                            row["checkpoint_acked"] = row["checkpoint_sent"]
                            row["sent_at_receipts_cutoff"] = row["sent"]
                            row["echoed_at_receipts_cutoff"] = row["echoed"]
                        self._publish(stats, rows, ledgers)
                        self.receipts_paused.set()
                if self._stop.is_set() and stop_at is None:
                    stats["source_stopped_ns"] = time.monotonic_ns()
                    stats["sending"] = False
                    stop_at = now + 0.050
                if stop_at is not None and now >= stop_at:
                    break
                if now - start > self.duration + 2.0:
                    raise TimeoutError("fixture 自有寿命看门狗到期，非正常停止")
                if stop_at is None and now >= next_wave:
                    active = []
                    if self.scenario == "last_only" and wave == 0:
                        active = [(len(sockets) - 1, 12)]
                    elif self.scenario in ("mixed", "stop_load"):
                        active = [(0, (32 + ((self.seed + wave * 17) % 33))
                                   if self.scenario == "mixed" else 8)]
                        # stop_load 首槽每 5ms 一波；其余槽仍每 10ms 一包。
                        if self.scenario == "mixed" or wave % 2 == 0:
                            active.extend((i, 1) for i in range(1, len(sockets)))
                    for i, count in active:
                        row, ledger, sock = rows[i], ledgers[i], sockets[i]
                        for _ in range(count):
                            if row["sent"] >= SAMPLE_LIMIT:
                                row["tracking_overflow"] += 1
                                continue
                            seq = row["attempted"]
                            row["attempted"] += 1
                            sent_ns = time.monotonic_ns()
                            payload = json.dumps([i, seq, sent_ns], separators=(",", ":")).encode("ascii")
                            send_call_ns = time.monotonic_ns()
                            try:
                                if sock.sendto(payload, self.addresses[i]) != len(payload):
                                    raise OSError("fixture UDP partial send")
                            except BlockingIOError:
                                row["send_errors"] += 1
                                continue
                            except OSError:
                                row["send_errors"] += 1
                                raise
                            finally:
                                send_return_ns = time.monotonic_ns()
                                row["send_call_max_ns"] = max(
                                    row["send_call_max_ns"], send_return_ns - send_call_ns)
                            ledger["pending"][seq] = (sent_ns, payload)
                            ledger["timings"][seq] = (send_call_ns, send_return_ns)
                            ledger["sent_times"].append(sent_ns)
                            row["sent"] += 1
                            with self._lock:
                                confirmed_ns = self._after_stop_ns
                            if confirmed_ns is not None and sent_ns > confirmed_ns:
                                stats["post_confirmation_sent"] += 1
                                self._progress.set()
                    wave += 1
                    if self.scenario == "stop_load":
                        next_wave = start + wave * 0.005
                    elif self.scenario == "mixed" and wave < total_waves:
                        next_wave = start + wave * 0.010
                    else:
                        next_wave = float("inf")
                        stats["scheduled_complete"] = True
                        stats["sending"] = False
                        self.scheduled_done.set()
                # fixture 独立节拍：每轮至少实际 sleep 1ms，再做一次零超时
                # 就绪查询；并非无等待轮询。worker 的等待路径完全不变。
                # 避免把 fixture 自己空闲 select 的调度粒度混入 10ms 发包节拍。
                delay = 0.002
                if stop_at is None:
                    delay = min(delay, max(0.0, next_wave - time.monotonic()))
                time.sleep(max(0.001, delay))
                if self.receipts_paused.is_set():
                    # 截止后不再调用 recvfrom；这部分一律未确认，绝非零丢包。
                    readable = []
                else:
                    readable, _, _ = select.select(sockets, [], [], 0)
                for i, sock in enumerate(sockets):
                    if sock not in readable:
                        continue
                    row, ledger = rows[i], ledgers[i]
                    for _ in range(PER_DIRECTION_LIMIT):
                        receive_call_ns = time.monotonic_ns()
                        try:
                            payload, peer = sock.recvfrom(512)
                        except BlockingIOError:
                            break
                        except OSError:
                            row["receive_errors"] += 1
                            raise
                        finally:
                            receive_return_ns = time.monotonic_ns()
                            row["receive_call_max_ns"] = max(
                                row["receive_call_max_ns"], receive_return_ns - receive_call_ns)
                        received_ns = receive_return_ns
                        try:
                            packet = json.loads(payload)
                            if (not isinstance(packet, list) or len(packet) != 3
                                    or type(packet[0]) is not int or packet[0] != i
                                    or type(packet[1]) is not int
                                    or type(packet[2]) is not int
                                    or peer != self.addresses[i]):
                                raise ValueError("非原路原槽回执")
                            seq = packet[1]
                            if seq in ledger["seen"]:
                                row["duplicates"] += 1
                                continue
                            expected = ledger["pending"].get(seq)
                            if expected is None or expected != (packet[2], payload):
                                raise ValueError("未知 seq 或消息被改写")
                        except (ValueError, TypeError, UnicodeError):
                            row["invalid"] += 1
                            continue
                        del ledger["pending"][seq]
                        send_call_ns, send_return_ns = ledger["timings"].pop(seq)
                        timing = {"seq": seq, "rtt_ns": received_ns - packet[2],
                                  "pre_send_ns": send_call_ns - packet[2],
                                  "send_call_ns": send_return_ns - send_call_ns,
                                  "after_send_return_ns": received_ns - send_return_ns,
                                  "receive_call_ns": receive_return_ns - receive_call_ns}
                        row["slowest_samples"] = sorted(
                            row["slowest_samples"] + [timing],
                            key=lambda sample: sample["rtt_ns"], reverse=True)[:8]
                        if "checkpoint_pending" in ledger:
                            ledger["checkpoint_pending"].discard(seq)
                        ledger["seen"].add(seq)
                        ledger["acks"].append((packet[2], received_ns))
                        row["echoed"] += 1
                        if len(ledger["samples"]) < self.sample_limit:
                            ledger["samples"].append(received_ns - packet[2])
                        else:
                            row["sample_overflow"] += 1
                        if ledger["last_ack"] is not None:
                            row["max_service_gap_ns"] = max(
                                row["max_service_gap_ns"], received_ns - ledger["last_ack"])
                        ledger["last_ack"] = received_ns
                if stats["scheduled_complete"] and all(not x["pending"] for x in ledgers):
                    self.complete.set()
                self._publish(stats, rows, ledgers)
        except BaseException as exc:
            stats["errors"].append(type(exc).__name__ + ": " + str(exc))
        finally:
            if stats["source_stopped_ns"] is None:
                stats["source_stopped_ns"] = time.monotonic_ns()
            stats["sending"] = False
            for i, sock in enumerate(sockets):
                try:
                    sock.close()
                    rows[i]["closed"] += 1
                    stats["closed"] += 1
                except BaseException as exc:
                    stats["errors"].append("fixture close: " + repr(exc))
            self._publish(stats, rows, ledgers, final=True)
            self.ready.set()
            self.done.set()

    def _publish(self, stats, rows, ledgers, final=False):
        result = dict(stats)
        result["errors"] = list(stats["errors"])
        result["slots"] = []
        for row, ledger in zip(rows, ledgers):
            copy = dict(row)
            copy["missing"] = len(ledger["pending"])
            if final:
                copy["rtt"] = percentiles(ledger["samples"])
                if "checkpoint_pending" in ledger:
                    copy["checkpoint_unconfirmed"] = len(ledger["checkpoint_pending"])
                    copy["checkpoint_acked"] = row["checkpoint_sent"] - copy["checkpoint_unconfirmed"]
                # 有界证据账本，用于区分停机前未确认、停机后发送与已确认包。
                copy["sent_times_ns"] = list(ledger["sent_times"])
                copy["ack_times_ns"] = list(ledger["acks"])
                copy["rtt_samples_ns"] = list(ledger["samples"])
            result["slots"].append(copy)
        with self._lock:
            self._view = result


def evaluate_case(result):
    """只评架构、生命周期及完整性；无 RTT/CPU 性能阈值。"""
    failures = list(result["errors"])
    worker, fixture = result["worker"], result["fixture"]
    expected = result["sessions"] * 2
    for name, state in (("worker", worker), ("fixture", fixture)):
        failures.extend(name + ": " + error for error in state.get("errors", []))
        if state.get("alive", True):
            failures.append(name + " thread alive")
        if state.get("created") != expected or state.get("closed") != expected:
            failures.append(name + " socket lifecycle mismatch")
        if len(state.get("slots", [])) != expected:
            failures.append(name + " slot count mismatch")
        for row in state.get("slots", []):
            if row["created"] != 1 or row["closed"] != 1:
                failures.append(name + " per-slot lifecycle mismatch")
            if row["send_errors"] or row["receive_errors"]:
                failures.append(name + " socket IO error")
    if worker.get("stop_to_finally_ns") is None or worker.get("stop_to_finally_ns", -1) < 0:
        failures.append("未证实正常的外部 stop 到 finally")
    if not result.get("wait_boundary_observed"):
        failures.append("未观察到有限等待边界")
    if result["scenario"] == "idle" and not result.get("idle_stop_wait_boundary"):
        failures.append("idle stop 未观察到等待边界")
    if worker.get("wait_calls", 0) != worker.get("timeouts", 0) + worker.get("wakeups", 0):
        failures.append("等待次数与完成次数不一致")
    rotations = worker.get("rotation_counts", [])
    if (len(rotations) != expected or not rotations or min(rotations) < 1
            or max(rotations) - min(rotations) > 1
            or sum(rotations) != worker.get("iterations")):
        failures.append("轮转起点或 pump 次数异常")
    addresses = worker.get("addresses", [])
    if len(addresses) != expected or any(addr[0] != "127.0.0.1" or not addr[1] for addr in addresses):
        failures.append("worker 回环绑定地址异常")
    if result.get("traffic_wall_ns", 0) < 300_000_000:
        failures.append("场景运行不足 300ms")
    for row in fixture.get("slots", []):
        i = row["slot"]
        if row["duplicates"] or row["invalid"] or row["tracking_overflow"]:
            failures.append("fixture slot %d 回执完整性失败" % i)
        if i < len(worker.get("slots", [])):
            wr = worker["slots"][i]
            if wr["received"] != wr["echoed"]:
                failures.append("slot %d worker 收发收支不一致" % i)
            if result["scenario"] == "stop_load":
                if not row["echoed"] <= wr["echoed"] <= row["sent"]:
                    failures.append("slot %d 停机收支不一致" % i)
            elif wr["echoed"] != row["echoed"]:
                failures.append("slot %d worker/fixture 收支不一致" % i)
        if row["missing"] != row["sent"] - row["echoed"]:
            failures.append("slot %d missing 账本不一致" % i)
        if result["scenario"] != "stop_load" and row["missing"]:
            failures.append("slot %d 缺失回执" % i)
        if result["scenario"] == "idle":
            if row["sent"] or row["echoed"]:
                failures.append("idle 不允许 UDP 控制包或数据包")
        elif result["scenario"] == "last_only":
            if (i == expected - 1 and (row["sent"] != 12 or row["echoed"] != 12)) or (
                    i != expected - 1 and row["sent"]):
                failures.append("last_only 流量分布错误")
        elif result["scenario"] == "mixed":
            planned_waves = result["fixture_waves"]
            target = (sum(32 + ((result["seed"] + k * 17) % 33)
                          for k in range(planned_waves)) if i == 0 else planned_waves)
            if row["sent"] != target or row["echoed"] != target:
                failures.append("mixed slot %d 未完整收齐固定强度流量" % i)
        elif result["scenario"] == "stop_load":
            checkpoint = row.get("checkpoint_sent", 0)
            if (checkpoint == 0 or checkpoint != row.get("checkpoint_acked")
                    or checkpoint > row["echoed"]
                    or row.get("echoed_at_receipts_cutoff") != row["echoed"]):
                failures.append("stop_load slot %d 检查点前未完整收齐" % i)
            if row.get("acked_before_stop", 0) == 0:
                failures.append("stop_load slot %d 停机前无已确认回执" % i)
            if row.get("unconfirmed_at_stop") != row.get("sent_before_stop", 0) - row.get("acked_before_stop", 0):
                failures.append("stop_load slot %d 未确认账本不一致" % i)
    if result["scenario"] == "stop_load":
        if not result.get("source_active_at_stop_confirmation"):
            failures.append("stop 确认时连续源未运行")
        if fixture.get("post_confirmation_sent", 0) == 0:
            failures.append("未证实 stop 确认后仍有实际发送")
        cutoff = fixture.get("receipts_cutoff_ns")
        stopped = fixture.get("source_stopped_ns")
        confirmed = result.get("stop_confirmation_ns")
        if cutoff is None or cutoff > (worker.get("stop_requested_ns") or 0):
            failures.append("未证实回执截止早于外部 stop")
        if stopped is None or confirmed is None or stopped < confirmed:
            failures.append("发送源在 worker stop 确认之前停止")
    return failures


def run_case(sessions, mode, scenario, seed=SEED, duration=DURATION,
             worker_factory=Worker, fixture_factory=Fixture):
    if scenario not in SCENARIOS or duration < 0.300:
        raise ValueError("非法场景或场景时长")
    result = {"sessions": sessions, "mode": mode, "scenario": scenario,
              "seed": seed, "errors": [], "wait_boundary_observed": False,
              "source_active_at_stop_confirmation": False,
              "fixture_waves": int(round(duration / 0.010)),
              "traffic_wall_ns": 0}
    worker = worker_factory(sessions, mode)
    fixture = None
    try:
        if not worker.start():
            raise RuntimeError("worker 启动失败")
        result["wait_boundary_observed"] = worker.wait_for_wait()
        if not result["wait_boundary_observed"]:
            raise RuntimeError("worker 未进入等待边界")
        fixture = fixture_factory(worker.snapshot()["addresses"], scenario,
                                  duration=duration, seed=seed)
        if not fixture.start():
            raise RuntimeError("fixture 启动失败")
        start_ns = time.monotonic_ns()
        # 不让主线程发包/接包；即使 fixture 提前异常也保留失败证据。
        worker.done.wait(duration)
        result["traffic_wall_ns"] = time.monotonic_ns() - start_ns
        if scenario != "stop_load" and not fixture.complete.wait(1.0):
            raise RuntimeError("fixture 完整回执等待超时")
        if scenario == "idle":
            count = worker.snapshot()["wait_calls"]
            result["idle_stop_wait_boundary"] = worker.wait_for_wait(after=count)
            if not result["idle_stop_wait_boundary"]:
                raise RuntimeError("idle stop 未观察到下一次真实等待调用边界")
        if scenario == "stop_load" and not fixture.pause_receipts():
            raise RuntimeError("fixture 回执截止前完整性握手超时")
        worker.request_stop()
        if not worker.join(1.0):
            result["errors"].append("worker join(1s) watchdog failed")
        if scenario == "stop_load":
            result["stop_confirmation_ns"] = time.monotonic_ns()
            source = fixture.snapshot()
            result["source_active_at_stop_confirmation"] = (
                source.get("sending", False) and source["alive"] and worker.done.is_set())
            if not fixture.confirm_worker_stop(result["stop_confirmation_ns"]):
                result["errors"].append("stop 确认后持续源未产生新发送")
    except Exception as exc:
        result["errors"].append(type(exc).__name__ + ": " + str(exc))
    finally:
        # 取消/启动失败时先停发送源并排尽回执，再关闭接收端，避免主动制造 ICMP 端口错误。
        # 正常 stop_load 已在上方确认 worker 停止且源仍发送，此处不改变该验收顺序。
        # 用户取消/SystemExit 在全部自有线程清理后继续传播，由 main 保存证据并停矩阵。
        if fixture is not None:
            fixture.request_stop()
            if not fixture.join(1.0):
                result["errors"].append("fixture join(1s) watchdog failed")
        worker.request_stop()
        if not worker.join(1.0):
            result["errors"].append("worker cleanup watchdog failed")
        result["worker"] = worker.snapshot()
        result["fixture"] = fixture.snapshot() if fixture else {
            "created": 0, "closed": 0, "slots": [], "errors": ["fixture 未启动"], "alive": False}
    stop_ns = result["worker"]["stop_requested_ns"]
    all_samples = []
    for row in result["fixture"].get("slots", []):
        sent_times = row.pop("sent_times_ns", [])
        ack_times = row.pop("ack_times_ns", [])
        all_samples.extend(row.pop("rtt_samples_ns", []))
        row["acked_before_stop"] = sum(ack <= stop_ns for _, ack in ack_times)
        row["sent_before_stop"] = sum(sent <= stop_ns for sent in sent_times)
        row["unconfirmed_at_stop"] = row["sent_before_stop"] - row["acked_before_stop"]
        row["sent_after_stop"] = row["sent"] - row["sent_before_stop"]
        if scenario == "stop_load":
            row["unconfirmed_after_checkpoint"] = row["missing"]
            slots = result["worker"]["slots"]
            if row["slot"] < len(slots):
                row["worker_echoed_not_observed"] = slots[row["slot"]]["echoed"] - row["echoed"]
    result["rtt"] = percentiles(all_samples)
    rows = result["fixture"].get("slots", [])
    for key in ("sent", "echoed", "missing", "duplicates", "sample_overflow", "tracking_overflow"):
        result[key] = sum(row[key] for row in rows)
    result["max_service_gap_ns"] = max((r["max_service_gap_ns"] for r in rows), default=0)
    result["lossless_asserted"] = scenario != "stop_load"
    result["failures"] = evaluate_case(result)
    result["passed"] = not result["failures"]
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="仅本机 UDP 有限等待实验；不代表端到端性能")
    parser.add_argument("--label", required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--sessions", type=int, nargs="+", default=[1, 2, 3])
    parser.add_argument("--modes", nargs="+", choices=MODES, default=["sleep", "select"])
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", args.label, flags=re.ASCII):
        parser.error("label 必须为 1~64 位 ASCII 标识：字母/数字开头，仅字母数字下划线连字符")
    if not 1 <= args.rounds <= 100:
        parser.error("rounds 必须为 1~100")
    if any(s not in (1, 2, 3) for s in args.sessions) or len(set(args.sessions)) != len(args.sessions):
        parser.error("sessions 必须为不重复的 1、2、3")
    if len(set(args.modes)) != len(args.modes):
        parser.error("modes 不可重复")
    return args


def case_plan(rounds, sessions, modes):
    for round_index in range(rounds):
        for topology_index, count in enumerate(sessions):
            for scenario_index, scenario in enumerate(SCENARIOS):
                # 相邻场景/拓扑及下一轮均交换 AB/BA；仅强度/seed 相同，非同相位。
                order = list(modes)
                if (round_index + topology_index + scenario_index) % 2:
                    order.reverse()
                for mode in order:
                    yield round_index + 1, count, mode, scenario


def main(argv=None):
    args = parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    tools = root / "tools"
    output_dir = root / ".workbuddy" / "tmp"
    if not tools.is_dir() or not output_dir.is_dir():
        print("要求 tools 与 .workbuddy/tmp 父目录已存在", file=sys.stderr)
        return 2
    path = output_dir / ("network_udp_wait_" + args.label + ".json")
    report = {"label": args.label, "rounds": args.rounds, "sessions": args.sessions,
              "modes": args.modes, "seed": SEED, "platform": sys.platform,
              "python": sys.version, "cases": [], "errors": [], "passed": False,
              "scope": "仅 Python worker 的 thread_time_ns；排除发送方；非 Godot/手机/端到端性能",
              "pass_definition": "架构、正常停止、资源生命周期、回执完整性门禁；无延迟 SLA",
              "service_gap_definition": "同槽连续两个有效回执的 fixture 接收时间间隔最大值；不含头尾空闲；少于两包为 0",
              "stop_load_definition": "先完整确认固定发送检查点；发送始终继续。为避免关闭端口后的 Windows ICMP 干扰，在请求 stop 前显式截止 recvfrom 采样；截止后未确认包全部计 missing/unconfirmed，不计作完整性成功。worker finally、join 确认后还必须有真实新发送，才停止源。不宣称停机阶段零丢包",
              "fixture_definition": "mixed 每 10ms 固定波数，首槽每波 32~64 包、其余每槽独立 seq 一包；stop_load 首槽每 5ms 一波八包、其余每 10ms 一包；调度受 OS 影响不保证硬实时。所有 socket 只 bind 127.0.0.1:0",
              "wait_totals_definition": "wait_requested_ns/actual_ns 为 worker 等待累计时长，wait_max_ns 为单次实际等待最大时长；不含 pump。iterations 为 pump 次数，预算是协作检查并非系统调用硬截止",
              "wait_definition": "wait_entered 通知紧邻真实 select/sleep 调用前；非内核进入证明；sleep 到期记 timeout",
              "timing_definition": "每槽保留最慢八个完整回执；rtt=pre_send+send_call+after_send_return。send/receive_call 是调用包围区间的本地耗时，包含线程被调度出去的时间，不等于纯内核执行；after_send_return 仍含夹具调度、worker与回环等待，不能直接当网络单程",
              "cpu_definition": "仅 worker 的 thread_time_ns/wall_ns，短场景受CPU计时量化影响；读数0不证明零CPU；未测发送夹具/整进程/游戏或手机功耗",
              "limits": {"select_timeout_ns": 5_000_000, "sleep_timeout_ns": 1_000_000,
                         "pump_budget_ns": PUMP_BUDGET_NS, "per_direction_packets": 64,
                         "sample_limit_per_slot": SAMPLE_LIMIT, "tracking_limit_per_slot": SAMPLE_LIMIT,
                         "join_watchdog_seconds": 1, "scene_seconds": DURATION},
              "caveats": ["有限 select timeout 不是调度/停止延时 5ms 硬上界",
                          "AB/BA 相同 seed 和固定强度，不保证完全同相位",
                          "单机 Windows/Python 结果不可外推 Godot、移动端或公网",
                          "RTT 包含 fixture 调度/发送/接收；诊断统计不是用户 SLA"]}
    try:
        stream = path.open("x", encoding="utf-8")
    except FileExistsError:
        print("拒绝覆盖已有结果：" + str(path), file=sys.stderr)
        return 2

    def save():
        stream.seek(0)
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.truncate()
        stream.flush()

    with stream:
        save()
        try:
            for round_no, sessions, mode, scenario in case_plan(args.rounds, args.sessions, args.modes):
                # 先落盘当前案例，意外中断不能被误认为尚未运行或正常通过。
                case = {"round": round_no, "sessions": sessions, "mode": mode,
                        "scenario": scenario, "seed": SEED, "passed": False,
                        "status": "running_or_interrupted", "errors": []}
                report["cases"].append(case)
                save()
                try:
                    evidence = run_case(sessions, mode, scenario)
                except BaseException as exc:
                    case["errors"].append(type(exc).__name__ + ": " + str(exc))
                    raise
                case.update(evidence)
                case["status"] = "finished"
                save()
            report["passed"] = bool(report["cases"]) and all(c["passed"] for c in report["cases"])
        except BaseException as exc:
            report["errors"].append(type(exc).__name__ + ": " + str(exc))
        finally:
            save()
    passed = sum(case["passed"] for case in report["cases"])
    print("%s：%d/%d case 通过；仅生命周期/完整性门禁；%s" % (
        args.label, passed, len(report["cases"]), path))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
