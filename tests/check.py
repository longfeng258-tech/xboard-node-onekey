"""One offline regression check: parser, memory limits, auth and service rendering.

Run on Linux: python3 tests/check.py. No root, account or network needed.
Optional XBOARD_TEST_BINARIES points at verified official amd64 binaries.
"""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import pty
from pathlib import Path
import shlex
import select
import subprocess
import socket
import socketserver
import ssl
import tempfile
import threading
import time
import uuid

SCRIPT = Path(__file__).resolve().parents[1] / 'install.sh'
SHELL = shlex.split(os.environ.get('TEST_SHELL', 'sh'))
BASE = f'XBOARD_INSTALL_LIBRARY=1; . {shlex.quote(str(SCRIPT))}; '
COMMAND = (
    "curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh "
    "| sudo bash -s -- --mode machine --panel 'https://panel.example.com/' "
    "--token 'example-machine-token' --machine-id 8"
)


def run(code, stdin='', success=True):
    p = subprocess.run(SHELL + ['-c', BASE + code], input=stdin, text=True,
                       capture_output=True, timeout=20)
    if success:
        assert p.returncode == 0, (code, p.stdout, p.stderr)
    else:
        assert p.returncode != 0, (code, p.stdout, p.stderr)
    return p


assert run('parse_command', COMMAND + '\n').stdout.splitlines() == [
    'https://panel.example.com', 'example-machine-token', '8']
assert run('parse_command', COMMAND.replace('| sudo', '|').replace("'", '"') + '\n').returncode == 0
assert run('parse_command', COMMAND.replace('--machine-id 8', '--machine-id 42').replace(' --mode', '\t--mode') + '\n').stdout.endswith('42\n')
installer_url = 'https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh'
for copied in [
    COMMAND.replace(installer_url, f'[{installer_url}]({installer_url})'),
    COMMAND.replace('https://panel.example.com/',
                    '[https://panel.example.com/](https://panel.example.com/)'),
    COMMAND.replace(' ', '\u00a0'),
]:
    assert run('parse_command', copied + '\n').stdout.splitlines() == [
        'https://panel.example.com', 'example-machine-token', '8']
for attack in [
    COMMAND + '; touch /tmp/must-not-exist',
    COMMAND + ' && false', COMMAND + ' | sh', COMMAND + ' --kernel xray',
    COMMAND + ' --token duplicate', COMMAND + '\n' + COMMAND,
    COMMAND.replace('example-machine-token', '$(touch /tmp/must-not-exist)'),
    COMMAND.replace('example-machine-token', '`id`'),
    COMMAND.replace('example-machine-token', 'x\\y'),
    COMMAND.replace('example-machine-token', "x' --machine-id 99 '"),
    COMMAND.replace('--machine-id 8', '--machine-id'),
    COMMAND.replace('--machine-id 8', '--machine-id 0'),
    COMMAND.replace('--machine-id 8', '--machine-id 99999999999'),
    COMMAND.replace('--mode machine', '--mode node'),
    COMMAND.replace('--token ', '--other '),
    COMMAND.replace('https://panel.example.com/', 'http://panel.example.com/'),
    COMMAND.replace('https://panel.example.com/', 'https://user@panel.example.com/'),
    COMMAND.replace('https://panel.example.com/', 'https://panel.example.com/?x=1'),
    COMMAND.replace('https://panel.example.com/', 'https://panel.example.com:99999/'),
    COMMAND.replace('cedar2025/xboard-node', 'attacker/xboard-node'),
    COMMAND.replace(installer_url, f'[{installer_url}](https://attacker.example/install.sh)'),
    COMMAND.replace('https://panel.example.com/',
                    '[https://panel.example.com/](https://attacker.example/)'),
    COMMAND.replace('https://panel.example.com/', '[panel](https://panel.example.com/)'),
    COMMAND[:-1] + "'", 'x' * 8193, '',
]:
    p = run('parse_command', attack + '\n', success=False)
    assert not p.stdout, 'rejected command must not emit private fields'

# Paste immediately after the prompt, including queued retries, to catch leaks.
for pasted_command, valid, options, kernel in [
    (COMMAND, True, '1\n2\n00000028\n', 'singbox'),
    ('invalid example-machine-token\n' + COMMAND.replace(
        installer_url, f'[{installer_url}]({installer_url})'), True, '\n\n', 'singbox'),
    ('invalid example-machine-token\n' * 2 + 'invalid example-machine-token', False, '', ''),
    # Mistyped menu choices and budgets must retry without reimporting credentials.
    (COMMAND, True, '9\n2\nbad\n2\nnope\n15\n33\n999999999\n28\n', 'xray'),
    (COMMAND, True, '\n2\n\n', 'singbox'),
]:
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp(SHELL[0], SHELL + ['-c', BASE +
                  'trap cleanup EXIT; MEMORY=64; read_private_command </dev/null; choose_options </dev/null; '
                  'printf "PRIVATE_OK:%s:%s:%s\\n" "$MACHINE_ID" "$BUDGET" "$KERNEL"'])
    output = b''
    sent = False
    deadline = time.monotonic() + 10
    try:
        while True:
            assert time.monotonic() < deadline, output
            readable, _, _ = select.select([terminal], [], [], 0.2)
            if not readable:
                continue
            try:
                chunk = os.read(terminal, 8192)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if not sent and '输入隐藏'.encode() in output:
                os.write(terminal, (pasted_command + '\n' + options).encode())
                sent = True
        _, status = os.waitpid(pid, 0)
        if valid:
            assert status == 0 and f'PRIVATE_OK:8:28:{kernel}'.encode() in output, output
        else:
            assert status != 0 and '连续三次输入无效'.encode() in output, output
        assert b'example-machine-token' not in output, 'terminal echoed private command'
    finally:
        os.close(terminal)

# EOF still exits: input retry must not spin forever after a disconnected terminal.
p = run('MEMORY=64; exec 3>&1; read() { return 1; }; choose_options', success=False)
assert '输入中断' in p.stderr

with tempfile.TemporaryDirectory(prefix='xboard-check-') as temp:
    root = Path(temp)
    # Run the documented entry: neither empty nor partial failed downloads execute.
    entry = (SCRIPT.parent / 'README.md').read_text().split('```sh\n', 1)[1].split('```', 1)[0]
    for curl_exit in (0, 22, 28):
        entry_dir = root / f'entry-{curl_exit}'
        entry_dir.mkdir()
        marker = entry_dir / 'executed'
        setup = (f'TMPDIR={shlex.quote(str(entry_dir))}; export TMPDIR; '
                 'curl() { while [ "$1" != -o ]; do shift; done; shift; '
                 f'if [ {curl_exit} != 22 ]; then '
                 f'printf \'touch "%s"\\n\' {shlex.quote(str(marker))} >"$1"; '
                 'else : >"$1"; fi; '
                 f'return {curl_exit}; }}; ')
        run(setup + entry, success=curl_exit == 0)
        assert marker.exists() == (curl_exit == 0)
        assert set(entry_dir.iterdir()) == ({marker} if curl_exit == 0 else set())

    proc = root / 'proc'
    (proc / 'self').mkdir(parents=True)
    cg = root / 'cg'
    leaf = cg / 'slice' / 'child'
    leaf.mkdir(parents=True)
    (proc / 'meminfo').write_text('MemTotal: 2048000 kB\n')
    (proc / 'self/cgroup').write_text('0::/slice/child\n')
    (proc / 'self/mountinfo').write_text(f'29 23 0:26 / {cg} rw - cgroup2 cgroup rw\n')
    (cg / 'memory.max').write_text('max\n')
    (cg / 'slice/memory.max').write_text('67108864\n')
    (leaf / 'memory.max').write_text('max\n')
    assert run(f'effective_memory {shlex.quote(str(proc))}').stdout.strip() == '64'
    (leaf / 'memory.max').write_text('128000000\n')
    assert run(f'effective_memory {shlex.quote(str(proc))}').stdout.strip() == '64'
    (cg / 'slice/memory.max').write_text('max\n')
    assert run(f'effective_memory {shlex.quote(str(proc))}').stdout.strip() == '122'
    # cgroup namespace can expose an ancestor limit only at its mount root.
    (proc / 'self/cgroup').write_text('0::/../hidden\n')
    (cg / 'memory.max').write_text('67108864\n')
    assert run(f'effective_memory {shlex.quote(str(proc))}').stdout.strip() == '64'
    # v1 unlimited sentinel must not masquerade as actual host RAM.
    (proc / 'self/cgroup').write_text('3:memory:/slice/child\n')
    (proc / 'self/mountinfo').write_text(f'29 23 0:26 / {cg} rw - cgroup cgroup rw,memory\n')
    (cg / 'memory.limit_in_bytes').write_text('9223372036854771712\n')
    (leaf / 'memory.limit_in_bytes').write_text('128000000\n')
    assert run(f'effective_memory {shlex.quote(str(proc))}').stdout.strip() == '122'
    for memory, expected in [(64, 28), (122, 48), (256, 102), (1024, 409)]:
        assert run(f'recommended_budget {memory}').stdout.strip() == str(expected)

    # Private JSON auth is stdin; curl argv never receives the token or redirects.
    stage = root / 'stage'
    stage.mkdir()
    # Minimal Alpine images can have crond but no OpenRC service for it.
    mockbin = root / 'mockbin'
    mockbin.mkdir()
    (mockbin / 'rc-service').write_text('#!/bin/sh\ntest -e "$STAGE/cron-ready"\n')
    (mockbin / 'apk').write_text(
        '#!/bin/sh\nprintf "%s\\n" "$@" >"$STAGE/apk-argv"\n: >"$STAGE/cron-ready"\n')
    for path in mockbin.iterdir():
        path.chmod(0o755)
    dependency_probe = (f'STAGE={shlex.quote(str(stage))}; export STAGE; INIT=openrc; '
                        f'PATH={shlex.quote(str(mockbin))}:$PATH; '
                        'command() { return 0; }; install_dependencies')
    run(dependency_probe)
    assert 'busybox-openrc' in (stage / 'apk-argv').read_text().splitlines()
    (mockbin / 'rc-update').write_text('#!/bin/sh\nexit 0\n')
    (mockbin / 'rc-update').chmod(0o755)
    (mockbin / 'rc-service').write_text('#!/bin/sh\nexit 1\n')
    p = run(f'PATH={shlex.quote(str(mockbin))}:$PATH; '
            f'LOCK={shlex.quote(str(root / "cron-lock"))}; '
            f'mktemp() {{ case "$1" in -d) echo {shlex.quote(str(stage))};; '
            f'*) touch {shlex.quote(str(root / "cron-diagnostic"))}; echo {shlex.quote(str(root / "cron-diagnostic"))};; esac; }}; '
            'id() { echo 0; }; check_existing() { return 1; }; '
            'detect_platform() { INIT=openrc; }; read_private_command() { :; }; '
            'choose_options() { :; }; install_dependencies() { :; }; '
            'check_panel() { NODE_COUNT=0; }; '
            f'download_binaries() {{ touch {shlex.quote(str(root / "download-called"))}; }}; main',
            success=False)
    assert 'OpenRC crond 服务无法启动' in p.stderr
    assert not (root / 'download-called').exists()
    assert not (root / 'cron-lock').exists()

    # Exercise main end-to-end: a stripped Alpine image must recover its packaged
    # hostname service, reach completion, and explain otherwise silent failures.
    flowbin = root / 'flowbin'
    flowbin.mkdir()
    (flowbin / 'rc-service').write_text('''#!/bin/sh
case "$*" in
  '--exists hostname') test -e "$FLOW/hostname-ready";;
  '--exists crond') exit 0;;
  'crond start') test -e "$FLOW/hostname-ready" && test "$FLOW_MODE" != cron-fail;;
  *) exit 0;;
esac
''')
    (flowbin / 'rc-update').write_text('#!/bin/sh\nexit 0\n')
    (flowbin / 'apk').write_text('''#!/bin/sh
case "$*" in
  'info -L openrc') test "$FLOW_MODE" = unknown-owner || echo etc/init.d/hostname;;
  'fix --no-cache openrc')
    echo repair >>"$FLOW/repairs"
    test "$FLOW_MODE" = repair-fail || : >"$FLOW/hostname-ready";;
  *) exit 0;;
esac
''')
    for path in flowbin.iterdir():
        path.chmod(0o755)
    for mode in ('repair', 'healthy', 'repair-fail', 'unknown-owner', 'cron-fail', 'unexpected'):
        flow = root / mode
        flow.mkdir()
        if mode in ('healthy', 'cron-fail', 'unexpected'):
            (flow / 'hostname-ready').touch()
        fields = dict(FLOW=flow, FLOW_MODE=mode, LOCK=flow / 'lock',
                      BIN_DIR=flow / 'bin', CONFIG_DIR=flow / 'config', LOG_DIR=flow / 'logs')
        code = '; '.join(f'{key}={shlex.quote(str(value))}' for key, value in fields.items()) + '; '
        code += (f'export FLOW FLOW_MODE; PATH={shlex.quote(str(flowbin))}:$PATH; '
                 'id() { echo 0; }; check_existing() { return 1; }; '
                 'detect_platform() { INIT=openrc; ARCH=arm64; }; read_private_command() { TOKEN=example-machine-token; }; '
                 'choose_options() { KERNEL=singbox; }; install_dependencies() { :; }; '
                 'check_panel() { NODE_COUNT=0; }; '
                 'mktemp() { case "$1" in -d) mkdir "$FLOW/stage"; echo "$FLOW/stage";; '
                 '*) : >"$FLOW/diagnostic.log"; echo "$FLOW/diagnostic.log";; esac; }; '
                 'download_binaries() { test "$FLOW_MODE" != unexpected; '
                 'mkdir "$STAGE/bin" "$STAGE/config"; }; '
                 'generate_config() { :; }; write_services() { mkdir "$LOG_DIR"; }; '
                 'start_services() { :; }; main')
        valid = mode in ('repair', 'healthy')
        p = run(code, success=valid)
        output = p.stdout + p.stderr
        if valid:
            assert '安装完成' in output and '无需重装' in output, output
            assert not (flow / 'diagnostic.log').exists()
        else:
            assert '失败阶段' in output and '退出码' in output, output
            assert (flow / 'diagnostic.log').stat().st_mode & 0o777 == 0o600
            if mode == 'unexpected':
                assert '意外停止' in output and '下载' in output, output
        assert (flow / 'repairs').exists() == (mode in ('repair', 'repair-fail'))
        assert not (flow / 'lock').exists()
        assert 'example-machine-token' not in output

    common = f'STAGE={shlex.quote(str(stage))}; PANEL=https://panel.example.com; TOKEN=example-machine-token; MACHINE_ID=8; '
    fake_curl = '''curl() {
        printf '%s\\n' "$@" >"$STAGE/argv";
        cat >"$STAGE/body";
        printf '%s' "$response" >"$STAGE/panel.json";
        printf '%s' "$http_status";
    }; '''
    for response, http_status, valid in [
        ('{"nodes":[]}', '200', True),
        ('{"nodes":[{"id":1,"type":"vless"}]}', '200', True),
        ('<html>login</html>', '200', False),
        ('{"data":{"nodes":[]}}', '200', False),
        ('{"nodes":[]}', '401', False),
        ('{"nodes":[]}', '302', False),
        ('{"nodes":[{"id":0,"type":"vless"}]}', '200', False),
    ]:
        code = common + fake_curl + f'response={shlex.quote(response)}; http_status={http_status}; check_panel'
        p = run(code, success=valid)
        assert 'example-machine-token' not in (stage / 'argv').read_text()
        assert '--location' not in (stage / 'argv').read_text()
        assert 'example-machine-token' not in p.stdout + p.stderr
        assert (stage / 'body').read_text() == '{"machine_id":8,"token":"example-machine-token"}'

    # Errors are actionable fixed text; never echo a panel-supplied message.
    for response, http_status, curl_exit, expected in [
        ('{"message":"Machine not found or disabled"}', '403', 0, '机器不存在或已停用'),
        ('{"message":"example-machine-token https://panel.example.com"}', '403', 0, '接入被拒绝'),
        ('{}', '401', 0, '鉴权未通过'),
        ('{}', '404', 0, '找不到机器 API'),
        ('<html>login</html>', '302', 0, '重定向'),
        ('{}', '429', 0, '请求过于频繁'),
        ('{}', '503', 0, '面板或代理服务异常'),
        ('<html>login example-machine-token</html>', '200', 0, '返回格式不符'),
        ('{}', '000', 6, 'DNS'),
        ('{}', '000', 7, '无法连接'),
        ('{}', '000', 28, '超时'),
        ('{}', '000', 60, 'TLS'),
        ('{}', '000', 63, '响应超过'),
        ('{}', '000', 52, '网络请求失败'),
    ]:
        code = common + fake_curl.replace('printf \'%s\' "$http_status";',
                                          f'printf \'%s\' "$http_status"; return {curl_exit};')
        code += (f'response={shlex.quote(response)}; http_status={http_status}; '
                 'if check_panel; then exit 99; fi; printf "%s\\n" "$PANEL_ERROR"; '
                 'test ! -e "$STAGE/panel.json"')
        p = run(code)
        assert expected in p.stdout, p.stdout
        assert 'example-machine-token' not in p.stdout + p.stderr
        assert 'https://panel.example.com' not in p.stdout + p.stderr

    # Config generation errors belong in the private diagnostic, not the terminal.
    config_stage = root / 'config-failure'
    (config_stage / 'bin').mkdir(parents=True)
    (config_stage / 'config').mkdir()
    ctl = config_stage / 'bin/xbctl'
    ctl.write_text('#!/bin/sh\necho "example-machine-token private config error" >&2\nexit 1\n')
    ctl.chmod(0o755)
    diagnostic = root / 'config-diagnostic'
    p = run(common + f'STAGE={shlex.quote(str(config_stage))}; '
            f'DIAG_LOG={shlex.quote(str(diagnostic))}; '
            'KERNEL=singbox; BUDGET=28; GOGC=50; generate_config', success=False)
    assert '官方配置生成失败' in p.stderr
    assert 'example-machine-token' not in p.stdout + p.stderr
    assert diagnostic.read_text() == 'example-machine-token private config error\n'
    assert diagnostic.stat().st_mode & 0o777 == 0o600

    # A stalled/failed download must stop before checking or running the binary.
    download_stage = root / 'download-failure'
    download_stage.mkdir()
    p = run(f'STAGE={shlex.quote(str(download_stage))}; ARCH=amd64; '
            'curl() { return 28; }; '
            'sha256sum() { echo must-not-reach-check; return 0; }; '
            'download_binaries', success=False)
    assert '官方二进制下载失败' in p.stderr
    assert 'must-not-reach-check' not in p.stdout + p.stderr

    def service_setup(init):
        for name in ('log', 'config'):
            (root / name).mkdir(exist_ok=True)
        assignments = dict(
            INIT=init, MEMORY=64, BUDGET=28, STAGE=stage,
            BIN_DIR=root / 'bin', CONFIG_DIR=root / 'config', LOG_DIR=root / 'log',
            ROTATE_CONFIG=root / 'rotate.conf', UNIT=root / 'node.service',
            ROTATE_UNIT=root / 'rotate.service', ROTATE_TIMER=root / 'rotate.timer',
            RC_UNIT=root / 'rc-node', RC_ROTATE=root / 'rc-rotate',
        )
        return '; '.join(f'{k}={shlex.quote(str(v))}' for k, v in assignments.items()) + '; '

    run(service_setup('systemd') + 'mkdir() { :; }; write_services')
    unit = (root / 'node.service').read_text()
    assert 'MemoryHigh=40M' in unit and 'MemoryMax=48M' in unit
    assert 'RestartSec=5' in unit and 'StartLimitBurst=3' in unit
    assert 'credentials.env' in unit and 'example-machine-token' not in unit
    assert 'StandardOutput=append:' in unit
    assert (root / 'log/node.log').stat().st_mode & 0o777 == 0o600
    rotate = (root / 'rotate.conf').read_text()
    assert 'rotate 2' in rotate and 'size 1M' in rotate
    run(service_setup('openrc') + 'mkdir() { :; }; write_services')
    rc = (root / 'rc-node').read_text()
    assert 'supervise-daemon' in rc and 'respawn_max=3' in rc
    assert 'set -a' in rc and '/dev/null' not in rc
    subprocess.run(SHELL + ['-n', str(root / 'rc-node')], check=True)
    assert run(service_setup('systemd') + 'check_existing').returncode == 0

    stable_systemd = 'systemctl() { case "$1" in show) echo $$;; *) return 0;; esac; }; sleep() { :; }; '
    run(service_setup('systemd') + stable_systemd + 'start_services')
    run(service_setup('systemd') + 'systemctl() { case "$1" in show) echo 0;; *) return 0;; esac; }; start_services', success=False)
    mocks = root / 'mocks'
    mocks.mkdir()
    for name in ('rc-service', 'rc-update'):
        mock = mocks / name
        mock.write_text('#!/bin/sh\nexit 0\n')
        mock.chmod(0o755)
    mock_path = f'PATH={shlex.quote(str(mocks))}:$PATH; '
    run(service_setup('openrc') + mock_path + 'pidof() { echo $$; }; sleep() { :; }; start_services')
    # Two PIDs / a respawning child must not count as a stable OpenRC Node.
    run(service_setup('openrc') + mock_path + 'pidof() { echo "1 2"; }; start_services', success=False)

    # Installer lock rejects concurrent runs before OS detection or prompting.
    lock = root / 'locked'
    lock.mkdir()
    p = run(f'LOCK={shlex.quote(str(lock))}; id() {{ echo 0; }}; check_existing() {{ return 1; }}; main', success=False)
    assert '另一个安装' in p.stderr and lock.exists()

    # Failed-first-install cleanup is scoped to freshly owned files.
    preserve = root / 'unrelated'
    preserve.write_text('keep')
    (root / 'log/node.log').write_text('x' * 70000 + '\nexample-machine-token private startup failure\n')
    diagnostic = root / 'retained-diagnostic'
    p = run(service_setup('systemd') + f'LOCK={shlex.quote(str(lock))}; LOCKED=1; OWNED=1; '
            f'DIAG_LOG={shlex.quote(str(diagnostic))}; : >"$DIAG_LOG"; '
            'systemctl() { :; }; cleanup', success=False)
    assert preserve.read_text() == 'keep'
    assert not (root / 'config').exists() and not lock.exists()
    assert diagnostic.stat().st_mode & 0o777 == 0o600
    assert diagnostic.stat().st_size == 65536
    assert diagnostic.read_text().endswith('private startup failure\n')
    assert 'example-machine-token' not in p.stdout + p.stderr

    # Real pinned xbctl + Node smoke check is optional and stays in this temp tree.
    binaries = os.environ.get('XBOARD_TEST_BINARIES')
    if binaries:
        binaries = Path(binaries)
        digests = {
            'xbctl': '8ec7b9bbf0abb99a9c24b1b3ceef1ed5496f458e7dc22b09c33b098d5b2aad9e',
            'xboard-node': '55bf71fa9d9f2048d3255ae7c0af929a41897ca7743f6ead34132a6ca4c79043',
        }
        for name, digest in digests.items():
            assert hashlib.file_digest((binaries / name).open('rb'), 'sha256').hexdigest() == digest
        (stage / 'config').mkdir()
        (stage / 'bin').symlink_to(binaries, target_is_directory=True)
        for kernel in ('singbox', 'xray'):
            run(common + f'CONFIG_DIR={shlex.quote(str(root / "final-config"))}; KERNEL={kernel}; BUDGET=28; GOGC=50; generate_config')
            config = (stage / 'config/config.yml').read_text()
            assert 'gomemlimit: 28MiB' in config and 'gogc: 50' in config
            assert 'level: warn' in config and 'level: info' not in config
            assert 'example-machine-token' not in config and 'token_env: INSTANCE_' in config
            assert f'type: {kernel}' in config
            assert 'health_port: 0' in config or 'health_port:' not in config
            env_file = stage / 'config/credentials.env'
            assert env_file.stat().st_mode & 0o777 == 0o600
        p = subprocess.run([str(binaries / 'xboard-node'), '-v'], capture_output=True, text=True, check=True)
        assert 'v1.13' in p.stdout
        # Real Node talks to a local HTTPS mock panel. No real account or server.
        cert = root / 'cert.pem'
        key = root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                       check=True, capture_output=True)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            node_port = s.getsockname()[1]
        requests = []

        class Panel(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, data):
                body = json.dumps(data).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert body['machine_id'] == 8 and body['token'] == 'example-machine-token'
                requests.append(self.path)
                if self.path.endswith('/machine/nodes'):
                    self.reply({'nodes': [{'id': 1, 'type': 'vless', 'name': 'example'}],
                                'base_config': {'push_interval': 60, 'pull_interval': 60}})
                elif self.path.endswith('/handshake'):
                    self.reply({'websocket': {'enabled': False}})
                else:
                    self.reply({})

            def do_GET(self):
                requests.append(self.path.split('?')[0])
                if self.path.split('?')[0].endswith('/config'):
                    self.reply({'protocol': 'vless', 'listen_ip': '127.0.0.1',
                                'server_port': node_port, 'network': 'tcp', 'tls': 0,
                                # Upstream blocks private destinations by default;
                                # only this isolated echo target is allowed in the mock.
                                'custom_route_rules': [{
                                    'name': 'local-test-only',
                                    'match': {'ip_cidrs': ['127.0.0.1/32'],
                                              'ports': [str(echo.server_address[1])]},
                                    'action': {'type': 'direct'}}],
                                'base_config': {'push_interval': 60, 'pull_interval': 60}})
                else:
                    self.reply({'users': [{'id': 1, 'uuid': '00000000-0000-4000-8000-000000000001',
                                           'speed_limit': 0, 'device_limit': 0}]})

        server = ThreadingHTTPServer(('127.0.0.1', 0), Panel)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.sendall(self.request.recv(128))

        echo = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Echo)
        threading.Thread(target=echo.serve_forever, daemon=True).start()
        try:
            for kernel in ('singbox', 'xray'):
                run(f'STAGE={shlex.quote(str(stage))}; CONFIG_DIR={shlex.quote(str(root / "final-config"))}; '
                    f'PANEL=https://localhost:{server.server_port}; TOKEN=example-machine-token; MACHINE_ID=8; '
                    f'KERNEL={kernel}; BUDGET=28; GOGC=50; generate_config')
                env_key, value = env_file.read_text().strip().split('=', 1)
                env = dict(os.environ, SSL_CERT_FILE=str(cert))
                env[env_key] = value.strip("'")
                with (root / 'runtime.log').open('w') as log:
                    process = subprocess.Popen([str(binaries / 'xboard-node'), '-c', str(stage / 'config/config.yml')],
                                               env=env, stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 10
                        while True:
                            assert process.poll() is None, (root / 'runtime.log').read_text()
                            try:
                                with socket.create_connection(('127.0.0.1', node_port), timeout=0.2):
                                    break
                            except OSError:
                                assert time.monotonic() < deadline, (root / 'runtime.log').read_text()
                                time.sleep(0.1)
                        assert '/api/v2/server/machine/nodes' in requests
                        assert '/api/v2/server/config' in requests and '/api/v2/server/user' in requests
                        # VLESS TCP request to an isolated loopback echo target.
                        with socket.create_connection(('127.0.0.1', node_port), timeout=3) as client:
                            message = b'installer-check'
                            header = (b'\x00' + uuid.UUID('00000000-0000-4000-8000-000000000001').bytes +
                                      b'\x00\x01' + echo.server_address[1].to_bytes(2, 'big') +
                                      b'\x01' + socket.inet_aton('127.0.0.1'))
                            client.sendall(header + message)
                            stream = client.makefile('rb')
                            try:
                                assert stream.read(2) == b'\x00\x00'
                                assert stream.read(len(message)) == message
                            except (OSError, AssertionError) as error:
                                raise AssertionError((kernel, (root / 'runtime.log').read_text())) from error
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                requests.clear()
        finally:
            server.shutdown()
            server.server_close()
            echo.shutdown()
            echo.server_close()
        print('PASS: verified official binaries; both kernels authenticated to local HTTPS panel and relayed VLESS TCP')

print('PASS: command import, injection rejection, cgroup limits, private auth, service generation, lock and first-install cleanup')
