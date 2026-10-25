#!/usr/bin/env python3
"""Read/control smoke test against the installed, original Pi. No provider calls."""
import json, os, pathlib, queue, shutil, subprocess, tempfile, threading, time, uuid

pi = shutil.which('pi')
assert pi, 'Install original Pi CLI first'
with tempfile.TemporaryDirectory(prefix='pi-desktop-smoke-') as directory:
    root = pathlib.Path(directory)
    project = root / 'project with spaces'
    project.mkdir()
    agent = root / 'agent'
    agent.mkdir()
    sessions = root / 'sessions'
    sessions.mkdir()
    session = sessions / 'fixture.jsonl'
    timestamp = '2026-10-25T09:00:00.000Z'
    sid = str(uuid.uuid4())
    records = [
        {'type':'session','version':3,'id':sid,'timestamp':timestamp,'cwd':str(project)},
        {'type':'message','id':'usr00001','parentId':None,'timestamp':timestamp,'message':{'role':'user','content':[{'type':'text','text':'GUI and CLI native session smoke fixture'}],'timestamp':1792918800000}},
        {'type':'message','id':'ast00001','parentId':'usr00001','timestamp':timestamp,'message':{'role':'assistant','content':[{'type':'text','text':'Stored fixture, no provider request.'}],'api':'anthropic-messages','provider':'anthropic','model':'fixture','usage':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0,'totalTokens':0,'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0,'total':0}},'stopReason':'stop','timestamp':1792918800000}}
    ]
    session.write_text(''.join(json.dumps(r)+'\n' for r in records))
    extension = root / 'rpc-fixture.ts'
    extension.write_text('export default function(pi) { pi.registerCommand("desktop-ui-smoke", {description: "Test supported extension UI without a model", handler: async (_args, ctx) => { const result = await ctx.ui.confirm("Desktop smoke fixture", "Return this confirmation through native RPC"); ctx.ui.notify(result ? "fixture-confirmed" : "fixture-cancelled", "info"); }}); }')
    env = dict(os.environ, PI_CODING_AGENT_DIR=str(agent), PI_CODING_AGENT_SESSION_DIR=str(sessions))
    events = queue.Queue()
    diagnostics = []
    p = subprocess.Popen([pi,'--mode','rpc','--session',str(session),'--extension',str(extension)], cwd=project, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def drain():
        for line in p.stdout:
            try: events.put(json.loads(line))
            except json.JSONDecodeError: pass
    threading.Thread(target=drain, daemon=True).start()
    threading.Thread(target=lambda: diagnostics.append(p.stderr.read()), daemon=True).start()
    seq = 0
    def send(record):
        p.stdin.write((json.dumps(record)+'\n').encode()); p.stdin.flush()
    def request(kind, **fields):
        global seq
        seq += 1
        ident = f'test-{seq}'
        send(dict(type=kind, id=ident, **fields))
        deadline = time.monotonic()+45
        while time.monotonic()<deadline:
            record = events.get(timeout=max(.1, deadline-time.monotonic()))
            if record.get('type') == 'extension_ui_request':
                if record['method']=='confirm': send({'type':'extension_ui_response','id':record['id'],'confirmed':True})
            if record.get('id')==ident and record.get('type')=='response':
                assert record.get('success'), record.get('error')
                return record.get('data') or {}
        raise TimeoutError(kind)
    try:
        state = request('get_state')
        assert state['sessionFile'] == str(session)
        assert len(request('get_messages')['messages']) == 2
        commands = request('get_commands')['commands']
        assert any(c['name']=='desktop-ui-smoke' for c in commands)
        handled = request('prompt', message='/desktop-ui-smoke')
        assert handled.get('disposition') == 'handled'
        request('set_session_name', name='Native shared session')
        assert request('get_state')['sessionName']=='Native shared session'
        assert request('get_available_models').get('models') is not None
        # Graceful handoff: no second process is launched until the first has exited.
        p.stdin.close(); p.wait(timeout=20)
        assert p.returncode == 0
        saved = [json.loads(line) for line in session.read_text().splitlines()]
        assert any(e.get('type')=='session_info' and e.get('name')=='Native shared session' for e in saved)
        p2 = subprocess.Popen([pi,'--mode','rpc','--session',str(session)], cwd=project, env=env, stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        out, err = p2.communicate((json.dumps({'id':'resume','type':'get_state'})+'\n').encode(),timeout=30)
        resumed = [json.loads(line) for line in out.splitlines() if line.startswith(b'{')]
        result = next(r for r in resumed if r.get('id')=='resume')
        assert result['data']['sessionId']==sid
        assert result['data']['sessionName']=='Native shared session'
        print('PASS: original Pi RPC, shared JSONL resume/rename, model discovery, extension command + confirmation, graceful process handoff. No model request.')
    finally:
        if p.poll() is None: p.terminate(); p.wait(timeout=10)
