#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
python3 - "$SANDBOX" "${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}" <<'PY'
import json, os, pathlib, subprocess, sys
root, scripts = map(pathlib.Path, sys.argv[1:])
repo = root / 'repo'
repo.mkdir()
env = dict(os.environ, HOME=str(root / 'home'))
(repo / 'plan.md').write_text('---\nrevision: r1\n---\nplan\n')
subprocess.run(['git','init','-q','-b','main',str(repo)],check=True,env=env)
subprocess.run(['git','-C',str(repo),'config','user.name','Test'],check=True,env=env)
subprocess.run(['git','-C',str(repo),'config','user.email','test@example.com'],check=True,env=env)
(repo / 'tracked').write_text('one\n')
subprocess.run(['git','-C',str(repo),'add','.'],check=True,env=env)
subprocess.run(['git','-C',str(repo),'commit','-qm','init'],check=True,env=env)
head = subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
base = 'b' * 40
task = str((repo / 'plan.md').resolve())
policy = pathlib.Path(env['HOME']) / '.config/handoff/project-policy.json'
policy.parent.mkdir(parents=True)
policy.write_text(json.dumps({'version':1,'repositories':{str(repo):{'enabled':True,'overrides':[],'assessments':[{'task':task,'revision':'r1','risk':'ordinary','reason':'test'}],'hold':False,'task_holds':[]}}}))
evidence = repo / 'plan.final-review.json'
evidence.write_text(json.dumps({'feature':task,'repo':str(repo),'head':head,'base':base,'verdict':'PASS','blockers':'none','risk':'ordinary','backend':'test','created':0}))
fakebin=root/'bin'; fakebin.mkdir(exist_ok=True)
state=root/'forge.json'; log=root/'forge.log'; control=root/'control.json'
state.write_text('{"merged":false}')
control.write_text('{"draft":true}')
(fakebin/'gh').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['FAKE_ROOT']); state=root/'forge.json'; log=root/'forge.log'; ctl=root/'control.json'
d=json.loads(state.read_text()); c=json.loads(ctl.read_text()); a=sys.argv[1:]; method=a[a.index('-X')+1] if '-X' in a else 'GET'; ep='graphql' if 'graphql' in a else next((x for x in a if x.startswith('repos/')), '')
log.open('a').write(method+' '+ep+'\\n')
if ep.endswith('/pulls?state=all&head=acme:feature/x'):
 p={'number':7,'state':'open','merged_at':None,'merge_commit_sha':None,'head':{'ref':'feature/x','sha':c.get('list_head',os.environ['FAKE_HEAD']),'repo':{'full_name':'acme/widget'}},'base':{'ref':'dev','sha':os.environ['FAKE_BASE'],'repo':{'full_name':'acme/widget'}},'draft':c.get('draft',True)}; print(json.dumps(c.get('rows',[p]))); sys.exit(0)
if '/pulls/7/merge' in ep and method=='PUT':
 assert any('sha='+os.environ['FAKE_HEAD'] in x for x in a) and any('merge_method=squash' in x for x in a); d['merged']=True; state.write_text(json.dumps(d)); print('{"merged":true}'); sys.exit(0)
if ep.endswith('/pulls/7'):
 print(json.dumps({'number':7,'node_id':'PR_node','body':c.get('body','## Feature\\nfeature\\n## Acceptance\\naccept\\n## Final review\\n'+os.environ['FAKE_HEAD']+'\\n## CI\\nci\\n## Limitations\\nnone'),'state':'open','draft':c.get('draft',True),'merged':d['merged'],'merge_commit_sha':'c'*40 if d['merged'] else None,'mergeable_state':'clean','base':{'ref':'dev','sha':os.environ['FAKE_BASE'],'repo':{'full_name':'acme/widget'}},'head':{'ref':'feature/x','sha':('d'*40 if d.get('ready') and c.get('post_ready_head') else c.get('head_sha',os.environ['FAKE_HEAD'])),'repo':{'full_name':'acme/widget'}}})); sys.exit(0)
if ep.endswith('/protection/required_status_checks'):
 if c.get('protection_http'): print('HTTP '+str(c['protection_http']),file=sys.stderr); sys.exit(1)
 print(json.dumps(c.get('protection',{'contexts':['ci'],'checks':[]}))); sys.exit(0)
if ep.endswith('/commits/'+os.environ['FAKE_HEAD']+'/status'): print(json.dumps({'state':c.get('combined_state','success'),'statuses':c.get('statuses',[])})); sys.exit(0)
if '/commits/'+os.environ['FAKE_HEAD']+'/check-runs' in ep:
 page=int(ep.rsplit('page=',1)[1])
 runs=c.get('runs',[{'name':'ci','status':'completed','conclusion':'success','started_at':'2026-01-01T00:00:00Z','id':1}])
 if c.get('page2_failure'):
  runs=([{'name':'ci','status':'completed','conclusion':'success','started_at':'2026-01-01T00:00:00Z','id':1}]*100 + [{'name':'ci','status':'completed','conclusion':'failure','started_at':'2026-01-02T00:00:00Z','id':2}])
 batch=runs[(page-1)*100:page*100]
 print(json.dumps({'total_count':len(runs),'check_runs':batch})); sys.exit(0)
if ep == 'graphql':
 if c.get('graphql_error'): print('graphql mutation error',file=sys.stderr); sys.exit(1)
 d['ready']=True; state.write_text(json.dumps(d)); sys.stdout.write('{}'); sys.exit(0)
if ep.endswith('/git/ref/heads/feature/x'): print(json.dumps({'object':{'sha':os.environ['FAKE_HEAD']} })); sys.exit(0)
if ep.endswith('/git/refs/heads/feature/x') and method=='DELETE': sys.exit(0)
sys.exit(8)
''')
(fakebin/'gh').chmod(0o755)
env=dict(os.environ,PATH=f'{fakebin}:/usr/bin:/bin',HOME=str(root/'home'),GH_TOKEN='fake',GH_HOST='github.com',FAKE_ROOT=str(root),FAKE_HEAD=head,FAKE_BASE=base)
log.write_text('')
argv=['python3',str(scripts/'handoff-merge.py'),'finalize','--repository','acme/widget','--plan',str(repo/'plan.md'),'--branch','feature/x']
p=subprocess.run(argv,text=True,capture_output=True,env=env)
lines=log.read_text().splitlines()
if p.returncode != 0: raise AssertionError(f'expected draft finalize success, got {p.returncode}: {p.stderr}')
if lines.count('POST graphql') != 1: raise AssertionError(f'expected one GraphQL ready mutation: {lines}')
if sum(x.startswith('PUT ') for x in lines) != 1: raise AssertionError(f'expected one merge PUT: {lines}')
if not (lines.index('POST graphql') < next(i for i,x in enumerate(lines) if i > lines.index('POST graphql') and x.startswith('GET repos/acme/widget/pulls/7')) < next(i for i,x in enumerate(lines) if x.startswith('PUT '))): raise AssertionError(f'expected graphql, re-GET, PUT order: {lines}')
def exercise(label, cfg, expect=0, reason=None, graphql=None):
 control.write_text(json.dumps(cfg)); state.write_text('{"merged":false}'); log.write_text('')
 p=subprocess.run(argv,text=True,capture_output=True,env=env)
 lines=log.read_text().splitlines()
 if p.returncode != expect: raise AssertionError(f'{label}: exit {p.returncode}, wanted {expect}: {p.stderr}; calls={lines}')
 if reason and reason not in p.stderr: raise AssertionError(f'{label}: missing refusal {reason!r}: {p.stderr}')
 if expect and (not p.stderr.startswith('handoff-merge: ') or any(x.split(' ',1)[0] in ('PUT','PATCH','DELETE') or (x.startswith('POST ') and x != 'POST graphql') for x in lines) or ('POST graphql' in lines and graphql is False)): raise AssertionError(f'{label}: uncontrolled refusal or write: {p.stderr} {lines}')
 if graphql is not None and ('POST graphql' in lines) != graphql: raise AssertionError(f'{label}: GraphQL calls unexpected: {lines}')
 if expect == 0 and not any(x.startswith('PUT ') for x in lines): raise AssertionError(f'{label}: expected merge PUT: {lines}')
 return p, lines
# Non-draft and accepted protection fallbacks.
p,lines=exercise('non-draft positive',{'draft':False})
if 'POST graphql' in lines: raise AssertionError(f'non-draft PR used GraphQL: {lines}')
for label,cfg in [('403 fallback',{'draft':False,'protection_http':403,'protection':{},'runs':[{'name':'info','status':'completed','conclusion':'neutral'},{'name':'skip','status':'completed','conclusion':'skipped'},{'name':'green','status':'completed','conclusion':'success'}]}),('empty protection fallback',{'draft':False,'protection':{'contexts':[],'checks':[]},'runs':[{'name':'info','status':'completed','conclusion':'neutral'},{'name':'skip','status':'completed','conclusion':'skipped'},{'name':'green','status':'completed','conclusion':'success'}]})]:
 exercise(label,cfg)
for label,cfg,reason,gql in [
 ('required context missing',{'draft':False,'runs':[]},'required check missing: ci',False),
 ('required check failed',{'draft':False,'runs':[{'name':'ci','status':'completed','conclusion':'failure'}]},'required check unsuccessful: ci',False),
 ('check-run pending',{'draft':False,'runs':[{'name':'ci','status':'in_progress','conclusion':None}]},'required check unsuccessful: ci',False),
 ('page two failure',{'draft':False,'page2_failure':True},'required check unsuccessful: ci',False),
 ('legacy status failure',{'draft':False,'runs':[],'statuses':[{'context':'ci','state':'failure'}]},'required check unsuccessful: ci',False),
 ('404 empty pending fallback',{'draft':False,'protection_http':404,'runs':[],'combined_state':'pending','statuses':[]},'required checks are absent or unsuccessful',False),
 ('empty requirements pending fallback',{'draft':False,'protection':{'contexts':[],'checks':[]},'runs':[],'combined_state':'pending','statuses':[]},'required checks are absent or unsuccessful',False),
 ('malformed protection',{'draft':False,'protection':{'contexts':'ci','checks':[]}},'malformed required status checks response',False),
 ('missing body section',{'draft':False,'body':'## Feature\nfeature\n## Acceptance\naccept\n## Final review\n'+head+'\n## CI\nci\n'},'incomplete PR body: Limitations',False),
 ('final review omits head',{'draft':False,'body':'## Feature\nfeature\n## Acceptance\naccept\n## Final review\nother\n## CI\nci\n## Limitations\nnone'},'incomplete PR body: Final review',False),
 ('graphql mutation error',{'draft':True,'graphql_error':True},'GitHub POST graphql failed',True),
 ('changed head after ready',{'draft':True,'post_ready_head':True},'refused after marking ready',True),
]:
 exercise(label,cfg,expect=1,reason=reason,graphql=gql)
print('finalize forge: draft, non-draft, readiness fallbacks, and refusal scenarios passed')
PY
