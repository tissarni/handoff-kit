#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
python3 - "$SANDBOX" "${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}" <<'PY'
import json, os, pathlib, shutil, subprocess, sys
root, scripts = map(pathlib.Path, sys.argv[1:])
helper = scripts / 'handoff-merge.py'
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
policy = pathlib.Path(env['HOME']) / '.config/handoff/project-policy.json'
policy.parent.mkdir(parents=True)
task = str((repo / 'plan.md').resolve())
def write_policy(risk='ordinary', override=False, hold=False, task_hold=False):
    entry={'enabled':True,'overrides':[], 'assessments':[{'task':task,'revision':'r1','risk':risk,'reason':'test'}], 'hold':hold, 'task_holds':[task] if task_hold else []}
    if override: entry['overrides'].append({'task':task,'revision':'r1','risk':risk})
    policy.write_text(json.dumps({'version':1,'repositories':{str(repo):entry}}))
write_policy()
evidence = repo / 'plan.final-review.json'
def ev(**overrides):
    obj={'feature':task,'repo':str(repo),'head':head,'base':base,'verdict':'PASS','blockers':'none','risk':'ordinary','backend':'test','created':0}
    obj.update(overrides)
    if evidence.is_dir(): shutil.rmtree(evidence)
    evidence.write_text(json.dumps(obj))

fakebin=root/'bin'; fakebin.mkdir(exist_ok=True)
state=root/'forge.json'; log=root/'forge.log'; control=root/'control.json'
state.write_text(json.dumps({'merged':False}))
control.write_text('{}')
(fakebin/'gh').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['FAKE_ROOT']); state=root/'forge.json'; log=root/'forge.log'; ctl=root/'control.json'
d=json.loads(state.read_text()); c=json.loads(ctl.read_text()); a=sys.argv[1:]; method=a[a.index('-X')+1] if '-X' in a else 'GET'; ep=next((x for x in a if x.startswith('repos/')), '')
log.open('a').write(method+' '+ep+'\\n')
reads=sum(1 for x in log.read_text().splitlines() if x.startswith('GET '))
if c.get('after') == reads: (root/'mutation.py').is_file() and __import__('subprocess').run([sys.executable,str(root/'mutation.py')])
if ep.endswith('/pulls?state=all&head=acme:feature/x'):
 p={'number':7,'state':'open','merged_at':None,'merge_commit_sha':None,'head':{'ref':'feature/x','sha':c.get('list_head',os.environ['FAKE_HEAD']),'repo':{'full_name':c.get('head_repo','acme/widget')}},'base':{'ref':c.get('base_ref','dev'),'sha':c.get('base_sha',os.environ['FAKE_BASE']),'repo':{'full_name':c.get('base_repo','acme/widget')}},'draft':c.get('draft',False)}; print(json.dumps(c.get('rows',[p]))); sys.exit(0)
if '/pulls/7/merge' in ep and method=='PUT':
 assert any('sha='+os.environ['FAKE_HEAD'] in x for x in a) and any('merge_method=squash' in x for x in a); d['merged']=True; state.write_text(json.dumps(d)); print('{"merged":true}'); sys.exit(0)
if ep.endswith('/pulls/7'):
 print(json.dumps({'number':7,'state':c.get('state','open'),'draft':c.get('draft',False),'merged':d['merged'],'merge_commit_sha':'c'*40 if d['merged'] else None,'mergeable_state':c.get('mergeable_state','clean'),'base':{'ref':c.get('base_ref','dev'),'sha':c.get('base_sha',os.environ['FAKE_BASE']),'repo':{'full_name':c.get('base_repo','acme/widget')}},'head':{'ref':c.get('head_ref','feature/x'),'sha':c.get('head_sha',os.environ['FAKE_HEAD']),'repo':{'full_name':c.get('head_repo','acme/widget')}}})); sys.exit(0)
if ep.endswith('/commits/'+os.environ['FAKE_HEAD']+'/status'): print('{"state":"success"}'); sys.exit(0)
if ep.endswith('/commits/'+os.environ['FAKE_HEAD']+'/check-runs'): print('{"check_runs":[{"status":"completed","conclusion":"success"}]}'); sys.exit(0)
if ep.endswith('/git/ref/heads/feature/x'): print(json.dumps({'object':{'sha':os.environ['FAKE_HEAD']}})); sys.exit(0)
if ep.endswith('/git/refs/heads/feature/x') and method=='DELETE': sys.exit(0)
sys.exit(8)
''')
(fakebin/'gh').chmod(0o755)
baseenv=dict(os.environ, PATH=f'{fakebin}:/usr/bin:/bin', HOME=str(root/'home'), GH_TOKEN='fake', GH_HOST='github.com', FAKE_ROOT=str(root), FAKE_HEAD=head, FAKE_BASE=base)

def run(args=None, setup=None, expect=1, reason=None, legacy=False):
    log.write_text(''); state.write_text('{"merged":false}'); control.write_text('{}')
    if setup: setup()
    argv=['python3',str(helper),'finalize']+(args if args is not None else ['--repository','acme/widget','--plan',str(repo/'plan.md'),'--branch','feature/x'])
    p=subprocess.run(argv,text=True,capture_output=True,env=baseenv)
    lines=log.read_text().splitlines()
    if p.returncode != expect: raise AssertionError(f'{argv} (reason {reason!r}): exit {p.returncode}, wanted {expect}: {p.stderr}')
    if reason and reason not in p.stderr: raise AssertionError(f'{label if "label" in locals() else "case"}: {argv}: missing reason {reason!r}: {p.stderr}')
    if expect and not p.stderr.startswith('handoff-merge: '): raise AssertionError(f'not controlled refusal: {p.stderr}')
    if expect and any(x.split(' ',1)[0] in ('POST','PUT','PATCH','DELETE') for x in lines): raise AssertionError(f'write before refusal: {lines}')
    return p,lines

def reset():
    subprocess.run(['git','-C',str(repo),'reset','--hard',head],check=True,stdout=subprocess.DEVNULL)
    write_policy(); ev()

def gone(): evidence.unlink(missing_ok=True)
# New positive interface and accepted informational/extra fields.
reset(); ev(); obj=json.loads(evidence.read_text()); obj.pop('backend'); obj.pop('created'); obj['extra']='ignored'; evidence.write_text(json.dumps(obj)); p,lines=run(expect=0)
assert sum(x.startswith('PUT ') for x in lines)==1, lines
assert any('/pulls?state=all&head=acme:feature/x' in x for x in lines), lines
# Legacy invocation, all malformed argument forms, and local repository identity.
run(['--repository','acme/widget','--pr','7','--head','x','--base','y','--branch','feature/x','--policy-repo',str(repo),'--task',task,'--revision','r1','--risk','ordinary'],reason='handoff-merge: ')
run(['--repository',str(repo),'--plan',str(repo/'plan.md'),'--branch','feature/x'],reason='owner/name')
run(['--repository','acme/widget','--plan',str(repo/'plan.md'),'--branch','feature/x','--unknown'],reason='')
# Policy authority and risk rules.
for label, setup, reason in [('no assessment',lambda: (policy.write_text(json.dumps({'version':1,'repositories':{str(repo):{'enabled':True,'assessments':[]}}}))), 'no risk assessment'),('risky without override',lambda: (write_policy('breaking-api'),ev(risk='breaking-api')), 'breaking-api'),('stale override',lambda: (write_policy('breaking-api'), policy.write_text(json.dumps({'version':1,'repositories':{str(repo):{'enabled':True,'assessments':[{'task':task,'revision':'r1','risk':'breaking-api','reason':'test'}],'overrides':[{'task':task,'revision':'r1','risk':'ordinary'}]}}})), ev(risk='breaking-api')), 'breaking-api')]:
    run(setup=setup,reason=reason)
run(setup=lambda:(write_policy('breaking-api',True),ev(risk='uncertain')),reason='late risk uncertain')
run(setup=lambda:(write_policy(hold=True),ev()),reason='hold')
run(setup=lambda:(write_policy(task_hold=True),ev()),reason='hold')
baseenv['HANDOFF_MERGE_HOLD']='1'; run(reason='hold'); baseenv.pop('HANDOFF_MERGE_HOLD')
# Evidence validation, including every required field in missing and wrong-type forms.
run(setup=lambda:(reset(),ev(head='f'*40)),reason='does not match local HEAD')
run(setup=gone,reason='invalid final-review evidence')
for label, raw, reason in [('malformed','{','invalid final-review evidence'),('non-object','[]','invalid final-review evidence'),('unknown risk',None,'invalid final-review evidence: risk'),('bad head',None,'invalid final-review evidence: head'),('FAIL',None,'invalid final-review evidence: verdict'),('other plan',None,'invalid final-review evidence: feature'),('bad base',None,'invalid final-review evidence: base'),('blockers',None,'invalid final-review evidence: blockers'),('repo checkout',None,'invalid final-review evidence: repo')]:
    def setup(label=label,raw=raw):
        reset()
        if raw is not None: evidence.write_text(raw); return
        changes={'unknown risk':{'risk':'x'},'bad head':{'head':'x'},'FAIL':{'verdict':'FAIL'},'other plan':{'feature':str(repo/'other.md')},'bad base':{'base':'x'},'blockers':{'blockers':'some'},'repo checkout':{'repo':str(root/'missing')}}[label]
        ev(**changes)
    run(setup=setup,reason=reason)
for key in ('feature','repo','head','base','verdict','blockers','risk'):
    for value in (None, []):
        def setup(key=key,value=value):
            reset(); obj={'feature':task,'repo':str(repo),'head':head,'base':base,'verdict':'PASS','blockers':'none','risk':'ordinary'}
            if value is None: obj.pop(key)
            else: obj[key]=value
            evidence.write_text(json.dumps(obj))
        run(setup=setup,reason=f'invalid final-review evidence: {key}')
# Plan without revision and evidence file inaccessible.
def no_revision():
    (repo/'plan.md').write_text('---\nother: value\n---\n'); ev()
run(setup=no_revision,reason='revision')
(repo/'plan.md').write_text('---\nrevision: r1\n---\nplan\n')
def unreadable():
    reset(); evidence.unlink(); evidence.mkdir()
run(setup=unreadable,reason='invalid final-review evidence')
# Forge identity / readiness negatives; list pulls have no `merged` field.
for label, ctl, reason in [('no PR',{'rows':[]},'pull request'),('two open PRs',{'rows':[]},'pull request'),('other repo',{'head_repo':'evil/repo'},'pull request'),('base main',{'base_ref':'main'},'base changed'),('wrong head',{'head_sha':'d'*40},'head'),('base changed',{'base_sha':'e'*40},'base changed'),('draft',{'draft':True},'draft'),('not clean',{'mergeable_state':'dirty'},'clean')]:
    def setup(ctl=ctl,label=label):
        reset(); control.write_text(json.dumps(ctl))
        if label=='two open PRs':
            p={'number':8,'state':'open','head':{'ref':'feature/x','sha':head,'repo':{'full_name':'acme/widget'}},'base':{'ref':'dev','sha':base,'repo':{'full_name':'acme/widget'}}}; control.write_text(json.dumps({'rows':[p,p]}))
    run(setup=setup,reason=reason)
# Re-check mutations are injected by fake gh between the first and later reads.
mutations=[('local HEAD moves','local head','local HEAD'),('repo hold recorded','hold','hold'),('assessment changes','assessment','risk breaking-api'),('evidence replaced','evidence','evidence'),('PR head sha changes','head_sha','head'),('draft PR','draft','draft'),('base ref','base_ref','base changed'),('base sha','base_sha','base changed'),('base repo','base_repo','pull request'),('head repo','head_repo','pull request'),('head ref','head_ref','pull request identity'),('mergeable_state','mergeable_state','clean'),('PR state','state','pull request'),('PR count','count','pull request')]
for label, field, reason in mutations:
    reset()
    mut=root/'mutation.py'
    if field=='local head': body=f"subprocess.run(['git','-C',{str(repo)!r},'config','user.name','Test'],check=True); pathlib.Path({str(repo/'tracked')!r}).write_text('two\\n'); subprocess.run(['git','-C',{str(repo)!r},'add','.'],check=True); subprocess.run(['git','-C',{str(repo)!r},'commit','-qm','move'],check=True)"
    elif field=='hold': body=f"p=pathlib.Path({str(policy)!r}); d=json.loads(p.read_text()); d['repositories'][{str(repo)!r}]['hold']=True; p.write_text(json.dumps(d))"
    elif field=='assessment': body=f"p=pathlib.Path({str(policy)!r}); d=json.loads(p.read_text()); d['repositories'][{str(repo)!r}]['assessments'][0]['risk']='breaking-api'; p.write_text(json.dumps(d))"
    elif field=='evidence': body=f"p=pathlib.Path({str(evidence)!r}); d=json.loads(p.read_text()); d['verdict']='FAIL'; p.write_text(json.dumps(d))"
    else:
        ctl={field:'d'*40 if field in ('head_sha','base_sha') else ({'draft':True,'base_ref':'main','base_repo':'other/repo','head_repo':'other/repo','head_ref':'other','mergeable_state':'dirty','state':'closed'}.get(field))}
        if field=='count': ctl['rows']=[]
        body=f"p=pathlib.Path({str(control)!r}); d=json.loads(p.read_text()); d.update({ctl!r}); p.write_text(json.dumps(d))"
    mut.write_text('import json,pathlib,subprocess\n'+body+'\n')
    run(setup=lambda: control.write_text(json.dumps({'after':3})),reason=reason)
    mut.unlink(missing_ok=True)
print('finalize binding: positive, validation, policy, forge identity, and re-check cases passed')
PY
