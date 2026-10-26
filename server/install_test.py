#!/usr/bin/env python3
"""Installer integration tests in an isolated filesystem with mocked OS services.
Uses a real relay binary and a pseudo-terminal; never writes actual system paths.
Usage: python3 server/install_test.py /absolute/path/to/host-native/nas-relay
"""
import json, os, pathlib, pty, select, shlex, signal, subprocess, sys, tempfile, time

BINARY = pathlib.Path(sys.argv[1]).resolve()
SOURCE = pathlib.Path(__file__).with_name('install.sh').read_text()

class Fixture:
    def __init__(self, root):
        self.root = pathlib.Path(root).resolve()
        self.bin = self.root/'mocks'; self.bin.mkdir()
        self.state = self.root/'state'
        self.pointer = self.root/'etc/nas-archive-relay/data-path'
        self.unit = self.root/'etc/systemd/system/nas-archive-relay.service'
        self.disk = self.root/'mounted disk'; self.disk.mkdir()
        for d in ['etc/systemd/system','usr/local/bin','usr/local/lib','run/lock']:
            (self.root/d).mkdir(parents=True, exist_ok=True)
        replacements = {
            '/var/lib/nas-archive-relay':str(self.state),
            '/etc/nas-archive-relay':str(self.root/'etc/nas-archive-relay'),
            '/etc/systemd/system':str(self.root/'etc/systemd/system'),
            '/usr/local/bin':str(self.root/'usr/local/bin'),
            '/usr/local/lib':str(self.root/'usr/local/lib'),
            '/run/lock':str(self.root/'run/lock'),
        }
        script=SOURCE
        for old,new in replacements.items():script=script.replace(old,new)
        script=script.replace('[[ $EUID == 0 ]]','[[ 1 == 1 ]]')
        script=script.replace('OS_ID="$(. /etc/os-release; printf %s "$ID")"','OS_ID=ubuntu')
        self.script=self.root/'install.sh';self.script.write_text(script)
        self.mock('apt-get','#!/usr/bin/env bash\nexit 0\n')
        self.mock('findmnt','#!/usr/bin/env bash\necho /\n')
        self.mock('lsblk','#!/usr/bin/env bash\nprintf "%s\\n" "$FIXTURE_DISK"\n')
        self.mock('systemctl','''#!/usr/bin/env bash
if [[ "$1" == show && -f "$FIXTURE_UNIT" ]]; then grep '^ExecStart=' "$FIXTURE_UNIT"; fi
exit 0
''')
        self.mock('realpath','#!/usr/bin/env python3\nimport os,sys\nprint(os.path.realpath(sys.argv[-1]))\n')
        self.env=dict(os.environ,PATH=str(self.bin)+os.pathsep+os.environ['PATH'],FIXTURE_DISK=str(self.disk),FIXTURE_UNIT=str(self.unit))
    def mock(self,name,text):
        p=self.bin/name;p.write_text(text);p.chmod(0o755)
    def run(self,interactive=False,answers=(),extra=()):
        args=['bash',str(self.script),'--binary',str(BINARY),'--interactive' if interactive else '--non-interactive',*extra]
        if not interactive:
            result=subprocess.run(args,env=self.env,capture_output=True,timeout=30)
            assert result.returncode==0, ('installer exit', result.returncode, result.stderr.decode()[-300:])
            return
        args=['bash','-c','cat '+shlex.quote(str(self.script))+' | bash -s -- '+shlex.join(args[2:])]
        pid,fd=pty.fork()
        if pid==0:os.execvpe(args[0],args,self.env)
        pending=list(answers);buffer=b'';end=time.monotonic()+40
        try:
            while time.monotonic()<end:
                if select.select([fd],[],[],.2)[0]:
                    try:data=os.read(fd,65536)
                    except OSError:break
                    if not data:break
                    buffer+=data
                    while pending and pending[0][0].encode() in buffer:
                        prompt,value=pending.pop(0);_,buffer=buffer.split(prompt.encode(),1)
                        os.write(fd,value.encode()+b'\n')
                found,status=os.waitpid(pid,os.WNOHANG)
                if found:
                    assert status==0,('interactive installer exit',status)
                    assert not pending,('unanswered prompts', [p for p,_ in pending])
                    return
            found,status=os.waitpid(pid,os.WNOHANG)
            if found:assert status==0 and not pending,('installer ended early',status)
            else:
                os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
                raise AssertionError(('interactive timeout', [p for p,_ in pending]))
        finally:os.close(fd)
    def config(self,path=None):return json.loads(((path or self.state)/'config.json').read_text())

with tempfile.TemporaryDirectory(prefix='relay-installer-') as folder:
    f=Fixture(folder)
    f.run(extra=('--name','Original Relay','--endpoint','https://127.0.0.1:8743'))
    before=f.config();cert=(f.state/'server.crt').read_bytes()
    (f.state/'task-canary').write_text('retain existing task data')
    f.run(interactive=True,answers=[('繼續升級','Y')])
    assert f.config()==before and (f.state/'server.crt').read_bytes()==cert
    assert (f.state/'task-canary').read_text()=='retain existing task data'
    assert f.pointer.read_text().strip()==str(f.state)
    print('PASS unattended installation and interactive upgrade preserve identity, credentials and task data')

with tempfile.TemporaryDirectory(prefix='relay-installer-') as folder:
    f=Fixture(folder);custom=f.disk/'我的 暫存'
    f.run(interactive=True,answers=[('伺服器顯示名稱','Studio Relay'),('HTTPS 服務埠號','18743'),('輸入編號或 C','C'),('資料目錄絕對路徑',str(custom)),('保留全部','C'),('其他 HTTPS 位址','https://127.0.0.1:18743'),('開始安裝','Y')])
    config=f.config(custom)
    assert config['name']=='Studio Relay' and config['endpoints']==['https://127.0.0.1:18743']
    assert f.pointer.read_text().strip()==str(custom)
    unit=f.unit.read_text();assert f'--data "{custom}"' in unit and f'ReadWritePaths="{custom}"' in unit
    before=config.copy();f.run();assert f.config(custom)==before
    print('PASS interactive custom storage with spaces/Unicode, endpoint selection, and preserved upgrade')

with tempfile.TemporaryDirectory(prefix='relay-installer-') as folder:
    f=Fixture(folder)
    f.run(interactive=True,answers=[('伺服器顯示名稱',''),('HTTPS 服務埠號',''),('輸入編號或 C','2'),('保留全部',''),('其他 HTTPS 位址',''),('開始安裝','Y')])
    data=f.disk/'nas-archive-relay';config=f.config(data)
    assert config['endpoints'] and all(ep.startswith('https://') for ep in config['endpoints'])
    assert f.pointer.read_text().strip()==str(data)
    print('PASS detected disk selection and automatic endpoint defaults')

with tempfile.TemporaryDirectory(prefix='relay-installer-') as folder:
    f=Fixture(folder);f.state.mkdir();canary=f.state/'unrelated-data';canary.write_text('do not touch')
    result=subprocess.run(['bash',str(f.script),'--binary',str(BINARY),'--non-interactive'],env=f.env,capture_output=True,timeout=30)
    assert result.returncode!=0 and canary.read_text()=='do not touch' and not(f.state/'config.json').exists()
    print('PASS unrelated nonempty storage directory is never initialized or overwritten')
