#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
python3 - "$SANDBOX/kit/handoff-merge.py" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('merge', sys.argv[1]); m=importlib.util.module_from_spec(spec); sys.modules['merge']=m; spec.loader.exec_module(m)
head='a'*40
real_decision=m._finalize_decision
m._finalize_decision=lambda *a,**kw: ('repo','task','r1',7,head,'b'*40,False)
body='## Feature\nf\n## Acceptance\na\n## Final review\n'+head+'\n## CI\nc\n## Limitations\nn'
state={'mergeable':'clean','runs_status':'in_progress','run_conclusion':None,'job_status':'in_progress','job_conclusion':None,'calls':[], 'status_state':'success','total':0,'statuses':[],'jobs_mode':'normal','fallback':False}
def gh(method, endpoint, fields=None, **kw):
    state['calls'].append((method,endpoint))
    if endpoint.endswith('/pulls/7'): return {'body':body,'draft':False,'mergeable_state':state['mergeable']}
    if endpoint.endswith('/protection/required_status_checks'): return {'contexts':[] if state['fallback'] else ['ci'],'checks':[]}
    if '/actions/runs?head_sha=' in endpoint: return [{'workflow_runs':[{'id':1,'workflow_id':1,'name':'ci','event':'push','head_sha':head,'status':state['runs_status'],'conclusion':state['run_conclusion'],'created_at':'now'}]}]
    if '/actions/runs/1/jobs?' in endpoint:
        if state['jobs_mode']=='empty': return [{'jobs': []}]
        return [{'jobs':[{'name':'ci','status':state['job_status'],'conclusion':state['job_conclusion']}]}]
    if endpoint.endswith('/commits/'+head+'/status'): return {'state':state['status_state'],'total_count':state['total'],'statuses':state['statuses']}
    raise AssertionError((method,endpoint))
m._gh=gh
for label, mergeable, status, conclusion, expect in [
    ('pending run','clean','in_progress',None,5),
    ('unknown mergeability','unknown','completed','success',5),
    ('completed failure','clean','completed','failure',1),
]:
    state.update(mergeable=mergeable,runs_status=status,run_conclusion=conclusion,
                 job_status='in_progress' if status!='completed' else 'completed',
                 job_conclusion='failure' if conclusion=='failure' else conclusion,calls=[])
    try: m._finalize('acme/widget','plan','feature/x','dev')
    except m.Refusal as exc:
        actual=exc.exit_code if isinstance(exc,m.FinalizeFailure) else 1
        assert actual==expect, (label,actual)
        assert (str(exc).startswith('pending:') if expect==5 else 'unsuccessful' in str(exc)), (label,str(exc))
    else: raise AssertionError(label+' unexpectedly finalized')
    assert not any(method in ('POST','PUT','PATCH','DELETE') for method,endpoint in state['calls']), (label,state['calls'])

def check(label, expected, **updates):
    state.update(mergeable='clean',runs_status='completed',run_conclusion='success',
                 job_status='completed',job_conclusion='success',status_state='success',
                 total=0,statuses=[],jobs_mode='normal',fallback=False,calls=[])
    state.update(updates)
    try: m._finalize('acme/widget','plan','feature/x','dev')
    except m.Refusal as exc:
        actual=exc.exit_code if isinstance(exc,m.FinalizeFailure) else 1
        assert actual==expected, (label,actual,str(exc))
        if expected==5: assert str(exc).startswith('pending:'), (label,str(exc))
    else:
        assert expected==0, (label,'unexpected success')
    assert not any(method in ('POST','PUT','PATCH','DELETE') for method,endpoint in state['calls']), (label,state['calls'])

check('pending run plus completed failing status refuses',1,runs_status='in_progress',run_conclusion=None,
      job_status='in_progress',job_conclusion=None,status_state='failure',total=1,
      statuses=[{'context':'external','state':'failure'}])
for mergeable in ('blocked','unstable'):
    check(mergeable+' with pending run',5,mergeable=mergeable,runs_status='in_progress',
          run_conclusion=None,job_status='in_progress',job_conclusion=None)
    check(mergeable+' without pending run',1,mergeable=mergeable)
check('pending combined status with entries',5,status_state='pending',total=1,
      statuses=[{'context':'external','state':'pending'}])
check('zero-count pending combined status is not pending',1,mergeable='blocked',
      status_state='pending',total=0,statuses=[])
check('empty jobs preserves pending run',5,fallback=True,runs_status='in_progress',
      run_conclusion=None,job_status='in_progress',job_conclusion=None,jobs_mode='empty')

# Run the real decision function across mark-ready: its second, strict decision must refuse.
import json, os, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp).resolve(); repo=root/'repo'; repo.mkdir(); home=root/'home'
    subprocess.run(['git','init','-q','-b','main',str(repo)],check=True)
    subprocess.run(['git','-C',str(repo),'config','user.name','Test'],check=True)
    subprocess.run(['git','-C',str(repo),'config','user.email','test@example.com'],check=True)
    plan=repo/'plan.md'; plan.write_text('---\nrevision: r1\n---\nplan\n')
    (repo/'tracked').write_text('test\n'); subprocess.run(['git','-C',str(repo),'add','.'],check=True)
    subprocess.run(['git','-C',str(repo),'commit','-qm','init'],check=True)
    real_head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
    real_base='b'*40; task=str(plan.resolve()); policy=home/'.config/handoff/project-policy.json'
    policy.parent.mkdir(parents=True)
    policy.write_text(json.dumps({'version':1,'repositories':{str(repo):{'enabled':True,'overrides':[],
        'assessments':[{'task':task,'revision':'r1','risk':'ordinary','reason':'test'}],
        'hold':False,'task_holds':[]}}}))
    (repo/'plan.final-review.json').write_text(json.dumps({'feature':task,'repo':str(repo),'head':real_head,
        'base':real_base,'verdict':'PASS','blockers':'none','risk':'ordinary'}))
    real_state={'ready':False,'calls':[]}
    real_body=f'''## Feature
f
## Acceptance
a
## Final review
{real_head}
## CI
c
## Limitations
n'''
    assert real_head in m._pr_body_sections(real_body)['Final review'], repr(real_body)
    def real_gh(method, endpoint, fields=None, **kw):
        real_state['calls'].append((method,endpoint))
        if endpoint.endswith('/pulls?state=all&head=acme:feature/x'):
            return [{'number':7,'state':'open','head':{'ref':'feature/x','sha':real_head,'repo':{'full_name':'acme/widget'}},
                     'base':{'ref':'dev','sha':real_base,'repo':{'full_name':'acme/widget'}}}]
        if endpoint.endswith('/pulls/7'):
            return {'number':7,'node_id':'node','body':real_body,'draft':True,'state':'open',
                    'mergeable_state':'blocked' if real_state['ready'] else 'clean',
                    'head':{'ref':'feature/x','sha':real_head,'repo':{'full_name':'acme/widget'}},
                    'base':{'ref':'dev','sha':real_base,'repo':{'full_name':'acme/widget'}}}
        if endpoint.endswith('/protection/required_status_checks'): return {'contexts':['ci'],'checks':[]}
        if '/actions/runs?head_sha=' in endpoint:
            return [{'workflow_runs':[{'id':1,'workflow_id':1,'name':'ci','event':'push','head_sha':real_head,
                'status':'completed','conclusion':'success','created_at':'now'}]}]
        if '/actions/runs/1/jobs?' in endpoint: return [{'jobs':[{'name':'ci','status':'completed','conclusion':'success'}]}]
        if endpoint.endswith('/commits/'+real_head+'/status'): return {'state':'success','total_count':0,'statuses':[]}
        if endpoint=='graphql': real_state['ready']=True; return {}
        raise AssertionError((method,endpoint))
    m._load=lambda: json.loads(policy.read_text())
    m._gh=real_gh
    m._finalize_decision=real_decision
    os.environ['HOME']=str(home)
    try: m._finalize('acme/widget',str(plan),'feature/x','dev')
    except m.Refusal as exc:
        assert 'refused after marking ready:' in str(exc), str(exc)
    else: raise AssertionError('post-ready blocked PR unexpectedly finalized')
    assert ('POST','graphql') in real_state['calls'], real_state['calls']
    assert not any(method=='PUT' and endpoint.endswith('/merge') for method,endpoint in real_state['calls']), real_state['calls']
    m._gh=gh
    m._load=lambda: None
print('pending CI and completed-failure finalize checks passed')
PY
chmod +x "$SANDBOX/kit/handoff-merge.py"
python3 -m py_compile "$SANDBOX/kit/handoff-merge.py"
echo ok
