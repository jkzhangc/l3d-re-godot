"""Local authenticated UDP transport + real production Net/World fault-injection runner.
Not a production listener or a TCP lower-layer loss comparison. All child PIDs are owned here.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
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
ENGINE = 'godot'


def resolve_godot(explicit=None):
    """优先命令行、环境变量，再查找 PATH；不启动引擎。"""
    configured = explicit or os.environ.get('GODOT_BIN') or os.environ.get('GODOT')
    candidates = [configured] if configured else [ENGINE, 'godot4', 'godot-console', 'godot4-console']
    for candidate in candidates:
        path = Path(candidate).expanduser()
        if path.is_file():
            return str(path.resolve())
        found = shutil.which(str(path))
        if found:
            return found
    raise ValueError('Godot executable not found; use --godot or GODOT_BIN/GODOT, or add Godot to PATH')


def read_optional_config(config):
    """配置只按不透明字节保存，不解析或打印内容。"""
    try:
        return config.read_bytes()
    except FileNotFoundError:
        return None


def restore_config(config, before):
    """恢复原内容或原不存在状态；不创建含私有配置的磁盘备份。"""
    unchanged = read_optional_config(config) == before
    if not unchanged:
        if before is None:
            config.unlink(missing_ok=True)
        else:
            config.write_bytes(before)
    return {'config_unchanged_during_run': unchanged,
            'config_preserved': read_optional_config(config) == before,
            'config_sha256': hashlib.sha256(before).hexdigest() if before is not None else None}

# 启动期就失败时，子进程可能只打印这些再退出；等待方必须立刻醒来，不能耗到超时。
EARLY_FAILURE_MARKERS = ('UDP_HOST_ERROR ', 'UDP_HOST_FINAL ', 'UDP_LAB_ERROR ', 'UDP_RE_FAILED ')


class Child:
    def __init__(self, args, prefix, stdin=False, env=None):
        self.lines = []
        self.on_line = None
        self.messages = queue.Queue()
        self.private_messages = queue.Queue()
        self.notifications = queue.Queue()
        self.failure = None
        self.failures = []
        self.closed_reason = None
        self._condition = threading.Condition()
        self.ready_seen = False
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', env=env)
        self.prefix = prefix
        self.thread = threading.Thread(target=self.read)
        self.thread.start()

    def _fail(self, message):
        with self._condition:
            if self.failure is None:
                self.failure = message
            self.failures.append(message)
            self._condition.notify_all()

    def read(self):
        try:
            for line in self.proc.stdout:
                # 私有行不进入日志、回调或异常；解析器异常也不能终止 reader。
                if line.startswith('UDP_LAB_PRIVATE_'):
                    try:
                        value = json.loads(line.split(' ', 1)[1])
                        if not isinstance(value, dict):
                            raise ValueError
                    except Exception:
                        self._fail('invalid private JSON message')
                        continue
                    with self._condition:
                        self.private_messages.put(value)
                        self._condition.notify_all()
                    continue
                line = line.rstrip()
                with self._condition:
                    self.notifications.put(line)
                    self.lines.append(line)
                    if line.startswith(self.prefix):
                        self.ready_seen = True
                        self.messages.put(line[len(self.prefix):].strip())
                    elif line.startswith(EARLY_FAILURE_MARKERS):
                        if line.startswith('UDP_HOST_FINAL ') and self.ready_seen:
                            self.closed_reason = 'UDP_HOST_FINAL received'
                        else:
                            self._fail(line.split(' ', 1)[0] + ' received')
                    if 'SCRIPT ERROR' in line or 'Parse Error' in line or 'UDP_GAME_FAILED' in line:
                        self._fail('child script failure')
                    self._condition.notify_all()
                if self.on_line is not None:
                    try:
                        self.on_line(line)
                    except Exception:
                        self._fail('child callback failed')
        except Exception:
            self._fail('child stdout reader failed')
        finally:
            with self._condition:
                self.closed_reason = f'stdout closed (exit={self.proc.poll()})'
                if not self.ready_seen:
                    self._fail(f'stdout closed before {self.prefix.strip()} (exit={self.proc.poll()})')
                self._condition.notify_all()

    def _wait(self, messages, timeout, label, allow_queued=False):
        deadline = time.monotonic() + timeout
        with self._condition:
            while True:
                reason = self.failure or self.closed_reason
                if reason and not allow_queued:
                    raise RuntimeError(f'{label} interrupted: {reason}')
                try:
                    return messages.get_nowait()
                except queue.Empty:
                    if reason:
                        raise RuntimeError(f'{label} interrupted: {reason}')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f'{label} not received within {timeout}s')
                self._condition.wait(remaining)

    def ready(self, timeout):
        value = self._wait(self.messages, timeout, self.prefix.strip(), allow_queued=True)
        return json.loads(value) if value.startswith('{') else value

    def wait_private(self, timeout=10):
        """等待私有对象；失败或 EOF 后的所有调用均立即失败，且不泄漏私有原文。"""
        return self._wait(self.private_messages, timeout, 'private message')

    def command(self, value):
        self.proc.stdin.write(json.dumps(value) + '\n')
        self.proc.stdin.flush()

    def wait_marker(self, marker, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            line = self._wait(self.notifications, max(0, deadline - time.monotonic()),
                              marker.strip(), allow_queued=True)
            if line.startswith(marker):
                return json.loads(line[len(marker):])

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


def start_godot_adapter(bridge, children, output, label, godot=None):
    bridge.command({'type': 'external-config'})
    config, env = None, None
    try:
        config = bridge.wait_private(timeout=10)
        token = secrets.token_hex(24)
        config['control_token'] = token
        env = os.environ.copy()
        env['UDP_LAB_HOST_CONFIG'] = json.dumps(config)
        log = output.parent / f'{output.stem}_{label}_adapter_engine.log'
        adapter = Child([godot or ENGINE, '--headless', '--path', str(ROOT), '--log-file', str(log),
            '--script', 'res://tools/network_udp_host_bridge.gd'], 'UDP_HOST_READY ', env=env)
    except Exception:
        raise RuntimeError('adapter configuration or child startup failed') from None
    finally:
        # 配置修改、环境复制、编码及启动异常都经过同一清理路径。
        if env is not None:
            env.pop('UDP_LAB_HOST_CONFIG', None)
        if config is not None:
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
ADAPTER_COUNTERS = ('transport_packets', 'raw_packets', 'accepted_packets',
                    'rejected_packets', 'rejected_no_forward', 'forwarded_packets',
                    'sealed_packets', 'returned_packets', 'busy_errors') + ZERO_ADAPTER_COUNTERS


def check_godot_adapter(stats, clients):
    """严格校验 worker 生命周期、统计类型及逐 session 收支，允许闭合的认证拒绝。"""
    failures = []
    if not isinstance(stats, dict):
        return ['stats must be an object']

    def integer(value, label):
        if type(value) is not int or value < 0:
            failures.append(f'{label} must be a nonnegative integer')
            return False
        return True

    for name, expected in (('state', 'closed'), ('running', False), ('ready', False)):
        if type(stats.get(name)) is not type(expected) or stats.get(name) != expected:
            failures.append(f'{name} must equal {expected!r}')
    for name, expected in (('created_sockets', clients * 2), ('closed_sockets', clients * 2),
                           ('startup_error', 0), ('exit_code', 0), ('control_io_errors', 0)):
        value = stats.get(name)
        if integer(value, name) and value != expected:
            failures.append(f'{name}={value} expected={expected}')
    # worker 与 bridge 发布的其余数值字段同样不能接受 bool、负数或字符串。
    for name, value in stats.items():
        if name not in ('state', 'running', 'ready', 'sessions', 'totals', 'ports', 'backend_ports', 'reason'):
            integer(value, name)
    sessions = stats.get('sessions')
    totals = stats.get('totals')
    if not isinstance(sessions, list):
        failures.append('sessions must be an array')
        sessions = []
    if len(sessions) != clients:
        failures.append(f'session_count={len(sessions)} expected={clients}')
    if not isinstance(totals, dict):
        failures.append('totals must be an object')
        totals = {}
    fields = set(ADAPTER_COUNTERS) | set(totals)
    for session in sessions:
        if isinstance(session, dict):
            fields.update(session)
    valid = []
    for label, counters in [('totals', totals)] + [(f'session{i}', s) for i, s in enumerate(sessions)]:
        if not isinstance(counters, dict):
            failures.append(f'{label} must be an object')
            valid.append(False)
            continue
        typed = all([integer(counters.get(name), f'{label}.{name}') for name in sorted(fields)])
        valid.append(typed)
        if not typed:
            continue
        for name in ZERO_ADAPTER_COUNTERS:
            if counters[name] != 0:
                failures.append(f'{label}.{name}={counters[name]}')
        for name in ('accepted_packets', 'forwarded_packets', 'sealed_packets', 'returned_packets'):
            if counters[name] <= 0:
                failures.append(f'{label}.{name} not positive')
        for left, right in (
                ('transport_packets', ('accepted_packets', 'rejected_packets')),
                ('rejected_no_forward', ('rejected_packets',)),
                ('accepted_packets', ('forwarded_packets',)),
                ('raw_packets', ('sealed_packets', 'raw_oversize', 'seal_rejected')),
                ('sealed_packets', ('returned_packets',))):
            if counters[left] != sum(counters[name] for name in right):
                failures.append(f'{label}.{left} ledger mismatch')
    if valid and all(valid):
        for name in totals:
            if totals[name] != sum(session[name] for session in sessions):
                failures.append(f'totals.{name} does not equal session sum')
    return failures


def summarize_echo_stability(echo):
    """可靠 echo RTT 的观察统计，不代表 HUD/输入延迟；诊断桶不是用户 SLA。"""
    raw = echo.get('raw', [])
    samples, replies, sequences = [], [], []
    for item in raw:
        seq, stamp, rtt = item['seq'], item['sent_usec'], item['rtt_ms']
        if (type(seq) is not int or seq < 0 or type(stamp) is not int or stamp < 0
                or type(rtt) not in (int, float) or not math.isfinite(rtt) or rtt < 0):
            raise ValueError('invalid reliable echo sample')
        samples.append(rtt)
        replies.append(stamp + rtt * 1000)
        sequences.append(seq)
    samples.sort()
    replies.sort()
    count = len(samples)
    expected = echo.get('count')
    missing = set(echo.get('missing', []))
    if type(expected) is int and expected >= 0:
        missing.update(set(range(expected)) - set(sequences))
    spread = (samples[math.ceil(count * .95) - 1] - samples[math.ceil(count * .50) - 1]) if count else None
    return {'count': count, 'max_ms': max(samples) if count else None,
            'p95_minus_p50_ms': spread,
            **{f'above_{limit}ms': sum(value > limit for value in samples) for limit in (100, 250, 1000)},
            'max_reply_gap_ms': max(((b - a) / 1000 for a, b in zip(replies, replies[1:])), default=None),
            'missing': sorted(missing),
            'duplicates': max(echo.get('duplicates', 0), count - len(set(sequences))),
            'measurement': 'reliable_echo_rtt_not_hud_or_input_latency',
            'diagnostic_buckets_are_sla': False,
            'stability_evaluated_as': 'observational_no_latency_budget'}


def run_case(index, profile, clients, count, seed, output, adapter_mode='node', delay_ms=4, fps=60, godot=None):
    host_port = 28160 + index
    children = {}
    result = {'profile': profile, 'seed': seed, 'clients': clients, 'count': count,
              'adapter': adapter_mode, 'delay_ms': delay_ms, 'fps': fps,
              'reliability_ok': False, 'ok': False,
              'stability_evaluated_as': 'observational_no_latency_budget',
              'scope': 'localhost real ENet/World through authenticated UDP carrier; no public path'}
    try:
        # Each Godot child gets its own log; concurrent default user:// log rotation can collide.
        def engine_command(role):
            log = output.parent / f'{output.stem}_{index}_{profile}_{role}_engine.log'
            return [godot or ENGINE, '--headless', '--path', str(ROOT), '--log-file', str(log),
                    '--script', 'res://tools/network_udp_game_probe.gd', '--']
        host = Child(engine_command('host') + [f'--udp-lab-role=host', f'--udp-lab-port={host_port}',
            f'--udp-lab-clients={clients}', f'--udp-lab-count={count}', f'--udp-lab-fps={fps}'], 'UDP_GAME_HOST_READY')
        children['host'] = host
        host.ready(15)
        loss = {'clean': 0, 'loss1': 0.01, 'loss5': 0.05, 'outage': 0.01}[profile]
        bridge_args = ['node', str(ROOT / 'tools/network_udp_enet_proxy.mjs'),
            f'--host-port={host_port}', f'--clients={clients}', f'--seed={seed}', f'--loss={loss}',
            f'--delay-ms={delay_ms}', '--jitter-ms=' + ('0' if profile == 'clean' else '10'),
            '--duplicate=' + ('0' if profile == 'clean' else '0.02')]
        if adapter_mode == 'godot':
            bridge_args += ['--external-host=1']
        bridge = Child(bridge_args, 'UDP_LAB_READY ', stdin=True)
        children['bridge'] = bridge
        endpoint = bridge.ready(10)
        adapter, adapter_ready, adapter_token = (None, None, None)
        if adapter_mode == 'godot':
            adapter, adapter_ready, adapter_token = start_godot_adapter(
                bridge, children, output, f'{index}_{profile}_adapter', godot=godot)
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
                f'--udp-lab-count={count}', f'--udp-lab-fps={fps}'], 'UDP_GAME_CLIENT_RESULT ')
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
        for client in result['client_results']:
            summary = summarize_echo_stability(client.get('echo', {}))
            observation = client.get('stability_observation', client.get('echo', {}).get('stability_observation'))
            if observation is not None:
                summary['stability_observation'] = observation
            client['stability_summary'] = summary
        result['bridge'] = parse_result(bridge, 'UDP_LAB_FINAL ')
        result['child_failures'] = {name: list(child.failures) for name, child in children.items() if child.failures}
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
        result['ok'] = (result['ok'] and not result['engine_runtime_errors'] and not result['child_failures']
            and all(c['stability_summary']['count'] == count
                and not c['stability_summary']['missing'] and c['stability_summary']['duplicates'] == 0
                for c in result['client_results']))
        if adapter_mode == 'godot':
            adapter_failures = check_godot_adapter(result['godot_adapter'], clients)
            result['godot_adapter_gate'] = adapter_failures
            result['ok'] = result['ok'] and not adapter_failures
        result['reliability_ok'] = bool(result['ok'])
        print(json.dumps({'profile': profile, 'seed': seed, 'ok': result['ok'],
            'reliability_ok': result['reliability_ok'],
            'stability_evaluated_as': result['stability_evaluated_as'],
            'host_checks': result['host'].get('checks'), 'host_failures': result['host'].get('failures'),
            'clients': [{'index': c.get('index'), 'checks': c.get('checks'), 'failures': c.get('failures'),
                'stability_summary': c['stability_summary'],
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
    parser.add_argument('--godot', help='Godot 可执行文件；也可通过 GODOT_BIN/GODOT 或 PATH 指定')
    parser.add_argument('--profiles', nargs='+', choices=['clean', 'loss1', 'loss5', 'outage'], default=['clean', 'loss1', 'loss5', 'outage'])
    parser.add_argument('--clients', type=int, choices=[1, 2, 3], default=2)
    parser.add_argument('--adapter', choices=['node', 'godot'], default='node')
    parser.add_argument('--count', type=int, default=150)
    parser.add_argument('--delay-ms', type=int, default=4)
    parser.add_argument('--fps', type=int, default=60)
    parser.add_argument('--seed', type=int, default=31)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    if not 20 <= args.count <= 300:
        parser.error('count must be 20..300')
    if not 0 <= args.delay_ms <= 50:
        parser.error('delay-ms must be 0..50')
    if not 30 <= args.fps <= 240:
        parser.error('fps must be 30..240')
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in args.label):
        parser.error('label must be a simple ASCII identifier')
    try:
        godot = resolve_godot(args.godot)
    except ValueError as exc:
        parser.error(str(exc))
    output = ROOT / '.workbuddy/tmp' / f'network_udp_lab_{args.label}.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() or any(output.parent.glob(f'{output.stem}_*')):
        parser.error('label already has evidence; choose a new label')
    config = ROOT / 'config.json'
    before = read_optional_config(config)
    cases, error = [], None
    try:
        for index, profile in enumerate(args.profiles):
            cases.append(run_case(index, profile, args.clients, args.count, args.seed, output,
                args.adapter, args.delay_ms, args.fps, godot=godot))
    except Exception as exc:
        error = repr(exc)
        raise
    finally:
        config_status = restore_config(config, before)
        result = {'cases': cases, 'error': error, **config_status,
            'public_server_modified': False, 'tcp_lower_layer_comparison': False}
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'UDP_GAME_OUTPUT {output}; config_preserved={result["config_preserved"]}', flush=True)
        if not config_status['config_unchanged_during_run']:
            raise RuntimeError('test modified config; original restored, run rejected')


if __name__ == '__main__':
    main()
