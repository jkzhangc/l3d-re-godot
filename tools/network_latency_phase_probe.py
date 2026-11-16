"""Sequential phase-decorrelated production Net/Tunnel diagnostics; no config/save writes."""
from __future__ import annotations
import argparse
import hashlib
import json
import queue
import subprocess
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = Path('D:/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64_console.exe')
PREFIX = [str(ENGINE), '--headless', '--path', str(ROOT), '--script',
          'res://tools/network_latency_phase_probe.gd', '--']


def summary(values):
    values = sorted(values)
    if not values:
        return {'n': 0}
    return {'n': len(values), 'min_usec': values[0], 'p50_usec': values[(len(values)+1)//2-1],
            'p95_usec': values[(len(values)*95+99)//100-1],
            'p99_usec': values[(len(values)*99+99)//100-1], 'max_usec': values[-1]}


def trace_summary(result):
    trace = result.get('net_trace', {})
    raw = trace.get('rows', [])
    start = result.get('window_start_usec', 0)
    end = result.get('window_end_usec', 2**63-1)
    # begin/end RPC callbacks toggle capture inside poll. Exclude any straddling window edge.
    rows = [r for r in raw if start <= r[1] and r[1]+r[2] <= end]
    polls = sorted((r for r in rows if int(r[0]) in (0, 1, 3)), key=lambda r: r[1])
    gaps = [b[1]-a[1] for a, b in zip(polls, polls[1:])]
    periods = {}
    transitions = {}
    for phase in (0, 1, 3):
        times = [r[1] for r in polls if int(r[0]) == phase]
        periods[str(phase)] = summary([b-a for a, b in zip(times, times[1:])])
    for a, b in zip(polls, polls[1:]):
        transitions.setdefault(f'{a[0]}->{b[0]}', []).append(b[1]-a[1])
    result['trace_summary'] = {'poll_gap': summary(gaps),
        'phase_periods': periods,
        'phase_transitions': {k: summary(v) for k, v in transitions.items()},
        'window_excluded_rows': len(raw)-len(rows),
        'window_note': 'protocol-enclosed local windows, not clock-synchronized; terminal poll may be absent',
        'poll_cost': summary([r[2] for r in polls]),
        'phase_counts': {str(p): sum(int(r[0]) == p for r in rows) for p in range(4)},
        'dropped': trace.get('dropped', -1),
        'gaps_above_20ms': sum(g > 20000 for g in gaps),
        # Uniform-arrival residual wait E[G^2]/(2E[G]); unlike the median it exposes clustered polls.
        'modeled_uniform_arrival_residual_wait_usec': sum(g*g for g in gaps)/(2*sum(gaps)) if sum(gaps) else 0,
        'note': 'poll_cost includes synchronous RPC callbacks; it is not socket-only CPU time'}


def run_case(index, fps, variant, seed, count, interval, tunnel, out):
    port = 28040 + index
    common = [f'--phase-fps={fps}', f'--phase-seed={seed}', f'--phase-count={count}',
              f'--phase-interval-usec={interval}', f'--phase-port={port}']
    switches = {'base': [], 'late': ['--net-phase-late-render-poll'],
                'threaded': ['--net-tunnel-threaded-io']}[variant]
    # Different deterministic startup phase per seed, identical for a seed's A/B pair.
    phase = (seed * 7919) % 97000
    common.append(f'--phase-start-usec={phase}')
    host_args = PREFIX + common + switches + ['--phase-role=host'] + (['--phase-tunnel'] if tunnel else [])
    ready = queue.Queue()
    lines = []
    host = subprocess.Popen(host_args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding='utf-8', errors='replace')

    def read_host():
        for line in host.stdout:
            lines.append(line.rstrip())
            if line.startswith('PHASE_READY '):
                ready.put(json.loads(line.split(' ', 1)[1]))
            if 'PHASE_ERROR' in line or 'SCRIPT ERROR' in line or 'Parse Error' in line:
                ready.put({'error': line.strip()})

    reader = threading.Thread(target=read_host)
    reader.start()
    client = None
    try:
        endpoint = ready.get(timeout=18)
        if 'error' in endpoint:
            raise RuntimeError(endpoint['error'])
        client = subprocess.run(PREFIX + common + switches + ['--phase-role=client',
            f'--phase-address={endpoint["address"]}', f'--phase-port={endpoint["port"]}'],
            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=115)
        host.wait(timeout=12)
        reader.join(timeout=3)
        result = {'index': index, 'fps': fps, 'variant': variant, 'seed': seed,
                  'startup_phase_usec': phase, 'target_count': count,
                  'interval_usec': interval, 'tunnel': tunnel,
                  'host_exit': host.returncode, 'client_exit': client.returncode}
        for line in lines:
            if line.startswith('PHASE_HOST_RESULT '):
                result['host'] = json.loads(line.split(' ', 1)[1])
        text = client.stdout + client.stderr
        for line in text.splitlines():
            if line.startswith('PHASE_RESULT '):
                result['client'] = json.loads(line.split(' ', 1)[1])
        errors = [l for l in lines + text.splitlines() if 'PHASE_ERROR' in l or 'SCRIPT ERROR' in l or 'Parse Error' in l]
        result['errors'] = errors
        for role in ['host', 'client']:
            if role in result:
                trace_summary(result[role])
        path = out.parent / f'{out.stem}_case{index}.json'
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        if (host.returncode != 0 or client.returncode != 0 or errors
                or result.get('host', {}).get('ok') is not True
                or result.get('client', {}).get('ok') is not True):
            raise RuntimeError(f'phase case failed: {path}; errors={errors}')
        brief = {k: v for k, v in result.items() if k not in ('host', 'client')}
        brief.update({'host_poll': result['host']['trace_summary'],
                      'client_poll': result['client']['trace_summary'],
                      'client_metrics': {k: v for k, v in result['client'].items()
                          if k not in ('net_trace', 'rows', 'render_gap_rows', 'physics_gap_rows', 'skipped_deadline_rows')}})
        print(json.dumps(brief, ensure_ascii=False), flush=True)
        return {'file': str(path), 'summary': brief}
    finally:
        if host.poll() is None:
            host.terminate()
            host.wait(timeout=5)
        reader.join(timeout=3)
        (out.parent / f'{out.stem}_case{index}_host.log').write_text('\n'.join(lines), encoding='utf-8')
        if client is not None:
            (out.parent / f'{out.stem}_case{index}_client.log').write_text(client.stdout+client.stderr, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--count', type=int, default=500)
    parser.add_argument('--interval-usec', type=int, default=50000)
    parser.add_argument('--fps', nargs='+', type=int, default=[30, 60])
    parser.add_argument('--variants', nargs='+', choices=['base', 'late', 'threaded'], default=['base'])
    parser.add_argument('--seeds', nargs='+', type=int, default=[31, 79, 127])
    parser.add_argument('--lan', action='store_true')
    parser.add_argument('--label', default='phase')
    args = parser.parse_args()
    if not 20 <= args.count <= 1500 or not 20000 <= args.interval_usec <= 100000:
        parser.error('count 20..1500 and interval 20000..100000 required')
    if any(f < 15 or f > 240 for f in args.fps) or len(args.fps)*len(args.seeds)*len(args.variants) > 100:
        parser.error('fps 15..240 and at most 100 sequential cases required')
    if args.count*args.interval_usec*1.45 > 85000000:
        parser.error('worst planned window must fit 85 seconds before protocol timeout')
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in args.label):
        parser.error('label must be a simple ASCII name')
    output = ROOT / '.workbuddy/tmp' / f'network_latency_{args.label}.json'
    if output.exists() or any(output.parent.glob(f'{output.stem}_case*')):
        parser.error('label already has evidence; choose a new label to preserve raw measurements')
    config = ROOT / 'config.json'
    before = hashlib.sha256(config.read_bytes()).hexdigest()
    rows = []
    error = None
    try:
        index = 0
        for fps in args.fps:
            for s_index, seed in enumerate(args.seeds):
                variants = args.variants if s_index % 2 == 0 else list(reversed(args.variants))
                for variant in variants:
                    rows.append(run_case(index, fps, variant, seed, args.count,
                                         args.interval_usec, not args.lan, output))
                    index += 1
    except Exception as exc:
        error = repr(exc)
        raise
    finally:
        preserved = hashlib.sha256(config.read_bytes()).hexdigest() == before
        output.write_text(json.dumps({'engine': str(ENGINE), 'cases': rows,
            'config_preserved': preserved, 'error': error}, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'PHASE_OUTPUT {output}; config_preserved={preserved}', flush=True)
        if not preserved:
            raise RuntimeError('config changed; original must be restored from explicit backup')


if __name__ == '__main__':
    main()
