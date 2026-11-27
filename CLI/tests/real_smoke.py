#!/usr/bin/env python3
"""Real-model tests: caller supplies ZHENGXIN_MODEL_PATH / ZHENGXIN_LLAMA_SERVER.
Runs both CLI and MCP, checks non-mock translations and reaping child processes.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time
import zipfile
import xml.etree.ElementTree as ET

p=argparse.ArgumentParser();p.add_argument('--report',required=True);p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
command=a.command[1:] if a.command[:1]==['--'] else a.command
env=dict(os.environ);env.pop('ZHENGXIN_TRANSLATE_MOCK',None)
checks=[];artifacts={}
def check(ok,name):
    if not ok: raise AssertionError(name)
    checks.append(name);print('PASS',name,flush=True)
def run(*args):
    result=subprocess.run(command+list(args),capture_output=True,text=True,env=env,timeout=240)
    check(result.returncode==0,'real CLI exit: '+args[0]+': '+result.stderr[-300:]);return json.loads(result.stdout)
def translated(text):return text and '[zh-CN]' not in text and any('\u4e00'<=c<='\u9fff' for c in text)
def children(pid):
    r=subprocess.run(['ps','-axo','pid=,ppid='],capture_output=True,text=True)
    return [int(parts[0]) for line in r.stdout.splitlines() if len(parts:=line.split())==2 and int(parts[1])==pid]
def gone(pid):
    try: os.kill(pid,0);return False
    except ProcessLookupError:return True

check(run('model-status','--json')['ready'],'real model and runtime verified')
text=run('text','Hello world.','--to','zh-CN','--json')['translation'];artifacts['cli_translation']=text
check(translated(text),'real CLI produced Chinese translation')
with tempfile.TemporaryDirectory(prefix='zhengxin-real-') as tmp:
    source=Path(tmp)/'source.txt';source.write_text('Hello world.');output=Path(tmp)/'translation.docx'
    job=run('file',str(source),'--output',str(output),'--bilingual','--json')
    with zipfile.ZipFile(output) as z:text=''.join(ET.fromstring(z.read('word/document.xml')).itertext())
    check(job['status']=='completed' and 'Hello world.' in text and translated(text),'real CLI bilingual DOCX')
    proc=subprocess.Popen(command+['mcp','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
    lines=queue.Queue();errors=[]
    def reader():
        for line in proc.stdout:lines.put(line)
    threading.Thread(target=reader,daemon=True).start()
    threading.Thread(target=lambda:errors.extend(proc.stderr.readlines()),daemon=True).start()
    seq=0
    def send(method,params=None,id=None):
        request=dict(jsonrpc='2.0',method=method)
        if params is not None:request['params']=params
        if id is not None:request['id']=id
        proc.stdin.write(json.dumps(request)+'\n');proc.stdin.flush()
    def call(method,params=None):
        global seq
        seq+=1;send(method,params,seq);response=json.loads(lines.get(timeout=240));check(response['id']==seq,'real RPC correlation '+method);return response
    def tool(name,args):
        response=call('tools/call',dict(name=name,arguments=args));check(not response['result']['isError'],'real tool '+name);return json.loads(response['result']['content'][0]['text'])
    try:
        call('initialize',dict(protocolVersion='2025-11-25',capabilities={},clientInfo=dict(name='real-smoke',version='1')))
        send('notifications/initialized')
        result=tool('translate_text',dict(text='Thank you.',target='zh-CN'));artifacts['mcp_translation']=result['translation'];check(translated(result['translation']),'real MCP translation')
        child_pids=children(proc.pid);check(bool(child_pids),'MCP owns a model subprocess')
        out=Path(tmp)/'mcp.md';job=tool('submit_document',dict(input=str(source),output=str(out)))
        for _ in range(240):
            state=tool('get_job',dict(job_id=job['job_id']))
            if state['status'] in ('completed','failed','cancelled'):break
            time.sleep(.25)
        check(state['status']=='completed' and translated(out.read_text()),'real MCP document export')
        # Disconnect with an active inference; EOF cancels it and reaps its model.
        send('tools/call',dict(name='translate_text',arguments=dict(text='Please translate this sentence. '*200,target='zh-CN')),'disconnect-text')
        time.sleep(.1);proc.stdin.close();check(proc.wait(timeout=30)==0,'real MCP EOF graceful exit')
        time.sleep(.2);check(all(gone(pid) for pid in child_pids),'model subprocess reaped on EOF')
    finally:
        if proc.poll() is None:proc.terminate();proc.wait(timeout=30)
# Exercise OS signal cleanup while the model is starting or translating.
proc=subprocess.Popen(command+['text','Hello world. '*500,'--to','zh-CN','--json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
time.sleep(2);child_pids=children(proc.pid);proc.send_signal(signal.SIGTERM)
proc.communicate(timeout=30);check(proc.returncode==130,'SIGTERM returns cancellation code')
time.sleep(.2);check(all(gone(pid) for pid in child_pids),'model subprocess reaped on SIGTERM')
Path(a.report).parent.mkdir(parents=True,exist_ok=True)
Path(a.report).write_text(json.dumps(dict(command=command,mode='real',checks=len(checks),passed=checks,results=artifacts),ensure_ascii=False,indent=2)+'\n')
print(f'{len(checks)} real-model checks passed.')
