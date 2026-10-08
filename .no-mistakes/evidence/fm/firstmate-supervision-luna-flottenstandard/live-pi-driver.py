import os, sys, json, time, shlex, subprocess, threading, hashlib
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
ROOT=Path.cwd(); LAB=ROOT/'.l'; EV=Path('/home/mla/.no-mistakes/evidence/01M4DJYGBZ6CN87EJQ641S8MD4')
requests=[]; results=[]
class Server(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length']))); requests.append(data)
  msgs=data.get('messages',[])
  tool_done=bool(msgs) and msgs[-1].get('role')=='tool'
  delta={'role':'assistant','content':'Supervision completed.'} if tool_done else {'role':'assistant','tool_calls':[{'index':0,'id':'call_lab','type':'function','function':{'name':'fm_branch_report','arguments':json.dumps({'task':'probe','verdict':'routine','summary':'Disposable lab supervision completed.'})}}]}
  chunks=[{'id':'lab','object':'chat.completion.chunk','created':1,'model':data['model'],'choices':[{'index':0,'delta':delta,'finish_reason':None}]},{'id':'lab','object':'chat.completion.chunk','created':1,'model':data['model'],'choices':[{'index':0,'delta':{},'finish_reason':'stop' if tool_done else 'tool_calls'}]}]
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
  for c in chunks: self.wfile.write(('data: '+json.dumps(c)+'\n\n').encode())
  self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
server=ThreadingHTTPServer(('127.0.0.1',0),Server); threading.Thread(target=server.serve_forever,daemon=True).start()
base=os.environ.copy()
for k in list(base):
 if k.startswith(('FM_','NO_MISTAKES','TASKS_AXI','PI_')) or k.endswith(('API_KEY','AUTH_TOKEN','OAUTH_TOKEN')): base.pop(k,None)
base.update(PI_OFFLINE='1',PI_TELEMETRY='0',TMPDIR=str(ROOT/'.test-phase-tmp'))
def run(args,**kw): return subprocess.run(args,check=True,text=True,capture_output=True,**kw)
run(['bash','bin/fm-lab-home.sh','create',str(LAB)],env=base)
(LAB/'tmux').mkdir(); base['TMUX_TMPDIR']=str(LAB/'tmux')
def tm(*args): return run(['tmux','-L','fm-lab',*args],env=base).stdout
probe=ROOT/'.test-phase-tmp/lab-extension.ts'
probe.write_text('''import {writeFileSync,readFileSync,mkdirSync} from "node:fs";
import {createBranchDispatchOffer,FM_BRANCH_DISPATCH_EVENT} from "../.pi/extensions/lib/fm-branch-dispatch.ts";
export default function(pi:any){
 const home=process.env.FM_HOME!;
 pi.on("session_start",()=>writeFileSync(`${home}/state/.lock`,`${process.pid}\\n`));
 pi.registerCommand("lab-probe",{description:"Exercise the public branch dispatch interface",handler:async(args:string,ctx:any)=>{
  writeFileSync(`${home}/state/probe.meta`,`project=${home}/projects/probe\\nwindow=fm-lab-probe\\n`);
  writeFileSync(`${home}/state/.wake-queue`,`${Math.floor(Date.now()/1000)}\\t${Date.now()}\\tsignal\\tprobe.status\\tsignal: disposable lab probe\\n`);
  const offer=createBranchDispatchOffer("signal: disposable lab probe",[`${home}/projects/probe`],false,true);
  pi.events.emit(FM_BRANCH_DISPATCH_EVENT,offer);
  let error=""; try {await offer.settlement;}catch(e){error=String(e)}
  const record={accepted:offer.accepted,error,main:{provider:ctx.model?.provider,id:ctx.model?.id,effort:pi.getThinkingLevel()},queue:readFileSync(`${home}/state/.wake-queue`,"utf8")};
  writeFileSync(`${home}/state/probe-result.json`,JSON.stringify(record));
  ctx.ui.notify(`LAB ${JSON.stringify(record)}`,error?"warning":"info");
 }});
}''')
agent=LAB/'agent'; agent.mkdir()
models={'providers':{'openai-codex':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'lab-only','models':[{'id':'gpt-6-luna','name':'Luna (local test endpoint)','reasoning':True,'contextWindow':32768,'maxTokens':1024}]},'lab-main':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'lab-only','models':[{'id':'main-model','reasoning':True,'contextWindow':32768,'maxTokens':1024},{'id':'plain','reasoning':False,'contextWindow':32768,'maxTokens':1024}]}}}
(agent/'models.json').write_text(json.dumps(models)); (agent/'settings.json').write_text(json.dumps({'quietStartup':True,'retry':{'enabled':False},'compaction':{'enabled':False}}))
def defaults(home,model='openai-codex/gpt-6-luna',effort='low'):
 for key,val in [('model',model),('effort',effort)]:
  p=home/'config'/f'supervision-branch-default-{key}'
  if val is None: p.unlink(missing_ok=True)
  else: p.write_text(val+'\n')
def start(home):
 cmd=['env',f'FM_HOME={home}',f'PI_CODING_AGENT_DIR={agent}','pi','--offline','--approve','--no-extensions','--no-context-files','--no-skills','--no-prompt-templates','--no-themes','--no-mcp','--model','lab-main/main-model','--thinking','high','--session-dir',str(home/'main-sessions'),'-e',str(probe),'-e',str(ROOT/'.pi/extensions/fm-branch-supervision.ts')]
 tm('new-session','-d','-s','primary','-x','120','-y','38','-c',str(ROOT),shlex.join(cmd))
 time.sleep(2)
def stop():
 try: tm('kill-server')
 except subprocess.CalledProcessError: pass
 time.sleep(.2)
def send(text):
 tm('send-keys','-t','primary','-l',text); tm('send-keys','-t','primary','Enter')
def wait_file(p,timeout=30):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  if p.exists(): return
  time.sleep(.1)
 raise RuntimeError(f'Timed out {p}: '+tm('capture-pane','-p','-t','primary'))
def exercise(label,home,expected_model=None,expected_effort=None,expected_error=None):
 out=home/'state/probe-result.json'; out.unlink(missing_ok=True); before=len(requests)
 send('/lab-probe'); wait_file(out)
 record=json.loads(out.read_text()); assert record['accepted'],record
 pointer=home/'state/.branch-session'; persisted=None
 if pointer.exists():
  f=Path(pointer.read_text().strip())
  if f.exists():
   rows=[json.loads(l) for l in f.read_text().splitlines()]; persisted={'model':next((f"{r['provider']}/{r['modelId']}" for r in reversed(rows) if r['type']=='model_change'),None),'effort':next((r['thinkingLevel'] for r in reversed(rows) if r['type']=='thinking_level_change'),None)}
 if expected_error:
  assert expected_error in record['error'],record
  assert len(requests)==before,'Unavailable model reached endpoint'
  assert record['queue'],'Refusal lost the wake'
 else:
  assert not record['error'],record
  if label != 'picker-follow-main': assert persisted=={'model':expected_model,'effort':expected_effort},persisted
  assert len(requests)>before,'No actual provider request'
  assert requests[before]['model']==expected_model.split('/',1)[1],requests[before]
  if expected_effort != 'off': assert requests[before].get('reasoning_effort')==expected_effort,requests[before]
 assert record['main']=={'provider':'lab-main','id':'main-model','effort':'high'},record
 capture=tm('capture-pane','-p','-t','primary','-S','-100'); (EV/(label+'.terminal.txt')).write_text(capture)
 item={'scenario':label,'main':record['main'],'branch':{'model':expected_model,'effort':expected_effort} if not expected_error else None,'persistedRecorded':persisted,'accepted':record['accepted'],'error':record['error'],'requests':[{'model':r.get('model'),'reasoning_effort':r.get('reasoning_effort'),'tools':[t['function']['name'] for t in r.get('tools',[])]} for r in requests[before:]],'wakeRetained':bool(record['queue'])}
 results.append(item); print(json.dumps(item),flush=True)
 return item
try:
 defaults(LAB); start(LAB)
 exercise('primary-default',LAB,'openai-codex/gpt-6-luna','low')
 send('/supervision-model'); time.sleep(1); (EV/'picker.terminal.txt').write_text(tm('capture-pane','-p','-t','primary'))
 tm('send-keys','-t','primary','Home','Enter'); time.sleep(1); tm('send-keys','-t','primary','Home','Enter'); time.sleep(1)
 assert (LAB/'config/supervision-branch-model').read_text()=='follow-main\n'
 assert (LAB/'config/supervision-branch-effort').read_text()=='follow-main\n'
 exercise('picker-follow-main',LAB,'lab-main/main-model','high'); stop()
 defaults(LAB,'lab-main/plain','off'); start(LAB)
 exercise('follow-main-after-restart-default-change',LAB,'lab-main/main-model','high'); stop()
 # Independent axes, and concrete home overrides.
 defaults(LAB)
 (LAB/'config/supervision-branch-model').unlink(); (LAB/'config/supervision-branch-effort').write_text('follow-main\n'); start(LAB)
 exercise('effort-follows-model-defaults',LAB,'openai-codex/gpt-6-luna','high'); stop()
 (LAB/'config/supervision-branch-model').write_text('follow-main\n'); (LAB/'config/supervision-branch-effort').unlink(); start(LAB)
 exercise('model-follows-effort-defaults',LAB,'lab-main/main-model','low'); stop()
 (LAB/'config/supervision-branch-model').write_text('lab-main/main-model\n'); (LAB/'config/supervision-branch-effort').write_text('medium\n'); start(LAB)
 exercise('concrete-local-override',LAB,'lab-main/main-model','medium'); stop()
 for axis in ['model','effort']: (LAB/'config'/f'supervision-branch-{axis}').unlink()
 defaults(LAB,'openai-codex/no-such-model','low'); start(LAB)
 exercise('unavailable-default-refused',LAB,expected_error='supervision model pin'); stop()
 defaults(LAB,'invalid-value','invalid-effort'); start(LAB)
 exercise('malformed-defaults-follow-main',LAB,'lab-main/main-model','high'); stop()
 defaults(LAB,'lab-main/plain','low'); start(LAB)
 exercise('default-effort-clamped',LAB,'lab-main/plain','off'); stop()
 defaults(LAB,None,None); start(LAB)
 exercise('absent-defaults-follow-main',LAB,'lab-main/main-model','high'); stop()
 # The real inheritance writer copies shared defaults while local choices stay local.
 sm=LAB/'second'; run(['bash','bin/fm-lab-home.sh','create',str(sm)],env=base)
 defaults(LAB)
 env=base|{'FM_HOME':str(LAB)}
 def inherit():
  return run(['bash','-c','. bin/fm-config-inherit-lib.sh; propagate_secondmate_inheritance "$1" "$2"','_',str(LAB),str(sm)],env=env).stdout
 inherit(); assert (sm/'config/supervision-branch-default-model').read_text()=='openai-codex/gpt-6-luna\n'
 start(sm); exercise('secondmate-inherited-startup',sm,'openai-codex/gpt-6-luna','low'); stop()
 (sm/'config/supervision-branch-model').write_text('follow-main\n'); (sm/'config/supervision-branch-effort').write_text('medium\n')
 defaults(LAB,'lab-main/plain','off'); inherit(); start(sm)
 exercise('secondmate-local-choice-preserved',sm,'lab-main/main-model','medium'); stop()
 defaults(LAB,None,None); inherit()
 assert not (sm/'config/supervision-branch-default-model').exists(); assert (sm/'config/supervision-branch-model').read_text()=='follow-main\n'
 # Real remote protocol receiver, with local transport (no SSH host needed).
 remote=LAB/'remote'; run(['bash','bin/fm-lab-home.sh','create',str(remote)],env=base)
 (remote/'config/supervision-branch-model').write_text('follow-main\n'); remote_env=base|{'FM_HOME':str(remote)}; receipt=[]
 for axis,value in [('model','openai-codex/gpt-6-luna\n'),('effort','low\n')]:
  args=['bash','bin/fm-remote-inherit.sh','put',f'config/supervision-branch-default-{axis}',str(len(value)),hashlib.sha256(value.encode()).hexdigest(),'1']
  receipt.append(run(args,input=value,env=remote_env).stdout)
  assert (remote/'config'/f'supervision-branch-default-{axis}').read_text()==value
  args=['bash','bin/fm-remote-inherit.sh','absent',f'config/supervision-branch-default-{axis}','0',hashlib.sha256(b'').hexdigest(),'2']
  receipt.append(run(args,input='',env=remote_env).stdout)
  assert not (remote/'config'/f'supervision-branch-default-{axis}').exists()
 refusal=subprocess.run(['bash','bin/fm-remote-inherit.sh','put','config/supervision-branch-model','0',hashlib.sha256(b'').hexdigest(),'3'],env=remote_env,input='',text=True,capture_output=True)
 assert refusal.returncode!=0 and 'path is not inherited material' in refusal.stderr+refusal.stdout
 assert (remote/'config/supervision-branch-model').read_text()=='follow-main\n'
 results.append({'scenario':'inheritance-update-removal-boundary','local':'shared defaults copied, updated and removed; local follow-main/medium preserved','remote':receipt,'localPinRefusal':refusal.stderr+refusal.stdout})
 print(json.dumps(results[-1]),flush=True)
finally:
 stop(); server.shutdown(); (EV/'live-pi-results.json').write_text(json.dumps(results,indent=2))
 import shutil
 shutil.rmtree(LAB)
