"""本地 UDP 实验工具的离线解析、生命周期、账本及观察统计测试。"""
import copy
import importlib.util
import io
import json
import queue
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location('udp_enet_lab', Path(__file__).with_name('network_udp_enet_lab.py'))
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class FakeChild:
    def __init__(self, lines):
        self.lines = lines


def offline_child(lines, prefix='READY ', exit_code=0, callback=None, read=True):
    """用内存 stdout 驱动真实 read()，不启动进程。"""
    child = lab.Child.__new__(lab.Child)
    child.lines = []
    child.on_line = callback
    child.messages = queue.Queue()
    child.private_messages = queue.Queue()
    child.notifications = queue.Queue()
    child.failure = None
    child.failures = []
    child.closed_reason = None
    child._condition = threading.Condition()
    child.ready_seen = False
    child.prefix = prefix
    child.proc = types.SimpleNamespace(stdout=io.StringIO(''.join(lines)), poll=lambda: exit_code)
    if read:
        child.read()
    return child


def adapter_stats(clients=2, **overrides):
    sessions = []
    for _ in range(clients):
        session = {name: 0 for name in lab.ADAPTER_COUNTERS}
        session.update(transport_packets=10, raw_packets=8, accepted_packets=10,
                       forwarded_packets=10, sealed_packets=8, returned_packets=8)
        sessions.append(session)
    totals = {name: sum(s[name] for s in sessions) for name in lab.ADAPTER_COUNTERS}
    stats = {'state': 'closed', 'running': False, 'ready': False, 'sessions': sessions,
             'totals': totals, 'ports': [30000 + i for i in range(clients)],
             'backend_ports': [31000 + i for i in range(clients)],
             'created_sockets': clients * 2, 'closed_sockets': clients * 2,
             'startup_error': 0, 'exit_code': 0, 'control_io_errors': 0,
             'control_busy_errors': 0, 'control_rejected': 0,
             'iterations': 100, 'max_iteration_gap_usec': 1000, 'work_usec': 500,
             'last_pump_usec': 3, 'max_pump_usec': 10, 'max_payload': 1176,
             'max_datagram': 1232}
    stats.update(overrides)
    return stats


class UdpLabParseTest(unittest.TestCase):
    def test_edited_sources_use_only_lf(self):
        for name in ('network_udp_enet_lab.py', 'network_udp_reconnect_lab.py',
                     'network_udp_game_probe.gd', 'test_network_udp_enet_lab.py'):
            with self.subTest(name=name):
                self.assertNotIn(b'\r', Path(__file__).with_name(name).read_bytes())

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

    def test_private_credentials_never_enter_logs_or_callback(self):
        callback = mock.Mock()
        child = offline_child(['UDP_LAB_PRIVATE_CONFIG {"key_hex":"private-key"}\n',
                               'READY {"ok":true}\n'], callback=callback)
        self.assertEqual(child.lines, ['READY {"ok":true}'])
        callback.assert_called_once_with('READY {"ok":true}')
        self.assertEqual(child.ready(10), {'ok': True})
        self.assertIsNone(child.failure)
        with self.assertRaises(RuntimeError):
            child.wait_private()

    def test_live_private_message_uses_public_wait(self):
        child = offline_child([], read=False)
        child.private_messages.put({'key': 'secret'})
        self.assertEqual(child.wait_private(), {'key': 'secret'})

    def test_bad_private_json_is_redacted_and_reader_continues(self):
        for line in ('UDP_LAB_PRIVATE_CONFIG {"private-key":oops}\n',
                     'UDP_LAB_PRIVATE_CONFIG private-key\n',
                     'UDP_LAB_PRIVATE_CONFIG\n', 'UDP_LAB_PRIVATE_CONFIG ["private-key"]\n'):
            with self.subTest(line=line):
                child = offline_child([line, 'READY {"ok":true}\n', 'RESULT {"done":true}\n'])
                self.assertEqual(child.ready(10), {'ok': True})
                self.assertEqual(child.wait_marker('RESULT '), {'done': True})
                self.assertEqual(child.failure, 'invalid private JSON message')
                self.assertNotIn('private-key', repr(child.lines) + repr(child.failures))
                for _ in range(2):
                    with self.assertRaises(RuntimeError) as raised:
                        child.wait_private()
                    self.assertNotIn('private-key', str(raised.exception))
                    self.assertIsNone(raised.exception.__context__)

    def test_private_parser_exception_payload_is_never_reported(self):
        child = offline_child(['UDP_LAB_PRIVATE_CONFIG private-key\n', 'READY ok\n'], read=False)
        with mock.patch.object(lab.json, 'loads', side_effect=RuntimeError('private-key')):
            child.read()
        self.assertEqual(child.ready(10), 'ok')
        self.assertNotIn('private-key', repr(child.failures) + repr(child.lines))

    def test_startup_error_wakes_ready_immediately(self):
        child = offline_child(['UDP_HOST_ERROR {"error":"invalid_config"}\n'], prefix='UDP_HOST_READY ', exit_code=1)
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, 'UDP_HOST_ERROR'):
            child.ready(10)
        self.assertLess(time.monotonic() - started, 1.0)

    def test_eof_before_ready_fails_fast_repeatedly(self):
        child = offline_child([], prefix='UDP_HOST_READY ', exit_code=2)
        for _ in range(3):
            started = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, 'stdout closed before.*exit=2'):
                child.ready(10)
            self.assertLess(time.monotonic() - started, 1.0)

    def test_final_without_ready_is_a_startup_failure(self):
        child = offline_child(['UDP_HOST_FINAL {"state":"closed"}\n'], prefix='UDP_HOST_READY ')
        with self.assertRaisesRegex(RuntimeError, 'UDP_HOST_FINAL'):
            child.ready(1)

    def test_ready_then_eof_preserves_ready_but_all_new_waits_fail(self):
        child = offline_child(['READY {"ok":true}\n'])
        self.assertEqual(child.ready(10), {'ok': True})
        self.assertEqual(child.failures, [])
        started = time.monotonic()
        for _ in range(3):
            with self.assertRaises(RuntimeError):
                child.wait_private(10)
            with self.assertRaises(RuntimeError):
                child.wait_marker('RESULT ', 10)
        self.assertLess(time.monotonic() - started, 1.0)

    def test_ready_then_errors_fail_private_and_marker_without_eof(self):
        for marker in lab.EARLY_FAILURE_MARKERS:
            with self.subTest(marker=marker):
                child = offline_child(['READY ok\n', marker + '{}\n'])
                child.closed_reason = None if marker != 'UDP_HOST_FINAL ' else 'UDP_HOST_FINAL received'
                self.assertEqual(child.ready(10), 'ok')
                for _ in range(2):
                    with self.assertRaises(RuntimeError):
                        child.wait_private(10)
                    with self.assertRaises(RuntimeError):
                        child.wait_marker('RESULT ', 10)

    def test_queued_target_precedes_failure(self):
        child = offline_child(['READY ok\n', 'RESULT {"ok":true}\n', 'UDP_RE_FAILED {}\n'])
        self.assertEqual(child.wait_marker('RESULT '), {'ok': True})
        with self.assertRaises(RuntimeError):
            child.wait_marker('RESULT ')

    def test_callback_exception_is_redacted_and_reader_continues(self):
        child = offline_child(['READY ok\n', 'RESULT {}\n'],
                              callback=mock.Mock(side_effect=RuntimeError('private-key')))
        self.assertEqual(child.ready(10), 'ok')
        self.assertEqual(child.wait_marker('RESULT '), {})
        self.assertEqual(child.failure, 'child callback failed')
        self.assertNotIn('private-key', repr(child.failures))

    def test_stdout_exception_is_redacted(self):
        child = offline_child([], read=False)
        child.proc.stdout = mock.Mock()
        child.proc.stdout.__iter__ = mock.Mock(side_effect=RuntimeError('private-key'))
        child.read()
        self.assertEqual(child.failure, 'child stdout reader failed')
        with self.assertRaises(RuntimeError):
            child.wait_private()

    def test_concurrent_waiters_wake_and_failure_is_persistent(self):
        child = offline_child([], read=False)
        entered = threading.Barrier(3)
        errors = []

        def wait(call):
            entered.wait()
            try:
                call()
            except RuntimeError as exc:
                errors.append(str(exc))

        threads = [threading.Thread(target=wait, args=(child.wait_private,)),
                   threading.Thread(target=wait, args=(lambda: child.wait_marker('RESULT '),))]
        for thread in threads:
            thread.start()
        entered.wait()
        child._fail('safe failure')
        for thread in threads:
            thread.join(1)
            self.assertFalse(thread.is_alive())
        self.assertEqual(len(errors), 2)
        with self.assertRaises(RuntimeError):
            child.wait_private()

    def test_live_wait_timeout(self):
        child = offline_child([], read=False)
        with self.assertRaises(TimeoutError):
            child.wait_private(0)
        with self.assertRaises(TimeoutError):
            child.wait_marker('RESULT ', 0)


class UdpAdapterGateTest(unittest.TestCase):
    def test_clean_stats_pass(self):
        self.assertEqual(lab.check_godot_adapter(adapter_stats(), 2), [])

    def test_pending_socket_leak_blocks(self):
        self.assertTrue(any('closed_sockets' in s for s in lab.check_godot_adapter(adapter_stats(closed_sockets=2), 2)))

    def test_missing_required_fields_block(self):
        for name in ('state', 'running', 'ready', 'startup_error', 'exit_code',
                     'control_io_errors', 'created_sockets', 'closed_sockets', 'totals', 'sessions'):
            with self.subTest(name=name):
                stats = adapter_stats()
                del stats[name]
                self.assertTrue(lab.check_godot_adapter(stats, 2))
        for name in lab.ADAPTER_COUNTERS:
            for location in ('totals', 'session'):
                with self.subTest(name=name, location=location):
                    stats = adapter_stats()
                    del (stats['totals'] if location == 'totals' else stats['sessions'][0])[name]
                    self.assertTrue(lab.check_godot_adapter(stats, 2))

    def test_invalid_stat_types_block_without_throwing(self):
        for value in (True, False, -1, 0.0, '0', None, [], {}):
            for location in ('totals', 'session', 'startup_error'):
                with self.subTest(value=value, location=location):
                    stats = adapter_stats()
                    if location == 'startup_error':
                        stats['startup_error'] = value
                    else:
                        (stats['totals'] if location == 'totals' else stats['sessions'][0])['io_errors'] = value
                    self.assertTrue(lab.check_godot_adapter(stats, 2))

    def test_malformed_stats_containers_block(self):
        for value in (None, [], True):
            self.assertTrue(lab.check_godot_adapter(value, 2))
            self.assertTrue(lab.check_godot_adapter(adapter_stats(sessions=value), 2))
            self.assertTrue(lab.check_godot_adapter(adapter_stats(totals=value), 2))
        self.assertTrue(lab.check_godot_adapter(adapter_stats(sessions=[None, {}]), 2))

    def test_lifecycle_values_block(self):
        for name, value in (('state', 'running'), ('running', True), ('running', 0),
                            ('ready', True), ('ready', 0), ('exit_code', 1),
                            ('startup_error', 1), ('control_io_errors', 1)):
            with self.subTest(name=name, value=value):
                self.assertTrue(lab.check_godot_adapter(adapter_stats(**{name: value}), 2))

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
        self.assertTrue(any('session0.forwarded_packets' in s for s in lab.check_godot_adapter(stats, 2)))

    def test_send_drop_blocks(self):
        stats = adapter_stats()
        stats['sessions'][0]['send_drops'] = 3
        self.assertTrue(any('send_drops' in s for s in lab.check_godot_adapter(stats, 2)))

    def test_each_total_must_equal_session_sum(self):
        for name in lab.ADAPTER_COUNTERS:
            with self.subTest(name=name):
                stats = adapter_stats()
                stats['totals'][name] += 1
                self.assertTrue(any(f'totals.{name} does not equal session sum' in s
                                    for s in lab.check_godot_adapter(stats, 2)))

    def test_each_session_ledger_must_close_even_with_matching_totals(self):
        for name in ('transport_packets', 'rejected_no_forward', 'forwarded_packets',
                     'raw_packets', 'returned_packets'):
            with self.subTest(name=name):
                stats = adapter_stats()
                stats['sessions'][0][name] += 1
                stats['totals'][name] += 1
                self.assertTrue(any('session0.' in s and 'ledger mismatch' in s
                                    for s in lab.check_godot_adapter(stats, 2)))

    def test_legitimate_authentication_rejections_pass(self):
        stats = adapter_stats()
        for name in ('rejected_packets', 'rejected_no_forward', 'transport_packets'):
            stats['sessions'][0][name] += 7
            stats['totals'][name] += 7
        self.assertEqual(lab.check_godot_adapter(stats, 2), [])

    def test_additional_counter_must_be_typed_present_and_sum(self):
        stats = adapter_stats()
        stats['totals']['future_counter'] = 3
        stats['sessions'][0]['future_counter'] = 1
        stats['sessions'][1]['future_counter'] = 2
        self.assertEqual(lab.check_godot_adapter(stats, 2), [])
        del stats['totals']['future_counter']
        self.assertTrue(lab.check_godot_adapter(stats, 2))


class AdapterSecretCleanupTest(unittest.TestCase):
    def test_all_setup_failures_clear_config_and_environment(self):
        for stage in ('token', 'config_copy', 'encode', 'child'):
            with self.subTest(stage=stage):
                config = {'key_hex': 'private-key'}
                env = {'OTHER': 'kept'}
                bridge = mock.Mock()
                bridge.wait_private.return_value = config
                with mock.patch.object(lab.secrets, 'token_hex', return_value='private-token') as token, \
                     mock.patch.object(lab.os, 'environ') as environ, \
                     mock.patch.object(lab.json, 'dumps', return_value='private-key') as dumps, \
                     mock.patch.object(lab, 'Child', side_effect=RuntimeError('private-key')):
                    environ.copy.return_value = env
                    if stage == 'token':
                        token.side_effect = RuntimeError('private-key')
                    elif stage == 'config_copy':
                        environ.copy.side_effect = RuntimeError('private-key')
                    elif stage == 'encode':
                        dumps.side_effect = ValueError('private-key')
                    with self.assertRaises(RuntimeError) as raised:
                        lab.start_godot_adapter(bridge, {}, Path('output.json'), 'test')
                    self.assertNotIn('private-key', str(raised.exception))
                    self.assertTrue(raised.exception.__suppress_context__)
                self.assertEqual(config, {})
                self.assertNotIn('UDP_LAB_HOST_CONFIG', env)
                self.assertEqual(env['OTHER'], 'kept')
                bridge.wait_private.assert_called_once_with(timeout=10)

    def test_success_clears_copies_before_ready_and_attaches(self):
        config = {'key_hex': 'private-key'}
        env = {}
        bridge, adapter = mock.Mock(), mock.Mock()
        bridge.wait_private.return_value = config

        def ready(timeout):
            self.assertEqual(config, {})
            self.assertNotIn('UDP_LAB_HOST_CONFIG', env)
            return {'ports': [1234]}

        adapter.ready.side_effect = ready
        children = {}
        with mock.patch.object(lab.os, 'environ') as environ, mock.patch.object(lab, 'Child', return_value=adapter) as child:
            environ.copy.return_value = env
            actual, report, token = lab.start_godot_adapter(bridge, children, Path('output.json'), 'test', godot='selected-godot')
            self.assertEqual(child.call_args.args[0][0], 'selected-godot')
        self.assertIs(actual, adapter)
        self.assertEqual(children, {'test': adapter})
        self.assertEqual(report, {'ports': [1234]})
        self.assertTrue(token)
        bridge.command.assert_any_call({'type': 'attach', 'ports': [1234]})

    def test_private_parse_failure_stops_before_child_creation(self):
        bridge = offline_child(['UDP_LAB_PRIVATE_CONFIG private-key\n', 'READY ok\n'])
        bridge.command = mock.Mock()
        with mock.patch.object(lab, 'Child') as child:
            with self.assertRaisesRegex(RuntimeError, 'adapter configuration'):
                lab.start_godot_adapter(bridge, {}, Path('output.json'), 'test')
        child.assert_not_called()


class EchoStabilityTest(unittest.TestCase):
    def test_thresholds_are_strict_and_nearest_rank_spread(self):
        values = [20, 100, 100.1, 250, 250.1, 1000, 1000.1]
        echo = {'count': len(values), 'missing': [], 'duplicates': 0,
                'raw': [{'seq': i, 'sent_usec': i * 100000, 'rtt_ms': value}
                        for i, value in enumerate(values)]}
        before = copy.deepcopy(echo)
        summary = lab.summarize_echo_stability(echo)
        self.assertEqual(summary['count'], 7)
        self.assertEqual(summary['max_ms'], 1000.1)
        self.assertAlmostEqual(summary['p95_minus_p50_ms'], 750.1)
        self.assertEqual([summary[f'above_{v}ms'] for v in (100, 250, 1000)], [5, 3, 1])
        self.assertFalse(summary['diagnostic_buckets_are_sla'])
        self.assertEqual(summary['stability_evaluated_as'], 'observational_no_latency_budget')
        self.assertIn('not_hud_or_input', summary['measurement'])
        self.assertEqual(echo, before)

    def test_reply_gap_sorts_by_local_arrival_not_sequence_or_rtt(self):
        summary = lab.summarize_echo_stability({'raw': [
            {'seq': 0, 'sent_usec': 0, 'rtt_ms': 500},
            {'seq': 1, 'sent_usec': 100000, 'rtt_ms': 10},
            {'seq': 2, 'sent_usec': 200000, 'rtt_ms': 10}]})
        self.assertEqual(summary['max_reply_gap_ms'], 290)

    def test_missing_and_duplicates_remain_separate(self):
        summary = lab.summarize_echo_stability({'count': 4, 'missing': [3], 'duplicates': 2,
            'raw': [{'seq': seq, 'sent_usec': 1, 'rtt_ms': 20} for seq in (0, 0, 2)]})
        self.assertEqual(summary['count'], 3)
        self.assertEqual(summary['missing'], [1, 3])
        self.assertEqual(summary['duplicates'], 2)
        self.assertEqual(summary['max_reply_gap_ms'], 0)

    def test_empty_and_single_sample_are_not_fake_zero_latency(self):
        empty = lab.summarize_echo_stability({})
        for name in ('max_ms', 'p95_minus_p50_ms', 'max_reply_gap_ms'):
            self.assertIsNone(empty[name])
        single = lab.summarize_echo_stability({'raw': [{'seq': 0, 'sent_usec': 1, 'rtt_ms': 2000}]})
        self.assertEqual(single['max_ms'], 2000)
        self.assertEqual(single['p95_minus_p50_ms'], 0)
        self.assertIsNone(single['max_reply_gap_ms'])

    def test_invalid_raw_statistics_cannot_silently_pass(self):
        for field, value in (('seq', True), ('sent_usec', -1), ('rtt_ms', True),
                             ('rtt_ms', -1), ('rtt_ms', float('nan')), ('rtt_ms', float('inf'))):
            with self.subTest(field=field, value=value):
                sample = {'seq': 0, 'sent_usec': 1, 'rtt_ms': 20}
                sample[field] = value
                with self.assertRaises(ValueError):
                    lab.summarize_echo_stability({'raw': [sample]})


class RunCaseReliabilityTest(unittest.TestCase):
    def run_mock_case(self, child_failure=False, observation=False, missing=False):
        host_report = {'ok': True, 'failures': [], 'network': {'enet_connections': {'2': {}}}}
        echo = {'count': 2, 'missing': [], 'duplicates': 0,
                'raw': [{'seq': 0, 'sent_usec': 0, 'rtt_ms': 2000},
                        {'seq': 1, 'sent_usec': 100000, 'rtt_ms': 3000}]}
        if missing:
            echo['raw'].pop()
        client_report = {'ok': True, 'failures': [], 'network': {'enet_connections': {'1': {}}}, 'echo': echo}
        if observation:
            client_report['stability_observation'] = {'measurement': 'probe observation'}
        bridge_report = {'state': 'closed', 'sessions': [{'totals': {'authAcceptedPackets': 10}}],
                         'totals': {'ioErrors': 0, 'rawOversizePackets': 0,
                                    'queueOverflowPackets': 0, 'queueExpiredPackets': 0},
                         'queue': {'packets': 0}}
        children = []
        for marker, report in (('UDP_GAME_HOST_RESULT ', host_report), ('UDP_LAB_FINAL ', bridge_report),
                               ('UDP_GAME_CLIENT_RESULT ', client_report)):
            child = mock.Mock()
            child.lines = [marker + json.dumps(report)]
            child.failures = ['child callback failed'] if child_failure and not children else []
            child.proc.returncode = 0
            child.proc.poll.return_value = 0
            child.ready.return_value = {'address': '127.0.0.1', 'ports': [1234]}
            children.append(child)
        written = []

        def write(path, content, **kwargs):
            if path.suffix == '.json':
                written.append(json.loads(content))

        def child_factory(args, *extra, **kwargs):
            self.assertIn(args[0], ('selected-godot', 'node'))
            return children.pop(0)

        with mock.patch.object(lab, 'Child', side_effect=child_factory), \
             mock.patch.object(Path, 'write_text', autospec=True, side_effect=write), mock.patch('builtins.print'):
            if child_failure or missing:
                with self.assertRaisesRegex(RuntimeError, 'case failed'):
                    lab.run_case(0, 'clean', 1, 2, 31, Path('output.json'), godot='selected-godot')
                return written[-1]
            return lab.run_case(0, 'clean', 1, 2, 31, Path('output.json'), godot='selected-godot')

    def test_large_tail_is_observational_not_stability_pass(self):
        result = self.run_mock_case()
        self.assertTrue(result['ok'])
        self.assertTrue(result['reliability_ok'])
        self.assertEqual(result['stability_evaluated_as'], 'observational_no_latency_budget')
        summary = result['client_results'][0]['stability_summary']
        self.assertEqual(summary['above_1000ms'], 2)
        self.assertNotIn('stable', summary)
        self.assertNotIn('stability_observation', summary)

    def test_optional_probe_observation_is_preserved(self):
        result = self.run_mock_case(observation=True)
        self.assertEqual(result['client_results'][0]['stability_summary']['stability_observation'],
                         {'measurement': 'probe observation'})

    def test_child_failures_cannot_escape_final_gate(self):
        result = self.run_mock_case(child_failure=True)
        self.assertFalse(result['ok'])
        self.assertFalse(result['reliability_ok'])
        self.assertEqual(result['child_failures'], {'host': ['child callback failed']})

    def test_missing_raw_echo_cannot_pass_reliability(self):
        result = self.run_mock_case(missing=True)
        self.assertFalse(result['ok'])
        self.assertFalse(result['reliability_ok'])


class ProbePingWindowTest(unittest.TestCase):
    def test_full_window_uses_content_not_length_or_last_rtt(self):
        source = Path(__file__).with_name('network_udp_game_probe.gd').read_text(encoding='utf-8')
        self.assertNotIn('_observation_last_ping_count', source)
        self.assertIn('ping_window != _observation_last_ping_window or ping_ema != _observation_last_ping_ema', source)
        self.assertIn('_observation_last_ping_window = ping_window.duplicate()', source)
        self.assertIn('"hud_ping_count_is_lower_bound": true', source)
        self.assertIn('window_or_ema_change_observed_per_frame_not_per_pong', source)
        self.assertIn('_observation_truncated = true', source)
        previous = [10] * 119 + [20]
        current = previous[1:] + [20]
        self.assertEqual(len(previous), len(current))
        self.assertEqual(previous[-1], current[-1])
        self.assertNotEqual(previous, current)

    def test_identical_full_window_is_explicitly_not_claimed_complete(self):
        previous = [20] * 120
        current = previous[1:] + [20]
        self.assertEqual(previous, current)
        source = Path(__file__).with_name('network_udp_game_probe.gd').read_text(encoding='utf-8')
        self.assertIn('满窗口完全相同值及同帧多次pong可被合并', source)
        self.assertIn('不声明逐pong完整采样', source)


class LabSetupTest(unittest.TestCase):
    def test_engine_precedence_and_path_lookup_without_starting_processes(self):
        with mock.patch.dict(lab.os.environ, {'GODOT_BIN': 'env-godot', 'GODOT': 'other-godot'}, clear=True), \
             mock.patch.object(Path, 'is_file', return_value=False), \
             mock.patch.object(lab.shutil, 'which', side_effect=lambda name: '/bin/' + name):
            self.assertEqual(lab.resolve_godot('cli-godot'), '/bin/cli-godot')
            self.assertEqual(lab.resolve_godot(), '/bin/env-godot')
        with mock.patch.dict(lab.os.environ, {}, clear=True), \
             mock.patch.object(Path, 'is_file', return_value=False), \
             mock.patch.object(lab.shutil, 'which', side_effect=lambda name: '/bin/godot4' if name == 'godot4' else None):
            self.assertEqual(lab.resolve_godot(), '/bin/godot4')
        with mock.patch.object(Path, 'is_file', return_value=False), \
             mock.patch.object(lab.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, '--godot'):
                lab.resolve_godot('missing-explicit')

    def test_engine_explicit_file(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / 'fake Godot.exe'
            engine.touch()
            self.assertEqual(lab.resolve_godot(str(engine)), str(engine.resolve()))

    def test_config_restores_missing_created_changed_and_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            self.assertIsNone(lab.read_optional_config(config))
            self.assertTrue(lab.restore_config(config, None)['config_unchanged_during_run'])
            config.write_bytes(b'generated')
            status = lab.restore_config(config, None)
            self.assertFalse(status['config_unchanged_during_run'])
            self.assertTrue(status['config_preserved'])
            self.assertIsNone(status['config_sha256'])
            self.assertFalse(config.exists())
            for changed in (b'changed', None):
                if changed is not None:
                    config.write_bytes(changed)
                else:
                    config.unlink(missing_ok=True)
                status = lab.restore_config(config, b'original')
                self.assertFalse(status['config_unchanged_during_run'])
                self.assertTrue(status['config_preserved'])
                self.assertEqual(config.read_bytes(), b'original')
            self.assertEqual(list(Path(directory).iterdir()), [config])

    def test_both_entrypoints_allow_missing_config_and_restore_on_failure(self):
        spec = importlib.util.spec_from_file_location('udp_reconnect_lab', Path(__file__).with_name('network_udp_reconnect_lab.py'))
        reconnect = importlib.util.module_from_spec(spec)
        with mock.patch.dict(sys.modules, {'network_udp_enet_lab': lab}):
            spec.loader.exec_module(reconnect)
        for module, prefix in ((lab, 'network_udp_lab_'), (reconnect, 'network_udp_reconnect_')):
            for mutation in ('none', 'create', 'fail', 'create_then_fail'):
                with self.subTest(module=module.__name__, mutation=mutation), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    config = root / 'config.json'

                    def run(*args, **kwargs):
                        self.assertEqual(kwargs['godot'], 'fake-godot')
                        self.assertTrue((root / '.workbuddy/tmp').is_dir())
                        if 'create' in mutation:
                            config.write_bytes(b'generated')
                        if 'fail' in mutation:
                            raise RuntimeError('mock case failure')
                        return {'ok': True}

                    with mock.patch.object(module, 'ROOT', root), \
                         mock.patch.object(module, 'resolve_godot', return_value='fake-godot'), \
                         mock.patch.object(module, 'run_case', side_effect=run), \
                         mock.patch.object(sys, 'argv', ['lab', '--label', 'offline', '--godot', 'fake-godot']), \
                         mock.patch('builtins.print'):
                        if mutation != 'none':
                            with self.assertRaises(RuntimeError):
                                module.main()
                        else:
                            module.main()
                    report = json.loads((root / '.workbuddy/tmp' / (prefix + 'offline.json')).read_text(encoding='utf-8'))
                    self.assertTrue(report['config_preserved'])
                    self.assertEqual(report['config_unchanged_during_run'], 'create' not in mutation)
                    self.assertFalse(config.exists())
                    self.assertFalse(list(root.rglob('*backup*')))


if __name__ == '__main__':
    unittest.main()
