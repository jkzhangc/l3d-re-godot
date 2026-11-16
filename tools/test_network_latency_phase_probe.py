"""Offline unit checks for the phase probe analysis; no Godot or sockets."""
import importlib.util
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name('network_latency_phase_probe.py')
SPEC = importlib.util.spec_from_file_location('phase_probe', MODULE)
phase = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(phase)


class PhaseAnalysisTest(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(phase.summary([]), {'n': 0})

    def test_nearest_rank_matches_gdscript(self):
        result = phase.summary(list(range(1, 101)))
        self.assertEqual([result[k] for k in ['p50_usec', 'p95_usec', 'p99_usec']], [50, 95, 99])
        self.assertEqual(phase.summary([4, 2])['p50_usec'], 2)

    def test_flush_is_not_poll(self):
        result = {'net_trace': {'rows': [[0, 100, 1], [2, 110, 1], [1, 150, 1], [3, 200, 1]], 'dropped': 0}}
        phase.trace_summary(result)
        self.assertEqual(result['trace_summary']['poll_gap']['n'], 2)
        self.assertEqual(result['trace_summary']['poll_gap']['p50_usec'], 50)
        self.assertEqual(result['trace_summary']['phase_counts'], {'0': 1, '1': 1, '2': 1, '3': 1})

    def test_window_edges_are_explicitly_excluded(self):
        result = {'window_start_usec': 100, 'window_end_usec': 200,
                  'net_trace': {'rows': [[0, 90, 20], [0, 110, 3], [1, 150, 4], [2, 199, 2]], 'dropped': 0}}
        phase.trace_summary(result)
        self.assertEqual(result['trace_summary']['window_excluded_rows'], 2)
        self.assertEqual(result['trace_summary']['poll_gap']['p50_usec'], 40)

    def test_clustered_polls_do_not_imply_even_service(self):
        result = {'net_trace': {'rows': [[0, 0, 0], [0, 1, 0], [1, 2, 0], [0, 33000, 0]], 'dropped': 0}}
        phase.trace_summary(result)
        self.assertEqual(result['trace_summary']['poll_gap']['p50_usec'], 1)
        self.assertGreater(result['trace_summary']['modeled_uniform_arrival_residual_wait_usec'], 16000)
        self.assertEqual(result['trace_summary']['gaps_above_20ms'], 1)


if __name__ == '__main__':
    unittest.main()
