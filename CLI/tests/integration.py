#!/usr/bin/env python3
"""The identical black-box CLI/MCP suite runs against Swift and .NET executables.
Usage: python3 CLI/tests/integration.py --report PATH -- COMMAND [ARGS...]
No external Python dependencies. Mock mode tests orchestration, not translation quality.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import zipfile
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--report', required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
a = parser.parse_args()
command = a.command[1:] if a.command[:1] == ['--'] else a.command
env = dict(os.environ, ZHENGXIN_TRANSLATE_MOCK='1')
checks = []
def check(condition, name):
    if not condition:
        raise AssertionError(name)
    checks.append(name)
    print('PASS', name, flush=True)
def cli(*args, data=None, success=True):
    p = subprocess.run(command + list(args), input=data, text=True, capture_output=True, env=env, timeout=40)
    check((p.returncode == 0) == success, 'exit: ' + ' '.join(args[:2]))
    return p

class MCP:
    def __init__(self):
        self.proc = subprocess.Popen(command+['mcp','--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.lines = queue.Queue(); self.stderr = []
        def read():
            for line in self.proc.stdout: self.lines.put(line)
        def errors():
            self.stderr.extend(self.proc.stderr.readlines())
        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=errors, daemon=True).start()
        self.id = 0
    def send(self, value):
        self.proc.stdin.write(json.dumps(value, ensure_ascii=False)+'\n'); self.proc.stdin.flush()
    def read(self):
        return json.loads(self.lines.get(timeout=40))
    def call(self, method, params=None):
        self.id += 1
        req = dict(jsonrpc='2.0',id=self.id,method=method)
        if params is not None: req['params'] = params
        self.send(req); reply = self.read()
        check(reply.get('id') == self.id and reply.get('jsonrpc') == '2.0','RPC correlation '+method)
        return reply
    def init(self, version='2025-11-25'):
        r = self.call('initialize',dict(protocolVersion=version,capabilities={},clientInfo=dict(name='integration-test',version='1')))
        self.send(dict(jsonrpc='2.0',method='notifications/initialized'))
        return r
    def tool(self, name, args):
        return self.call('tools/call',dict(name=name,arguments=args))
    def value(self, name, args):
        reply = self.tool(name,args)
        check(not reply['result']['isError'], 'tool success '+name)
        return json.loads(reply['result']['content'][0]['text'])
    def terminal(self, id):
        for _ in range(200):
            state = self.value('get_job',dict(job_id=id))
            if state['status'] in ('completed','cancelled','failed'): return state
            time.sleep(.03)
        raise AssertionError('job timeout')
    def close(self):
        self.proc.stdin.close()
        try: code = self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill(); raise AssertionError('MCP did not stop on EOF')
        check(code == 0,'MCP EOF graceful exit')
        check(self.lines.empty(),'stdout has only expected protocol messages')

with tempfile.TemporaryDirectory(prefix='zhengxin-cli-test-') as tmp:
    root = Path(tmp)
    md = root/'中文 空格.md'
    md.write_text('# Heading\n\nHello & <world>.\n\n- Item\n\n```python\nprint("keep")\n```\n')
    txt = root/'sample.txt'; txt.write_text('Hello world.\n\nSecond paragraph.')
    epub = root/'sample.epub'
    with zipfile.ZipFile(epub,'w') as z:
        z.writestr('OEBPS/ch1.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Title</h1><p>Hello book.</p></body></html>')
    # Minimal valid, uncompressed, text-layer PDF; both PDFKit and PdfPig parse it.
    pdf = root/'sample.pdf'
    stream = b'BT /F1 12 Tf 72 720 Td (Hello world. A document translation test.) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream']
    raw = bytearray(b'%PDF-1.4\n'); offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(raw)); raw.extend(f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n')
    xref = len(raw); raw.extend(b'xref\n0 6\n0000000000 65535 f \n')
    for offset in offsets[1:]: raw.extend(f'{offset:010d} 00000 n \n'.encode())
    raw.extend(f'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode());pdf.write_bytes(raw)

    check('mcp --stdio' in cli('--help').stdout,'CLI help documents MCP')
    check('ready' in json.loads(cli('model-status','--json').stdout),'read-only model status')
    check(cli('--version').stdout.strip()=='1.0.1','CLI version')
    result=json.loads(cli('text','Hello 世界','--to','zh','--json').stdout)
    check(result['translation']=='[zh-CN] Hello 世界','text JSON and zh alias')
    check(cli('text','--stdin','--to','en',data='你好\n第二行').stdout.strip()=='[en] 你好\n第二行','UTF-8 multiline stdin')
    cli('text','hi','--to','invalid',success=False)
    cli('text','hi','--output','unused',success=False)
    cli('text','hi','--to','en','--to','fr',success=False)
    cli('text','',success=False)
    cli('file',str(txt),success=False)
    cli('file',str(txt),'--output',str(txt),success=False)
    cli('file',str(txt),'--output',str(root/'bad.pdf'),success=False)
    output=root/'输出 空格.md'
    completed=json.loads(cli('file',str(md),'--output',str(output),'--bilingual','--json').stdout)
    text=output.read_text()
    check(completed['status']=='completed' and Path(completed['output'])==output,'file exact output path')
    check('Hello & <world>.' in text and '[zh-CN] Hello & <world>.' in text,'bilingual Markdown')
    check(text.count('print("keep")')==1 and '[zh-CN] ```' not in text,'Markdown code preserved')
    cli('file',str(md),'--output',str(output),success=False)
    check(output.read_text()==text,'existing output untouched')
    docx=root/'translated.docx'
    cli('file',str(txt),'--output',str(docx),'--bilingual')
    with zipfile.ZipFile(docx) as z:
        xml=ET.fromstring(z.read('word/document.xml'))
        check('Hello world.' in ''.join(xml.itertext()) and '[zh-CN]' in ''.join(xml.itertext()),'valid bilingual DOCX XML')
    for source in [txt,epub,pdf,docx]:
        out=root/(source.name+'.md')
        cli('file',str(source),'--output',str(out))
        check('[zh-CN]' in out.read_text(),'input support '+source.suffix)
    empty=root/'empty.txt';empty.write_text('')
    cli('file',str(empty),'--output',str(root/'empty.md'),success=False)

    m=MCP()
    check(m.call('tools/list')['error']['code']==-32000,'MCP requires initialization')
    check(m.init()['result']['protocolVersion']=='2025-11-25','MCP negotiation')
    tools=m.call('tools/list')['result']['tools']
    check({t['name'] for t in tools}=={'translate_text','submit_document','get_job','cancel_job','get_model_status'},'MCP tool catalog')
    check(m.call('initialize',{})['error']['code']==-32600,'duplicate initialization rejected')
    check(m.value('translate_text',dict(text='MCP 中文\ntext',target='en'))['translation']=='[en] MCP 中文\ntext','MCP text')
    check(m.tool('translate_text',{})['error']['code']==-32602,'missing argument')
    check(m.tool('translate_text',dict(text=1))['error']['code']==-32602,'wrong argument type')
    check(m.tool('submit_document',dict(input=str(txt),output=str(root/'bad.md'),bilingual=1))['error']['code']==-32602,'boolean type strict')
    check(m.tool('get_model_status',dict(extra=True))['error']['code']==-32602,'extra argument rejected')
    check(m.tool('missing',{})['error']['code']==-32602,'unknown tool rejected')
    check(m.call('missing')['error']['code']==-32601,'unknown method rejected')
    check(m.tool('translate_text',dict(text='hi',target='auto'))['result']['isError'],'domain error returned as tool error')
    check(m.tool('get_job',dict(job_id='missing'))['result']['isError'],'unknown job error')
    m.proc.stdin.write('{broken\n');m.proc.stdin.flush()
    check(m.read()['error']['code']==-32700,'parse error recoverable')
    m.send([]);check(m.read()['error']['code']==-32600,'batch rejected')
    m.send(dict(jsonrpc='2.0',method='unknown_notification'))
    check(m.call('ping')['result']=={},'notifications receive no response')
    m.send(dict(jsonrpc='2.0',id=True,method='ping'))
    check(m.read()['error']['code']==-32600,'boolean request ID rejected')
    # A long-running tool request must not block transport reads or cancellation.
    m.send(dict(jsonrpc='2.0',id='concurrent-text',method='tools/call',params=dict(name='translate_text',arguments=dict(text='Hello concurrent'))))
    m.send(dict(jsonrpc='2.0',id='concurrent-ping',method='ping'))
    replies={r['id']:r for r in [m.read(),m.read()]}
    check(replies['concurrent-ping']['result']=={} and not replies['concurrent-text']['result']['isError'],'concurrent tool request and ping')
    m.send(dict(jsonrpc='2.0',id='cancel-text',method='tools/call',params=dict(name='translate_text',arguments=dict(text='Cancel this translation'))))
    m.send(dict(jsonrpc='2.0',method='notifications/cancelled',params=dict(requestId='cancel-text',reason='test')))
    check(m.read()['result']['isError'],'MCP request cancellation')
    # Background translation, queryable progress, preserved error state.
    out=root/'mcp.docx'
    job=m.value('submit_document',dict(input=str(epub),output=str(out),format='docx',bilingual=True))
    final=m.terminal(job['job_id'])
    check(final['status']=='completed' and final['completed']==final['total'] and out.exists(),'MCP document completion')
    check(m.value('cancel_job',dict(job_id=job['job_id']))['status']=='completed','terminal cancel is idempotent')
    bad=m.value('submit_document',dict(input=str(empty),output=str(root/'mcp-empty.md')))
    check(m.terminal(bad['job_id'])['status']=='failed','background parse failure visible')
    many=root/'many.txt';many.write_text('\n\n'.join('Paragraph '+str(i) for i in range(200)))
    running=m.value('submit_document',dict(input=str(many),output=str(root/'running.md')))
    queued=m.value('submit_document',dict(input=str(many),output=str(root/'queued.md')))
    m.value('cancel_job',dict(job_id=queued['job_id']))
    check(m.call('ping')['result']=={},'MCP responsive while translating')
    m.value('cancel_job',dict(job_id=running['job_id']))
    check(m.terminal(running['job_id'])['status']=='cancelled','running job cancelled')
    check(m.terminal(queued['job_id'])['status']=='cancelled','queued job cancelled')
    check(not (root/'running.md').exists() and not (root/'queued.md').exists(),'cancelled jobs do not export')
    m.value('submit_document',dict(input=str(many),output=str(root/'disconnect.md')))
    m.close()
    check(not (root/'disconnect.md').exists(),'EOF cancels unfinished job')
    check(not list(root.glob('.zhengxin-*')),'no temporary export directories remain')
    for version in ['2025-06-18','2025-03-26','unknown']:
        client=MCP();negotiated=client.init(version)['result']['protocolVersion'];check(negotiated==('2025-11-25' if version=='unknown' else version),'negotiation '+version);client.close()

Path(a.report).parent.mkdir(parents=True,exist_ok=True)
Path(a.report).write_text(json.dumps(dict(command=command,mode='mock',checks=len(checks),passed=checks),ensure_ascii=False,indent=2)+'\n')
print(f'{len(checks)} checks passed.')
