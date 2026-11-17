"""Local only: rotate carrier credentials and actually recreate ENet client sessions.
The host game process survives both epochs. This does not claim live World recovery,
production credential exchange, NAT rebinding, TCP fallback, or public 20ms latency.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import secrets
import shutil
import time
from pathlib import Path
from network_udp_enet_lab import (ROOT, ENGINE, Child, check_godot_adapter, control_command,
                                  parse_result, start_godot_adapter)


def wait_status(endpoint, token, predicate, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = control_command(endpoint['control_port'], token,
            {'type': 'status', 'request_id': secrets.token_hex(4)}, wait_reply=True)
        if predicate(last):
            return last
        # A blocking control round-trip paces checks, not a busy spin or frame lock.
        # Delay on a selectable local event, without changing Godot frame timing.
        import threading
        threading.Event().wait(0.05)
    raise TimeoutError(f'probe status deadline; last={last}')


def run_case(output, clients, count, seed, loss):
    children, endpoints, status = {}, {}, {}
    token = secrets.token_hex(24)
    env = dict(os.environ, UDP_LAB_RE_CONTROL_TOKEN=token)
    result = {'clients': clients, 'count': count, 'seed': seed, 'loss': loss,
              'scope': 'localhost Godot codec worker + real production lobby ENet reconnect',
              'ok': False, 'epochs': [], 'stale_injection': None}
    bridge = adapter = None
    adapter_ready = adapter_token = None

    def spawn_probe(role, port, index=0):
        name = role if role == 'host' else f'client{index}'
        child = Child([ENGINE, '--headless', '--path', str(ROOT), '--log-file',
            str(output.parent / f'{output.stem}_{name}_engine.log'), '--script',
            'res://tools/network_udp_reconnect_probe.gd', '--', f'--udp-re-role={role}',
            f'--udp-re-port={port}', f'--udp-re-index={index}', f'--udp-re-clients={clients}'],
            'UDP_RE_READY ', env=env)
        children[name] = child
        endpoints[name] = child.ready(12)
        return child

    def start_carrier(epoch, host_port):
        lab = Child(['node', str(ROOT / 'tools/network_udp_enet_proxy.mjs'),
            f'--host-port={host_port}', f'--clients={clients}', f'--seed={seed + epoch}',
            f'--loss={loss}', '--delay-ms=4', '--jitter-ms=10', '--duplicate=0.02',
            '--external-host=1'], 'UDP_LAB_READY ', stdin=True)
        children[f'bridge{epoch}'] = lab
        ready = lab.ready(10)
        worker, worker_ready, worker_token = start_godot_adapter(
            lab, children, output, f'adapter{epoch}')
        return lab, ready, worker, worker_ready, worker_token

    def close_carrier(lab, worker, ready, worker_token):
        lab.command({'type': 'close'})
        lab.proc.wait(timeout=8)
        control_command(ready['control_port'], worker_token, {'type': 'close'})
        worker.proc.wait(timeout=8)
        lab.thread.join(timeout=3)
        worker.thread.join(timeout=3)
        return {'bridge': parse_result(lab, 'UDP_LAB_FINAL '),
                'adapter': parse_result(worker, 'UDP_HOST_FINAL ')}

    try:
        host_port = 28560
        host = spawn_probe('host', host_port)
        bridge, ready, adapter, adapter_ready, adapter_token = start_carrier(1, host_port)
        for i, port in enumerate(ready['ports']):
            spawn_probe('client', port, i)
        host_initial = wait_status(endpoints['host'], token,
            lambda s: len(s.get('names', {})) == clients + 1)
        initial_ids = []
        for i in range(clients):
            name = f'client{i}'
            s = wait_status(endpoints[name], token, lambda s: s.get('connected') is True)
            initial_ids.append(s['peer_id'])
        for epoch in (1, 2):
            for i in range(clients):
                response = control_command(endpoints[f'client{i}']['control_port'], token,
                    {'type': 'exercise', 'request_id': f'exercise{epoch}_{i}',
                     'epoch': epoch, 'count': count}, wait_reply=True)
                if response.get('accepted') is not True:
                    raise RuntimeError('exercise not accepted')
            epoch_clients = []
            for i in range(clients):
                s = wait_status(endpoints[f'client{i}'], token,
                    lambda s: str(epoch) in s.get('epochs', {}) and not s.get('busy', True), timeout=30)
                report = s['epochs'][str(epoch)]
                if report.get('ok') is not True:
                    raise RuntimeError('reconnect exercise failed')
                epoch_clients.append(s)
            h = wait_status(endpoints['host'], token,
                lambda s: s.get('ledger_count') == clients * count)
            result['epochs'].append({'epoch': epoch, 'host': h, 'clients': epoch_clients})
            if epoch == 2:
                break
            # Retain old authenticated packets only in memory, not evidence logs.
            bridge.command({'type': 'export-replay'})
            old_packets = bridge.private_messages.get(timeout=5)['packets']
            if len(old_packets) != clients:
                raise RuntimeError('old authenticated packet capture incomplete')
            for i in range(clients):
                response = control_command(endpoints[f'client{i}']['control_port'], token,
                    {'type': 'drop', 'request_id': f'drop{i}'}, wait_reply=True)
                if response.get('dropped') is not True:
                    raise RuntimeError('client did not actually leave ENet')
                wait_status(endpoints[f'client{i}'], token, lambda s: s.get('connected') is False)
            host_dropped = wait_status(endpoints['host'], token,
                lambda s: len(s.get('names', {})) == 1, timeout=25)
            result['old_host_ids_removed'] = all(str(i) not in host_dropped['names'] for i in initial_ids)
            result['carrier_epoch1'] = close_carrier(bridge, adapter, adapter_ready, adapter_token)
            bridge, ready, adapter, adapter_ready, adapter_token = start_carrier(2, host_port)
            # Inject old valid packets via NEW trusted source sockets at the NEW worker.
            # Failure is therefore old session authentication, not just a wrong source port.
            bridge.command({'type': 'inject-replay', 'packets': old_packets})
            injection = bridge.wait_marker('UDP_LAB_REPLAY_INJECTED ')
            old_packets.clear()
            control_command(adapter_ready['control_port'], adapter_token, {'type': 'stats'})
            # Stats publication is periodic; wait via status command observations for rejects.
            deadline = time.monotonic() + 5
            while True:
                control_command(adapter_ready['control_port'], adapter_token, {'type': 'stats'})
                stats = adapter.wait_marker('UDP_HOST_STATS ', timeout=5)
                if all(s.get('rejected_packets', 0) >= 1 for s in stats.get('sessions', [])):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('old session packets not observed/rejected')
            result['stale_injection'] = {'sent': injection, 'worker_stats': stats,
                'no_forward': all(s.get('forwarded_packets', -1) == 0
                    and s.get('accepted_packets', -1) == 0 for s in stats.get('sessions', []))}
            if not result['stale_injection']['no_forward']:
                raise RuntimeError('old session packet forwarded to new ENet backend')
            for i, port in enumerate(ready['ports']):
                response = control_command(endpoints[f'client{i}']['control_port'], token,
                    {'type': 'join', 'request_id': f'join{i}', 'port': port, 'epoch': 2}, wait_reply=True)
                if response.get('accepted') is not True:
                    raise RuntimeError('new ENet join not accepted')
            wait_status(endpoints['host'], token, lambda s: len(s.get('names', {})) == clients + 1)
            fresh_ids = [wait_status(endpoints[f'client{i}'], token,
                lambda s: s.get('connected') is True)['peer_id'] for i in range(clients)]
            result['peer_ids_changed'] = all(a != b for a, b in zip(initial_ids, fresh_ids))
            result['initial_ids'], result['fresh_ids'] = initial_ids, fresh_ids
            if not result['peer_ids_changed'] or not result['old_host_ids_removed']:
                raise RuntimeError('reconnect did not recreate distinct ENet peers')
        for name in ['host', *[f'client{i}' for i in range(clients)]]:
            control_command(endpoints[name]['control_port'], token,
                {'type': 'finish', 'request_id': f'finish_{name}'}, wait_reply=True)
        for name, child in children.items():
            if name == 'host' or name.startswith('client'):
                child.proc.wait(timeout=8)
                child.thread.join(timeout=3)
        result['carrier_epoch2'] = close_carrier(bridge, adapter, adapter_ready, adapter_token)
        result['probe_results'] = {name: parse_result(child, 'UDP_RE_RESULT ')
            for name, child in children.items() if name == 'host' or name.startswith('client')}
        result['exit_codes'] = {name: child.proc.returncode for name, child in children.items()}
        result['engine_errors'] = [line for child in children.values() for line in child.lines
            if 'SCRIPT ERROR' in line or 'Parse Error' in line
            or (line.startswith('ERROR:') and 'resources still in use at exit' not in line)]
        result['ok'] = (all(v == 0 for v in result['exit_codes'].values())
            and not result['engine_errors'] and all(s.get('ok') is True for s in result['probe_results'].values())
            and result['peer_ids_changed'] and result['old_host_ids_removed']
            and result['stale_injection']['no_forward'])
        adapter_gate = {}
        for key in ['carrier_epoch1', 'carrier_epoch2']:
            carrier = result[key]
            adapter_gate[key] = check_godot_adapter(carrier['adapter'], clients)
            if carrier['bridge']['totals']['ioErrors'] != 0:
                adapter_gate[key].append(f"bridge.ioErrors={carrier['bridge']['totals']['ioErrors']}")
            result['ok'] = result['ok'] and not adapter_gate[key]
        result['godot_adapter_gate'] = adapter_gate
        if not result['ok']:
            raise RuntimeError('strict reconnect gate failed')
        return result
    except Exception as exc:
        result['error'] = repr(exc)
        raise
    finally:
        for name, child in children.items():
            child.stop()
            (output.parent / f'{output.stem}_{name}.log').write_text('\n'.join(child.lines), encoding='utf-8')
        output.with_name(output.stem + '_case.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--clients', type=int, choices=[1, 2, 3], default=2)
    parser.add_argument('--count', type=int, default=30)
    parser.add_argument('--seed', type=int, default=31)
    parser.add_argument('--loss', type=float, default=0.01)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    if not 20 <= args.count <= 100 or not 0 <= args.loss <= 0.05:
        parser.error('count20..100/loss0..0.05 required')
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in args.label):
        parser.error('label must be ASCII identifier')
    output = ROOT / '.workbuddy/tmp' / f'network_udp_reconnect_{args.label}.json'
    if output.exists() or any(output.parent.glob(output.stem + '_*')):
        parser.error('label already has evidence')
    config = ROOT / 'config.json'
    before = config.read_bytes()
    backup = output.with_name('.' + output.stem + '_config_backup.json')
    shutil.copy2(config, backup)
    result = {}
    try:
        result = run_case(output, args.clients, args.count, args.seed, args.loss)
    finally:
        unchanged = config.read_bytes() == before
        if not unchanged:
            shutil.copy2(backup, config)
        result.update(config_unchanged_during_run=unchanged,
            config_preserved=config.read_bytes() == before,
            config_sha256=hashlib.sha256(before).hexdigest())
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('UDP_RECONNECT_OUTPUT', output, 'ok=', result.get('ok', False), flush=True)
        if not unchanged:
            raise RuntimeError('config was modified; restored, run rejected')


if __name__ == '__main__':
    main()
