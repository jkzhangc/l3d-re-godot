"""Local authenticated UDP transport + real production Net/World fault-injection runner.
Not a production listener or a TCP lower-layer loss comparison. All child PIDs are owned here.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import queue
import secrets
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = 'D:/Godot_v4.6.3-stable_win64.exe/Godot_v4.6.3-stable_win64_console.exe'
BASE = [ENGINE, '--headless', '--path', str(ROOT), '--script', 'res://tools/network_udp_game_probe.gd', '--']
# 启动期就失败时，子进程可能只打印这些再退出；等待方必须立刻醒来，不能耗到超时。
EARLY_FAILURE_MARKERS = ('UDP_HOST_ERROR ', 'UDP_HOST_FINAL ', 'UDP_LAB_ERROR ')
FAILURE_SENTINEL = '__CHILD_FAILED__ '


class Child:
    def __init__(self, args, prefix, stdin=False, env=None):
        self.lines = []
        self.on_line = None
        self.messages = queue.Queue()
        self.private_messages = queue.Queue()
        self.notifications = queue.Queue()
        self.failure = None
        self.ready_seen = False
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', env=env)
        self.prefix = prefix
        self.thread = threading.Thread(target=self.read)
        self.thread.start()

    def _fail(self, message):
        if self.failure is not None:
            return
        self.failure = message
        self.messages.put({'error': message})
        self.notifications.put(FAILURE_SENTINEL + message)

    def read(self):
        for line in self.proc.stdout:
            # Credentials travel only over the owned anonymous pipe, never into logs/evidence.
            if line.startswith('UDP_LAB_PRIVATE_'):
                self.private_messages.put(json.loads(line.split(' ', 1)[1]))
                continue
            self.notifications.put(line.rstrip())
            self.lines.append(line.rstrip())
            if self.on_line is not None:
                self.on_line(line.rstrip())
            if line.startswith(self.prefix):
                self.ready_seen = True
                self.messages.put(line[len(self.prefix):].strip())
            elif line.startswith(EARLY_FAILURE_MARKERS) and not self.ready_seen:
                self._fail(line.strip())
            if 'SCRIPT ERROR' in line or 'Parse Error' in line or 'UDP_GAME_FAILED' in line:
                self._fail(line.strip())
        # 流结束：没拿到就绪标记说明启动失败；已就绪则只通知等待中的观测点。
        exit_code = self.proc.poll()
        if self.ready_seen:
            self.notifications.put(FAILURE_SENTINEL + f'stdout closed (exit={exit_code})')
        else:
            self._fail(f'stdout closed before {self.prefix.strip()} (exit={exit_code})')

    def ready(self, timeout):
        try:
            value = self.messages.get(timeout=timeout)
        except queue.Empty:
            raise RuntimeError(f'{self.prefix.strip()} not received within {timeout}s; '
                f'exit={self.proc.poll()} failure={self.failure!r}; tail={self.lines[-6:]}')
        if isinstance(value, dict):
            raise RuntimeError(value['error'])
        return json.loads(value) if value.startswith('{') else value

    def command(self, value):
        self.proc.stdin.write(json.dumps(value) + '\n')
        self.proc.stdin.flush()

    def wait_marker(self, marker, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.notifications.get(timeout=max(0.001, deadline - time.monotonic()))
            except queue.Empty:
                raise TimeoutError(f'{marker.strip()} not received within {timeout}s; '
                    f'exit={self.proc.poll()} failure={self.failure!r}')
            if line.startswith(FAILURE_SENTINEL):
                raise RuntimeError(f'{marker.strip()} interrupted: {line[len(FAILURE_SENTINEL):]}')
            if line.startswith(marker):
                return json.loads(line[len(marker):])
            if time.monotonic() >= deadline:
                raise TimeoutError('expected marker not received')

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.thread.join(timeout=3)


def parse_result(child, marker):
    matches = [json.loads(s[len(marker):]) for s in child.lines if s.startswith(marker)]
    if len(matches) != 1:
        raise RuntimeError(f'expected one {marker} got {len(matches)}; tail={child.lines[-10:]}')
    return matches[0]


def start_godot_adapter(bridge, children, output, label):
    bridge.command({'type': 'external-config'})
    config = bridge.private_messages.get(timeout=10)
    token = secrets.token_hex(24)
    config['control_token'] = token
    env = os.environ.copy()
    env['UDP_LAB_HOST_CONFIG'] = json.dumps(config)
    log = output.parent / f'{output.stem}_{label}_adapter_engine.log'
    adapter = None
    try:
        adapter = Child([ENGINE, '--headless', '--path', str(ROOT), '--log-file', str(log),
            '--script', 'res://tools/network_udp_host_bridge.gd'], 'UDP_HOST_READY ', env=env)
    finally:
        # 启动失败也要擦掉持密副本：环境变量与本地配置都不留在进程/异常栈里。
        env.pop('UDP_LAB_HOST_CONFIG', None)
        config.clear()
    children[label] = adapter
    ready = adapter.ready(12)
    bridge.command({'type': 'attach', 'ports': ready['ports']})
    bridge.wait_marker('UDP_LAB_ATTACHED ')
    return adapter, ready, token


def control_command(port, token, command, wait_reply=False):
    value = dict(command, token=token)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        sock.settimeout(3)
        sock.sendto(json.dumps(value).encode(), ('127.0.0.1', port))
        if wait_reply:
            packet, source = sock.recvfrom(65535)
            if source != ('127.0.0.1', port):
                raise RuntimeError('unexpected test control source')
            return json.loads(packet)


ZERO_ADAPTER_COUNTERS = ('io_errors', 'receive_errors', 'send_drops', 'busy_drops',
                         'raw_oversize', 'wire_oversize', 'seal_rejected')


def check_godot_adapter(stats, clients):
    """Godot 工作线程门禁：只认实际搬运结果，不接受「进程退出 0」当通过。"""
    failures = []
    totals = stats.get('totals', {})
    if stats.get('state') != 'closed':
        failures.append(f"state={stats.get('state')!r}")
    if len(stats.get('sessions', [])) != clients:
        failures.append(f"session_count={len(stats.get('sessions', []))} expected={clients}")
    expected_sockets = clients * 2
    if stats.get('created_sockets') != expected_sockets:
        failures.append(f"created_sockets={stats.get('created_sockets')} expected={expected_sockets}")
    if stats.get('closed_sockets') != expected_sockets:
        failures.append(f"closed_sockets={stats.get('closed_sockets')} expected={expected_sockets}")
    if int(stats.get('startup_error', 0)) != 0:
        failures.append(f"startup_error={stats.get('startup_error')}")
    for name in ZERO_ADAPTER_COUNTERS:
        if int(totals.get(name, -1)) != 0:
            failures.append(f'totals.{name}={totals.get(name)}')
    for name in ('accepted_packets', 'forwarded_packets', 'sealed_packets', 'returned_packets'):
        if int(totals.get(name, 0)) <= 0:
            failures.append(f'totals.{name} not positive')
    for index, session in enumerate(stats.get('sessions', [])):
        # 每个 session 两个方向都必须真的搬运过，避免「某客户端整段静默仍判过」。
        for name in ('accepted_packets', 'forwarded_packets', 'sealed_packets', 'returned_packets'):
            if int(session.get(name, 0)) <= 0:
                failures.append(f'session{index}.{name} not positive')
        for name in ('raw_oversize', 'wire_oversize', 'seal_rejected', 'send_drops', 'io_errors'):
            if int(session.get(name, -1)) != 0:
                failures.append(f'session{index}.{name}={session.get(name)}')
    return failures


def run_case(index, profile, clients, count, seed, output, adapter_mode='node'):
    host_port = 28160 + index
    children = {}
    result = {'profile': profile, 'seed': seed, 'clients': clients, 'count': count,
              'adapter': adapter_mode,
              'scope': 'localhost real ENet/World through authenticated UDP carrier; no public path'}
    try:
        # Each Godot child gets its own log; concurrent default user:// log rotation can collide.
        def engine_command(role):
            log = output.parent / f'{output.stem}_{index}_{profile}_{role}_engine.log'
            return BASE[:4] + ['--log-file', str(log)] + BASE[4:]
        host = Child(engine_command('host') + [f'--udp-lab-role=host', f'--udp-lab-port={host_port}',
            f'--udp-lab-clients={clients}', f'--udp-lab-count={count}', '--udp-lab-fps=60'], 'UDP_GAME_HOST_READY')
        children['host'] = host
        host.ready(15)
        loss = {'clean': 0, 'loss1': 0.01, 'loss5': 0.05, 'outage': 0.01}[profile]
        bridge_args = ['node', str(ROOT / 'tools/network_udp_enet_proxy.mjs'),
            f'--host-port={host_port}', f'--clients={clients}', f'--seed={seed}', f'--loss={loss}',
            '--delay-ms=4', '--jitter-ms=' + ('0' if profile == 'clean' else '10'),
            '--duplicate=' + ('0' if profile == 'clean' else '0.02')]
        if adapter_mode == 'godot':
            bridge_args += ['--external-host=1']
        bridge = Child(bridge_args, 'UDP_LAB_READY ', stdin=True)
        children['bridge'] = bridge
        endpoint = bridge.ready(10)
        adapter, adapter_ready, adapter_token = (None, None, None)
        if adapter_mode == 'godot':
            adapter, adapter_ready, adapter_token = start_godot_adapter(
                bridge, children, output, f'{index}_{profile}_adapter')
        blackout_triggered = threading.Event()
        bridge_command_errors = []
        def on_host_line(line):
            if profile == 'outage' and line.startswith('UDP_GAME_ECHO_ACTIVE') and not blackout_triggered.is_set():
                blackout_triggered.set()
                try:
                    bridge.proc.stdin.write('{"type":"blackout","durationMs":300}\n')
                    bridge.proc.stdin.flush()
                except (OSError, ValueError) as exc:
                    bridge_command_errors.append(str(exc))
        host.on_line = on_host_line
        if endpoint.get('address') != '127.0.0.1' or len(endpoint.get('ports', [])) != clients:
            raise RuntimeError('bridge did not expose expected localhost-only endpoints')
        for i, port in enumerate(endpoint['ports']):
            children[f'client{i}'] = Child(engine_command(f'client{i}') + ['--udp-lab-role=client',
                f'--udp-lab-port={port}', f'--udp-lab-index={i}', f'--udp-lab-clients={clients}',
                f'--udp-lab-count={count}', '--udp-lab-fps=60'], 'UDP_GAME_CLIENT_RESULT ')
        host.proc.wait(timeout=110)
        for name, child in children.items():
            if name.startswith('client'):
                child.proc.wait(timeout=12)
        if bridge.proc.poll() is None:
            bridge.proc.stdin.write('{"type":"close"}\n')
            bridge.proc.stdin.flush()
            bridge.proc.wait(timeout=8)
        if adapter is not None:
            control_command(adapter_ready['control_port'], adapter_token, {'type': 'close'})
            adapter.proc.wait(timeout=8)
        for child in children.values():
            child.thread.join(timeout=3)
        if adapter is not None:
            result['godot_adapter'] = parse_result(adapter, 'UDP_HOST_FINAL ')
        result['exit_codes'] = {n: c.proc.returncode for n, c in children.items()}
        result['host'] = parse_result(host, 'UDP_GAME_HOST_RESULT ')
        result['client_results'] = [parse_result(children[f'client{i}'], 'UDP_GAME_CLIENT_RESULT ') for i in range(clients)]
        result['bridge'] = parse_result(bridge, 'UDP_LAB_FINAL ')
        result['script_errors'] = [s for c in children.values() for s in c.lines
            if 'SCRIPT ERROR' in s or 'Parse Error' in s or 'UDP_GAME_FAILED' in s]
        totals = result['bridge'].get('totals', {})
        result['fault_coverage'] = {
            'loss_observed': totals.get('lossDroppedPackets', 0) > 0 if loss else True,
            'blackout_observed': (blackout_triggered.is_set() and not bridge_command_errors
                and totals.get('blackoutDroppedPackets', 0) > 0) if profile == 'outage' else True,
            'each_session_loss_observed': all(s['totals'].get('lossDroppedPackets', 0) > 0
                for s in result['bridge'].get('sessions', [])) if loss else True}
        result['ok'] = (all(v == 0 for v in result['exit_codes'].values()) and not result['script_errors']
            and all(result['fault_coverage'].values())
            and result['bridge'].get('state') == 'closed'
            and len(result['bridge'].get('sessions', [])) == clients
            and all(s['totals'].get('authAcceptedPackets', 0) > 0 for s in result['bridge'].get('sessions', []))
            and len(result['host'].get('network', {}).get('enet_connections', {})) == clients
            and all(set(c.get('network', {}).get('enet_connections', {})) == {'1'} for c in result['client_results'])
            and result['host'].get('ok') is True and result['host'].get('failures') == []
            and all(c.get('ok') is True and c.get('failures') == [] for c in result['client_results'])
            and result['bridge'].get('totals', {}).get('ioErrors', 1) == 0
            and result['bridge'].get('totals', {}).get('rawOversizePackets', 1) == 0
            and result['bridge'].get('totals', {}).get('queueOverflowPackets', 1) == 0
            and result['bridge'].get('totals', {}).get('queueExpiredPackets', 1) == 0
            and result['bridge'].get('queue', {}).get('packets', -1) == 0)
        result['engine_warnings'] = [s for c in children.values() for s in c.lines
            if 'WARNING:' in s or 'ERROR:' in s]
        result['engine_runtime_errors'] = [s for s in result['engine_warnings']
            if s.startswith('ERROR:') and 'resources still in use at exit' not in s]
        result['ok'] = result['ok'] and not result['engine_runtime_errors']
        if adapter_mode == 'godot':
            adapter_failures = check_godot_adapter(result['godot_adapter'], clients)
            result['godot_adapter_gate'] = adapter_failures
            result['ok'] = result['ok'] and not adapter_failures
        print(json.dumps({'profile': profile, 'seed': seed, 'ok': result['ok'],
            'host_checks': result['host'].get('checks'), 'host_failures': result['host'].get('failures'),
            'clients': [{'index': c.get('index'), 'checks': c.get('checks'), 'failures': c.get('failures'),
                'echo': {k: v for k, v in c.get('echo', {}).items() if k != 'raw'}} for c in result['client_results']],
            'bridge_totals': totals, 'queue': result['bridge'].get('queue'),
            'fault_coverage': result['fault_coverage'], 'exit_codes': result['exit_codes'],
            'godot_adapter_gate': result.get('godot_adapter_gate'),
            'engine_warning_count': len(result['engine_warnings'])}, ensure_ascii=False), flush=True)
        if not result['ok']:
            raise RuntimeError('real UDP/ENet game case failed')
        return result
    except Exception as exc:
        result['error'] = repr(exc)
        raise
    finally:
        result.setdefault('exit_codes_before_cleanup', {n: c.proc.poll() for n, c in children.items()})
        for name, child in children.items():
            child.stop()
            (output.parent / f'{output.stem}_{index}_{profile}_{name}.log').write_text('\n'.join(child.lines), encoding='utf-8')
        (output.parent / f'{output.stem}_{index}_{profile}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profiles', nargs='+', choices=['clean', 'loss1', 'loss5', 'outage'], default=['clean', 'loss1', 'loss5', 'outage'])
    parser.add_argument('--clients', type=int, choices=[1, 2, 3], default=2)
    parser.add_argument('--adapter', choices=['node', 'godot'], default='node')
    parser.add_argument('--count', type=int, default=150)
    parser.add_argument('--seed', type=int, default=31)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    if not 20 <= args.count <= 300:
        parser.error('count must be 20..300')
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in args.label):
        parser.error('label must be a simple ASCII identifier')
    output = ROOT / '.workbuddy/tmp' / f'network_udp_lab_{args.label}.json'
    if output.exists() or any(output.parent.glob(f'{output.stem}_*')):
        parser.error('label already has evidence; choose a new label')
    config = ROOT / 'config.json'
    before = config.read_bytes()
    backup = output.with_name(f'.{output.stem}_config_backup.json')
    shutil.copy2(config, backup)
    cases, error = [], None
    try:
        for index, profile in enumerate(args.profiles):
            cases.append(run_case(index, profile, args.clients, args.count, args.seed, output, args.adapter))
    except Exception as exc:
        error = repr(exc)
        raise
    finally:
        unchanged = config.read_bytes() == before
        if not unchanged:
            shutil.copy2(backup, config)
        result = {'cases': cases, 'error': error, 'config_unchanged_during_run': unchanged,
            'config_preserved': config.read_bytes() == before,
            'config_sha256': hashlib.sha256(before).hexdigest(),
            'public_server_modified': False, 'tcp_lower_layer_comparison': False}
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'UDP_GAME_OUTPUT {output}; config_preserved={result["config_preserved"]}', flush=True)
        if not unchanged:
            raise RuntimeError('test modified config; original restored, run rejected')


if __name__ == '__main__':
    main()
