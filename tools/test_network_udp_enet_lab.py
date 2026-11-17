"""Offline tests for strict parsing/lifecycle gating in the local UDP runner."""
import importlib.util
import io
import queue
import time
import types
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('udp_enet_lab', Path(__file__).with_name('network_udp_enet_lab.py'))
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class FakeChild:
    def __init__(self, lines):
        self.lines = lines


def offline_child(lines, prefix='READY ', exit_code=0):
    """用内存 stdout 驱动真实 read()，不启动进程。"""
    child = lab.Child.__new__(lab.Child)
    child.lines = []
    child.on_line = None
    child.messages = queue.Queue()
    child.private_messages = queue.Queue()
    child.notifications = queue.Queue()
    child.failure = None
    child.ready_seen = False
    child.prefix = prefix
    child.proc = types.SimpleNamespace(stdout=io.StringIO(''.join(lines)), poll=lambda: exit_code)
    child.read()
    return child


class UdpLabParseTest(unittest.TestCase):
    def test_exact_marker(self):
        self.assertEqual(lab.parse_result(FakeChild(['noise', 'RESULT {"ok":true}']), 'RESULT '), {'ok': True})

    def test_missing_marker_cannot_pass(self):
        with self.assertRaises(RuntimeError):
            lab.parse_result(FakeChild(['process exited without report']), 'RESULT ')

    def test_duplicate_marker_cannot_pass(self):
        with self.assertRaises(RuntimeError):
            lab.parse_result(FakeChild(['RESULT {}', 'RESULT {}']), 'RESULT ')

    def test_corrupt_json_cannot_pass(self):
        with self.assertRaises(ValueError):
            lab.parse_result(FakeChild(['RESULT {bad}']), 'RESULT ')

    def test_private_credentials_and_replay_never_enter_logs(self):
        child = offline_child([
            'UDP_LAB_PRIVATE_CONFIG {"key_hex":"private-key"}\n',
            'UDP_LAB_PRIVATE_REPLAY {"packets":["private-frame"]}\n',
            'READY {"ok":true}\n'])
        self.assertEqual(child.lines, ['READY {"ok":true}'])
        self.assertEqual(child.private_messages.get_nowait(), {'key_hex': 'private-key'})
        self.assertEqual(child.private_messages.get_nowait(), {'packets': ['private-frame']})
        self.assertEqual(child.notifications.get_nowait(), 'READY {"ok":true}')
        # 就绪后 EOF 只发一条观测哨兵，不再塞失败。
        self.assertTrue(child.notifications.get_nowait().startswith(lab.FAILURE_SENTINEL))
        self.assertTrue(child.notifications.empty())
        self.assertIsNone(child.failure)

    def test_startup_error_wakes_ready_immediately(self):
        child = offline_child(['UDP_HOST_ERROR {"error":"invalid_config"}\n'], prefix='UDP_HOST_READY ', exit_code=1)
        started = time.monotonic()
        with self.assertRaises(RuntimeError) as raised:
            child.ready(10)
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertIn('invalid_config', str(raised.exception))

    def test_eof_before_ready_fails_fast(self):
        child = offline_child([], prefix='UDP_HOST_READY ', exit_code=2)
        started = time.monotonic()
        with self.assertRaises(RuntimeError) as raised:
            child.ready(10)
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertIn('stdout closed before', str(raised.exception))
        self.assertIn('exit=2', str(raised.exception))

    def test_final_without_ready_is_a_startup_failure(self):
        child = offline_child(['UDP_HOST_FINAL {"state":"closed"}\n'], prefix='UDP_HOST_READY ')
        with self.assertRaises(RuntimeError):
            child.ready(1)
        self.assertIn('UDP_HOST_FINAL', child.failure)

    def test_wait_marker_raises_on_child_failure(self):
        child = offline_child(['UDP_HOST_ERROR {"error":"worker_start_failed"}\n'], prefix='UDP_HOST_READY ')
        with self.assertRaises(RuntimeError) as raised:
            child.wait_marker('UDP_HOST_STATS ', timeout=5)
        self.assertIn('worker_start_failed', str(raised.exception))


def adapter_stats(clients=2, **overrides):
    totals = {name: 0 for name in lab.ZERO_ADAPTER_COUNTERS}
    totals.update(accepted_packets=clients * 10, forwarded_packets=clients * 10,
                  sealed_packets=clients * 8, returned_packets=clients * 8)
    sessions = []
    for _ in range(clients):
        session = {name: 0 for name in lab.ZERO_ADAPTER_COUNTERS}
        session.update(accepted_packets=10, forwarded_packets=10, sealed_packets=8, returned_packets=8)
        sessions.append(session)
    stats = {'state': 'closed', 'sessions': sessions, 'totals': totals,
             'created_sockets': clients * 2, 'closed_sockets': clients * 2, 'startup_error': 0}
    stats.update(overrides)
    return stats


class UdpAdapterGateTest(unittest.TestCase):
    def test_clean_stats_pass(self):
        self.assertEqual(lab.check_godot_adapter(adapter_stats(), 2), [])

    def test_pending_socket_leak_blocks(self):
        failures = lab.check_godot_adapter(adapter_stats(closed_sockets=2), 2)
        self.assertTrue(any('closed_sockets' in item for item in failures))

    def test_oversize_and_seal_rejects_block(self):
        stats = adapter_stats()
        stats['totals']['raw_oversize'] = 1
        stats['sessions'][1]['seal_rejected'] = 1
        failures = lab.check_godot_adapter(stats, 2)
        self.assertTrue(any('raw_oversize' in item for item in failures))
        self.assertTrue(any('session1.seal_rejected' in item for item in failures))

    def test_silent_session_cannot_pass(self):
        stats = adapter_stats()
        for name in ('accepted_packets', 'forwarded_packets', 'sealed_packets', 'returned_packets'):
            stats['sessions'][0][name] = 0
        failures = lab.check_godot_adapter(stats, 2)
        self.assertTrue(any('session0.forwarded_packets' in item for item in failures))

    def test_send_drop_blocks(self):
        stats = adapter_stats()
        stats['sessions'][0]['send_drops'] = 3
        failures = lab.check_godot_adapter(stats, 2)
        self.assertTrue(any('send_drops' in item for item in failures))


if __name__ == '__main__':
    unittest.main()
