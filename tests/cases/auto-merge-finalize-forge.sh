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
if ep.endswith('/commits/'+os.environ['FAKE_HEAD']+'/status'): st=c.get('statuses',[]); print(json.dumps({'state':c.get('combined_state','success'),'total_count':c.get('status_total',len(st)),'statuses':st})); sys.exit(0)
if 'check-runs' in ep: print('HTTP 404 check-runs must never be requested',file=sys.stderr); sys.exit(8)
if '/actions/' in ep:
 if c.get('actions_http'): print('HTTP '+str(c['actions_http']),file=sys.stderr); sys.exit(1)
 H=os.environ['FAKE_HEAD']
 if 'wruns' in c: runs=[dict(r) for r in c['wruns']]
 else:
  raw=c.get('runs',[{'name':'ci','status':'completed','conclusion':'success'}])
  if c.get('page2_failure'): raw=[{'name':'ci','status':'completed','conclusion':'success'}]*100+[{'name':'ci','status':'completed','conclusion':'failure'}]
  runs=[{'id':i+1,'workflow_id':i+1,'name':'wf'+str(i),'status':r['status'],'conclusion':r['conclusion'],'jobs':[dict(r)]} for i,r in enumerate(raw)]
 for r in runs:
  r.setdefault('head_sha',H); r.setdefault('event','push'); r.setdefault('created_at','2026-01-01T00:00:00Z')
  for j,job in enumerate(r.get('jobs',[])): 'id' in job or job.update(id=r['id']*1000+j); job.setdefault('run_id',r['id']); job.setdefault('started_at','2026-01-01T00:00:00Z')
 if ep.split('?')[0].endswith('/jobs'):
  rid=int(ep.split('/actions/runs/')[1].split('/')[0]); jobs=[j for r in runs if r['id']==rid for j in r.get('jobs',[])]
  print(json.dumps([{'total_count':len(jobs),'jobs':jobs}])); sys.exit(0)
 if '/actions/runs?head_sha='+H in ep and '--slurp' in a:
  out=[{'total_count':len(runs),'workflow_runs':[{k:v for k,v in r.items() if k!='jobs'} for r in runs[i:i+100]]} for i in range(0,len(runs),100)] or [{'total_count':0,'workflow_runs':[]}]
  print(json.dumps(out)); sys.exit(0)
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
 # Public and private repositories make the same calls (Actions runs, jobs, statuses), so one fake serves both.
 if any('check-runs' in x for x in lines): raise AssertionError(f'{label}: check-runs requested: {lines}')
 if p.returncode != expect: raise AssertionError(f'{label}: exit {p.returncode}, wanted {expect}: {p.stderr}; calls={lines}')
 channel = p.stdout if expect == 0 else p.stderr
 if reason and reason not in channel: raise AssertionError(f'{label}: missing status/reason {reason!r}: stdout={p.stdout!r} stderr={p.stderr!r}')
 if expect in (1,5) and (not p.stderr.startswith('handoff-merge: ') or any(x.split(' ',1)[0] in ('PUT','PATCH','DELETE') or (x.startswith('POST ') and x != 'POST graphql') for x in lines) or ('POST graphql' in lines and graphql is False)): raise AssertionError(f'{label}: uncontrolled refusal or write: {p.stderr} {lines}')
 if graphql is not None and ('POST graphql' in lines) != graphql: raise AssertionError(f'{label}: GraphQL calls unexpected: {lines}')
 expected_puts = (0 if expect in (1,5) else 1) if puts is None else puts
 if sum(x.startswith('PUT ') for x in lines) != expected_puts: raise AssertionError(f'{label}: expected {expected_puts} merge PUTs: {lines}')
 if deletes is not None and sum(x.startswith('DELETE ') for x in lines) != deletes: raise AssertionError(f'{label}: expected {deletes} DELETEs: {lines}')
 return p, lines
# Non-draft and accepted protection fallbacks.
p,lines=exercise('non-draft positive',{'draft':False})
if 'POST graphql' in lines: raise AssertionError(f'non-draft PR used GraphQL: {lines}')
for label,cfg in [('403 fallback',{'draft':False,'protection_http':403,'protection':{},'runs':[{'name':'info','status':'completed','conclusion':'neutral'},{'name':'skip','status':'completed','conclusion':'skipped'},{'name':'green','status':'completed','conclusion':'success'}]}),('empty protection fallback',{'draft':False,'protection':{'contexts':[],'checks':[]},'runs':[{'name':'info','status':'completed','conclusion':'neutral'},{'name':'skip','status':'completed','conclusion':'skipped'},{'name':'green','status':'completed','conclusion':'success'}]})]:
 exercise(label,cfg)
for label,cfg,reason,gql in [
 ('required context missing',{'draft':False,'runs':[]},'required check not visible: ci',False),
 ('required check failed',{'draft':False,'runs':[{'name':'ci','status':'completed','conclusion':'failure'}]},'required check unsuccessful: ci',False),
 ('check-run pending',{'draft':False,'runs':[{'name':'ci','status':'in_progress','conclusion':None}]},'pending:',False),
 ('page two failure',{'draft':False,'page2_failure':True},'required check unsuccessful: ci',False),
 ('legacy status failure',{'draft':False,'runs':[],'statuses':[{'context':'ci','state':'failure'}]},'required check unsuccessful: ci',False),
 ('404 empty pending fallback',{'draft':False,'protection_http':404,'runs':[],'combined_state':'pending','statuses':[]},'required checks are absent or unsuccessful',False),
 ('empty requirements pending fallback',{'draft':False,'protection':{'contexts':[],'checks':[]},'runs':[],'combined_state':'pending','statuses':[]},'required checks are absent or unsuccessful',False),
 ('malformed protection',{'draft':False,'protection':{'contexts':'ci','checks':[]}},'malformed required status checks response',False),
 ('missing body section',{'draft':False,'body':'## Feature\nfeature\n## Acceptance\naccept\n## Final review\n'+head+'\n## CI\nci\n'},'incomplete PR body: Limitations',False),
 ('final review omits head',{'draft':False,'body':'## Feature\nfeature\n## Acceptance\naccept\n## Final review\nother\n## CI\nci\n## Limitations\nnone'},'incomplete PR body: Final review',False),
 ('draft with failed check',{'draft':True,'runs':[{'name':'ci','status':'completed','conclusion':'failure'}]},'required check unsuccessful: ci',False),
 ('draft missing body section',{'draft':True,'body':'## Feature\nfeature\n'},'incomplete PR body',False),
 ('graphql mutation error',{'draft':True,'graphql_error':True},'GitHub POST graphql failed',True),
 ('changed head after ready',{'draft':True,'post_ready_head':True},'refused after marking ready',True),
]:
 exercise(label,cfg,expect=5 if reason=='pending:' else 1,reason=reason,graphql=gql)
for label,cfg,expect,reason,puts,deletes in [
 ('already merged restart',{'draft':False,'initial_merged':True},0,'already merged',0,1),
 ('PUT error reconciled merged',{'draft':False,'put_error':True,'merge_on_error':True},0,None,1,1),
 ('PUT error remains unmerged',{'draft':False,'put_error':True},3,'ambiguous',1,0),
 ('base points at merge',{'draft':False,'base_sha':'c'*40},0,None,1,1),
 # GitHub compare BASE...HEAD reports HEAD relative to BASE: merge_sha...base_sha is "ahead" when base contains the merge.
 ('compare identical',{'draft':False,'compare_status':'identical'},0,None,1,1),
 ('compare ahead',{'draft':False,'compare_status':'ahead'},0,None,1,1),
 ('compare diverged',{'draft':False,'compare_status':'diverged'},3,'ambiguous',1,0),
 ('compare behind',{'draft':False,'compare_status':'behind'},3,'ambiguous',1,0),
 ('read-back GET fails',{'draft':False,'pr_get_error':True,'pr_get_error_after_put':True},3,'ambiguous',1,0),
 ('compare GET fails',{'draft':False,'compare_error':True},3,'ambiguous',1,0),
 ('branch moved',{'draft':False,'branch_moved':True},0,'branch preserved',1,0),
 ('delete fails',{'draft':False,'delete_error':True},4,'cleanup failed',1,1),
 ('branch already absent',{'draft':False,'initial_merged':True,'ref_missing':True},0,'branch already deleted',0,0),
 ('branch ref GET fails',{'draft':False,'ref_error':True},4,'cleanup failed',1,0),
]:
 p,lines=exercise(label,cfg,expect=expect,reason=reason,puts=puts,deletes=deletes)
# Pull request candidate selection: only same-repository rows for this branch, reviewed head and dev count.
def row(number, state='open', merged=False, head_repo='acme/widget', sha=None, base_ref='dev'):
 return {'number':number,'state':state,'merged_at':'2026-01-01T00:00:00Z' if merged else None,'merge_commit_sha':'c'*40 if merged else None,'draft':False,
         'head':{'ref':'feature/x','sha':sha or head,'repo':{'full_name':head_repo}},'base':{'ref':base_ref,'sha':base,'repo':{'full_name':'acme/widget'}}}
for label,rows,expect,reason in [
 ('no candidates',[],1,'ambiguous pull request candidates: none'),
 ('open and merged',[row(7),row(8,'closed',True)],1,'ambiguous pull request candidates: 7, 8'),
 ('two open',[row(7),row(8)],1,'ambiguous pull request candidates: 7, 8'),
 ('two merged',[row(7,'closed',True),row(8,'closed',True)],1,'ambiguous pull request candidates: 7, 8'),
 ('closed unmerged only',[row(9,'closed')],1,'ambiguous pull request candidates: 9'),
 ('open with closed unmerged',[row(7),row(9,'closed')],0,None),
 ('open with foreign head repository',[row(7),row(8,head_repo='other/widget')],0,None),
 ('open with stale head',[row(7),row(8,sha='e'*40)],0,None),
 ('base mismatch only',[row(8,base_ref='main')],1,'base changed; pull request candidates: 8'),
]:
 exercise(label,{'draft':False,'rows':rows},expect=expect,reason=reason,graphql=False if expect == 1 else None)
p,lines=exercise('report deleted',{'draft':False})
for required in ('merge-sha: '+'c'*40,'branch-cleanup: deleted'):
 if required not in p.stdout: raise AssertionError(f'missing reporting line {required!r}: {p.stdout!r}')
p,lines=exercise('report preserved',{'draft':False,'branch_moved':True})
for required in ('merge-sha: '+'c'*40,'branch-cleanup: preserved'):
 if required not in p.stdout: raise AssertionError(f'missing reporting line {required!r}: {p.stdout!r}')
p,lines=exercise('report already absent',{'draft':False,'initial_merged':True,'ref_missing':True},puts=0,deletes=0)
for required in ('merge-sha: '+'c'*40,'branch-cleanup: already-deleted'):
 if required not in p.stdout: raise AssertionError(f'missing reporting line {required!r}: {p.stdout!r}')
p,lines=exercise('report cleanup failure',{'draft':False,'delete_error':True},expect=4,reason='cleanup failed',puts=1,deletes=1)
for required in ('merge-sha: '+'c'*40,'branch-cleanup: failed'):
 if required not in p.stdout: raise AssertionError(f'missing reporting line {required!r}: {p.stdout!r}')
def jb(name, status='completed', conclusion='success', **kw): return dict({'name':name,'status':status,'conclusion':conclusion}, **kw)
def wr(id, wf, jobs, status='completed', conclusion='success', created='2026-01-01T00:00:00Z', head_sha=None, event='push'):
 r={'id':id,'workflow_id':wf,'name':'wf'+str(wf),'status':status,'conclusion':conclusion,'created_at':created,'event':event,'jobs':jobs}
 if head_sha: r['head_sha']=head_sha
 return r
green=wr(1,1,[jb('ci')])
for label,cfg in [
 ('green run merges',{'draft':False,'wruns':[green]}),
 ('green run merges, fallback',{'draft':False,'protection_http':404,'wruns':[green]}),
 ('old failed run, newer success of same workflow',{'draft':False,'wruns':[wr(1,1,[jb('ci','completed','failure')],conclusion='failure'),wr(2,1,[jb('ci')],created='2026-01-02T00:00:00Z')]}),
 ('old failed run, newer success, fallback',{'draft':False,'protection_http':404,'wruns':[wr(1,1,[jb('ci','completed','failure')],conclusion='failure'),wr(2,1,[jb('ci')],created='2026-01-02T00:00:00Z')]}),
 ('run for a foreign head is ignored',{'draft':False,'protection_http':404,'wruns':[green,wr(5,5,[jb('x','completed','failure')],conclusion='failure',head_sha='e'*40)]}),
 ('required context matched by job name',{'draft':False,'protection':{'contexts':['build'],'checks':[]},'wruns':[wr(1,1,[jb('lint'),jb('build')])]}),
 ('required context matched by check definition',{'draft':False,'protection':{'contexts':[],'checks':[{'context':'build','app_id':1}]},'wruns':[wr(1,1,[jb('build')])]}),
 ('required context matched by status',{'draft':False,'protection':{'contexts':['lint'],'checks':[]},'wruns':[],'statuses':[{'context':'lint','state':'success'}]}),
 ('no runs, successful status, fallback',{'draft':False,'protection_http':404,'wruns':[],'statuses':[{'context':'ext','state':'success'}]}),
]: exercise(label,cfg)
for label,cfg,reason in [
 ('failed run',{'draft':False,'wruns':[wr(1,1,[jb('ci','completed','failure')],conclusion='failure')]},'required check unsuccessful: ci'),
 ('failed run, fallback',{'draft':False,'protection_http':404,'wruns':[wr(1,1,[jb('ci','completed','failure')],conclusion='failure')]},'required checks are absent or unsuccessful'),
 ('in-progress run',{'draft':False,'wruns':[wr(1,1,[jb('ci','in_progress',None)],'in_progress',None)]},'pending:'),
 ('in-progress run, fallback',{'draft':False,'protection_http':404,'wruns':[wr(1,1,[jb('ci','in_progress',None)],'in_progress',None)]},'pending:'),
 ('cancelled run',{'draft':False,'wruns':[wr(1,1,[jb('ci','completed','cancelled')],conclusion='cancelled')]},'required check unsuccessful: ci'),
 ('cancelled run, fallback',{'draft':False,'protection_http':404,'wruns':[wr(1,1,[jb('ci','completed','cancelled')],conclusion='cancelled')]},'required checks are absent or unsuccessful'),
 ('failed job inside success run',{'draft':False,'wruns':[wr(1,1,[jb('ci','completed','failure')])]},'required check unsuccessful: ci'),
 ('failed job inside success run, fallback',{'draft':False,'protection_http':404,'wruns':[wr(1,1,[jb('lint'),jb('ci','completed','failure')])]},'required checks are absent or unsuccessful'),
 ('failed status beside green run, fallback',{'draft':False,'protection_http':404,'wruns':[green],'statuses':[{'context':'ext','state':'failure'}]},'required checks are absent or unsuccessful'),
 ('no runs and no statuses',{'draft':False,'protection_http':404,'wruns':[],'combined_state':'success','statuses':[]},'required checks are absent or unsuccessful'),
 ('required context visible nowhere',{'draft':False,'protection':{'contexts':['ghost'],'checks':[]},'wruns':[green]},'required check not visible: ghost'),
 ('actions 403',{'draft':False,'actions_http':403},'ci not readable: grant Actions: Read and Commit statuses: Read'),
 ('combined status failing beyond the listed page, fallback',{'draft':False,'protection_http':404,'wruns':[green],'combined_state':'failure','statuses':[{'context':'ext','state':'success'}]},'required checks are absent or unsuccessful'),
 ('combined status failing beyond the listed page',{'draft':False,'protection':{'contexts':['ci'],'checks':[]},'wruns':[green],'combined_state':'failure','statuses':[{'context':'ext','state':'success'}]},'commit status is not success'),
 ('more statuses than listed',{'draft':False,'protection_http':404,'wruns':[green],'status_total':31,'statuses':[{'context':'ext','state':'success'}]},'commit statuses are truncated'),
 ('run without workflow identity',{'draft':False,'protection_http':404,'wruns':[{'id':1,'status':'completed','conclusion':'failure','created_at':'2026-01-01T00:00:00Z','event':'push','jobs':[jb('ci','completed','failure')]},{'id':2,'status':'completed','conclusion':'success','created_at':'2026-01-02T00:00:00Z','event':'push','jobs':[jb('ci')]}]},'invalid workflow_runs response'),
 ('run id that is not a plain integer',{'draft':False,'protection_http':404,'wruns':[wr('²',1,[jb('ci',id=1,run_id=1)])]},'invalid workflow_runs response'),
 ('success run without jobs, fallback',{'draft':False,'protection_http':404,'wruns':[wr(1,1,[])]},'required checks are absent or unsuccessful'),
 ('success run without jobs',{'draft':False,'wruns':[wr(1,1,[])]},'required check not visible: ci'),
 ('same-named job queued in another workflow',{'draft':False,'wruns':[wr(1,1,[jb('ci')]),wr(2,2,[jb('ci','queued',None,started_at=None)],'queued',None)]},'required check unsuccessful: ci'),
 ('actions 403, draft',{'draft':True,'actions_http':403},'ci not readable: grant Actions: Read and Commit statuses: Read'),
 ('actions 403, fallback',{'draft':False,'protection_http':403,'actions_http':403},'ci not readable: grant Actions: Read and Commit statuses: Read'),
]:
 p,lines=exercise(label,cfg,expect=5 if reason=='pending:' else 1,reason=reason,graphql=False)
 if any(x.startswith(('PUT ','PATCH ','DELETE ','POST ')) for x in lines): raise AssertionError(f'{label}: mutation before refusal: {lines}')
for label,cfg,expect in [('report refusal',{'draft':False,'runs':[{'name':'ci','status':'completed','conclusion':'failure'}]},1),('report ambiguous',{'draft':False,'put_error':True},3)]:
 p,lines=exercise(label,cfg,expect=expect,puts=0 if expect==1 else 1)
 if 'merge-sha:' in p.stdout or 'branch-cleanup:' in p.stdout:
  raise AssertionError(f'{label}: refused/ambiguous output carried success reporting: {p.stdout!r}')
print('finalize forge: draft, readiness, merge reconciliation, base verification, cleanup, and reporting cases passed')
PY
