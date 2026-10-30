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
 merged=c.get('initial_merged',False)
 p={'number':7,'state':'closed' if merged else 'open','merged_at':'2026-01-01T00:00:00Z' if merged else None,'merge_commit_sha':'c'*40 if merged else None,'head':{'ref':'feature/x','sha':c.get('list_head',os.environ['FAKE_HEAD']),'repo':{'full_name':'acme/widget'}},'base':{'ref':'dev','sha':os.environ['FAKE_BASE'],'repo':{'full_name':'acme/widget'}},'draft':c.get('draft',True)}; print(json.dumps(c.get('rows',[p]))); sys.exit(0)
if '/pulls/7/merge' in ep and method=='PUT':
 assert any('sha='+os.environ['FAKE_HEAD'] in x for x in a) and any('merge_method=squash' in x for x in a)
 d['puts']=d.get('puts',0)+1
 if c.get('put_error'):
  if c.get('merge_on_error'): d['merged']=True
  state.write_text(json.dumps(d)); print('HTTP 500',file=sys.stderr); sys.exit(1)
 d['merged']=True; state.write_text(json.dumps(d)); print('{"merged":true}'); sys.exit(0)
if ep.endswith('/pulls/7'):
 if c.get('pr_get_error') and (not c.get('pr_get_error_after_put') or d.get('puts')): print('HTTP 500',file=sys.stderr); sys.exit(1)
 merged=d.get('merged',False) or c.get('initial_merged',False)
 print(json.dumps({'number':7,'node_id':'PR_node','body':c.get('body','## Feature\\nfeature\\n## Acceptance\\naccept\\n## Final review\\n'+os.environ['FAKE_HEAD']+'\\n## CI\\nci\\n## Limitations\\nnone'),'state':'closed' if merged else 'open','draft':c.get('draft',True),'merged':merged,'merge_commit_sha':'c'*40 if merged else None,'mergeable_state':'clean','base':{'ref':'dev','sha':os.environ['FAKE_BASE'],'repo':{'full_name':'acme/widget'}},'head':{'ref':'feature/x','sha':('d'*40 if d.get('ready') and c.get('post_ready_head') else c.get('head_sha',os.environ['FAKE_HEAD'])),'repo':{'full_name':'acme/widget'}}})); sys.exit(0)
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
if ep.endswith('/git/ref/heads/feature/x'):
 if c.get('ref_missing'): print('HTTP 404',file=sys.stderr); sys.exit(1)
 if c.get('ref_error'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 sha='d'*40 if c.get('branch_moved') else os.environ['FAKE_HEAD']
 print(json.dumps({'object':{'sha':sha}})); sys.exit(0)
if '/git/refs/heads/feature/x' in ep and method=='DELETE':
 d['deletes']=d.get('deletes',0)+1; state.write_text(json.dumps(d))
 if c.get('delete_error'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 sys.exit(0)
if '/git/ref/heads/dev' in ep: print(json.dumps({'object':{'sha':c.get('base_sha',os.environ['FAKE_BASE'])}})); sys.exit(0)
if '/compare/' in ep:
 if ep != 'repos/acme/widget/compare/'+'c'*40+'...'+os.environ['FAKE_BASE']: print('unexpected compare endpoint: '+ep,file=sys.stderr); sys.exit(9)
 if c.get('compare_error'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 print(json.dumps({'status':c.get('compare_status','identical')})); sys.exit(0)
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
def exercise(label, cfg, expect=0, reason=None, graphql=None, puts=None, deletes=None):
 control.write_text(json.dumps(cfg)); state.write_text('{"merged":false}'); log.write_text('')
 p=subprocess.run(argv,text=True,capture_output=True,env=env)
 lines=log.read_text().splitlines()
 if p.returncode != expect: raise AssertionError(f'{label}: exit {p.returncode}, wanted {expect}: {p.stderr}; calls={lines}')
 channel = p.stdout if expect == 0 else p.stderr
 if reason and reason not in channel: raise AssertionError(f'{label}: missing status/reason {reason!r}: stdout={p.stdout!r} stderr={p.stderr!r}')
 if expect == 1 and (not p.stderr.startswith('handoff-merge: ') or any(x.split(' ',1)[0] in ('PUT','PATCH','DELETE') or (x.startswith('POST ') and x != 'POST graphql') for x in lines) or ('POST graphql' in lines and graphql is False)): raise AssertionError(f'{label}: uncontrolled refusal or write: {p.stderr} {lines}')
 if graphql is not None and ('POST graphql' in lines) != graphql: raise AssertionError(f'{label}: GraphQL calls unexpected: {lines}')
 expected_puts = (0 if expect else 1) if puts is None else puts
 if sum(x.startswith('PUT ') for x in lines) != expected_puts: raise AssertionError(f'{label}: expected {expected_puts} merge PUTs: {lines}')
 if deletes is not None and sum(x.startswith('DELETE ') for x in lines) != deletes: raise AssertionError(f'{label}: expected {deletes} DELETEs: {lines}')
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
for label,cfg,expect,reason,puts,deletes in [
 ('already merged restart',{'draft':False,'initial_merged':True},0,'already merged',0,1),
 ('PUT error reconciled merged',{'draft':False,'put_error':True,'merge_on_error':True},0,None,1,1),
 ('PUT error remains unmerged',{'draft':False,'put_error':True},3,'ambiguous',1,0),
 ('base points at merge',{'draft':False,'base_sha':'c'*40},0,None,1,1),
 ('compare identical',{'draft':False,'compare_status':'identical'},0,None,1,1),
 ('compare behind',{'draft':False,'compare_status':'behind'},0,None,1,1),
 ('compare diverged',{'draft':False,'compare_status':'diverged'},3,'ambiguous',1,0),
 ('compare ahead',{'draft':False,'compare_status':'ahead'},3,'ambiguous',1,0),
 ('read-back GET fails',{'draft':False,'pr_get_error':True,'pr_get_error_after_put':True},3,'ambiguous',1,0),
 ('compare GET fails',{'draft':False,'compare_error':True},3,'ambiguous',1,0),
 ('branch moved',{'draft':False,'branch_moved':True},0,'branch preserved',1,0),
 ('delete fails',{'draft':False,'delete_error':True},4,'cleanup failed',1,1),
 ('branch already absent',{'draft':False,'initial_merged':True,'ref_missing':True},0,'branch already deleted',0,0),
 ('branch ref GET fails',{'draft':False,'ref_error':True},4,'cleanup failed',1,0),
]:
 p,lines=exercise(label,cfg,expect=expect,reason=reason,puts=puts,deletes=deletes)
print('finalize forge: draft, readiness, merge reconciliation, base verification, and cleanup cases passed')
PY
