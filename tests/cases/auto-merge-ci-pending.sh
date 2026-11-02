#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
python3 - "$SANDBOX/kit/handoff-merge.py" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('merge', sys.argv[1]); m=importlib.util.module_from_spec(spec); sys.modules['merge']=m; spec.loader.exec_module(m)
head='a'*40
m._finalize_decision=lambda *a,**kw: ('repo','task','r1',7,head,'b'*40,False)
body='## Feature\nf\n## Acceptance\na\n## Final review\n'+head+'\n## CI\nc\n## Limitations\nn'
state={'mergeable':'clean','runs_status':'in_progress','run_conclusion':None,'job_status':'in_progress','job_conclusion':None,'calls':[]}
def gh(method, endpoint, fields=None, **kw):
    state['calls'].append((method,endpoint))
    if endpoint.endswith('/pulls/7'): return {'body':body,'draft':False,'mergeable_state':state['mergeable']}
    if endpoint.endswith('/protection/required_status_checks'): return {'contexts':['ci'],'checks':[]}
    if '/actions/runs?head_sha=' in endpoint: return [{'workflow_runs':[{'id':1,'workflow_id':1,'name':'ci','event':'push','head_sha':head,'status':state['runs_status'],'conclusion':state['run_conclusion'],'created_at':'now'}]}]
    if '/actions/runs/1/jobs?' in endpoint: return [{'jobs':[{'name':'ci','status':state['job_status'],'conclusion':state['job_conclusion']}]}]
    if endpoint.endswith('/commits/'+head+'/status'): return {'state':'success','total_count':0,'statuses':[]}
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
print('pending CI and completed-failure finalize checks passed')
PY
chmod +x "$SANDBOX/kit/handoff-merge.py"
python3 -m py_compile "$SANDBOX/kit/handoff-merge.py"
echo ok
