#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../lib.sh"
sandbox_init
python3 - "$SANDBOX" "${HANDOFF_SCRIPTS_DIR:-$REPO_ROOT}" <<'PY'
import json, os, pathlib, subprocess, sys
root, scripts = map(pathlib.Path, sys.argv[1:])
repo = root/'repo'; repo.mkdir()
home = root/'home'; env = dict(os.environ, HOME=str(home))
(repo/'plan.md').write_text('---\nrevision: r1\nphases:\n  - name: one\n    briefs: [first.md, second.md]\n---\n# Feature title\n\n## Goal\nDo the useful thing.\n')
subprocess.run(['git','init','-q',str(repo)],check=True)
subprocess.run(['git','-C',str(repo),'config','user.name','Test'],check=True)
subprocess.run(['git','-C',str(repo),'config','user.email','test@example.com'],check=True)
(repo/'tracked').write_text('one\n'); subprocess.run(['git','-C',str(repo),'add','.'],check=True)
subprocess.run(['git','-C',str(repo),'commit','-qm','init'],check=True)
head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(); base='b'*40
plan=str((repo/'plan.md').resolve())
evidence={'feature':plan,'repo':str(repo),'head':head,'base':base,'verdict':'PASS','blockers':'none','risk':'ordinary'}
evpath=repo/'plan.final-review.json'; evpath.write_text(json.dumps(evidence))
bin=root/'bin'; bin.mkdir(exist_ok=True); state=root/'state.json'; log=root/'calls.log'; ctl=root/'control.json'
ctl.write_text(json.dumps({'body':'Free-form operator text.\nKeep these bytes.'})); state.write_text('{}'); log.write_text('')
(bin/'gh').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['FAKE_ROOT']); ctlp=root/'control.json'; log=root/'calls.log'; c=json.loads(ctlp.read_text()); a=sys.argv[1:]
method=a[a.index('-X')+1] if '-X' in a else 'GET'; ep=next((x for x in a if x.startswith('repos/')), '')
log.open('a').write(method+' '+ep+'\\n')
head=os.environ['FAKE_HEAD']; base=os.environ['FAKE_BASE']; number=7
row={'number':number,'state':'closed' if c.get('merged') else 'open','merged_at':'2026-01-01' if c.get('merged') else None,'head':{'ref':'feature/x','sha':c.get('list_head',head),'repo':{'full_name':c.get('head_repo','acme/widget')}},'base':{'ref':'dev','sha':base,'repo':{'full_name':c.get('base_repo','acme/widget')}}}
if ep.endswith('/pulls?state=all&head=acme:feature/x'):
 rows=c.get('rows',[row]); print(json.dumps(rows)); sys.exit(0)
if ep.endswith('/pulls/7') and method=='GET':
 if c.get('readback_error') and c.get('patched'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 if c.get('readback_invalid') and c.get('patched'): print('{invalid'); sys.exit(0)
 body=c.get('readback_body') if c.get('patched') and 'readback_body' in c else c.get('body','')
 print(json.dumps({'state':'open','body':body,'head':row['head'],'base':row['base']})); sys.exit(0)
if ep.endswith('/pulls/7') and method=='PATCH':
 c['patches']=c.get('patches',0)+1; c['patched']=True
 body=next((x[5:] for x in a if x.startswith('body=')),None)
 if body is None: print('no body field',file=sys.stderr); sys.exit(8)
 c['written_body']=body
 if not c.get('patch_error'): c['body']=body
 ctlp.write_text(json.dumps(c))
 if c.get('patch_error'): print('HTTP 500',file=sys.stderr); sys.exit(1)
 if c.get('patch_invalid'): print('{invalid'); sys.exit(0)
 print('{}'); sys.exit(0)
sys.exit(8)
'''); (bin/'gh').chmod(0o755)
runenv=dict(env,PATH=f'{bin}:/usr/bin:/bin',GH_TOKEN='fake',GH_HOST='github.com',FAKE_ROOT=str(root),FAKE_HEAD=head,FAKE_BASE=base)
argv=['python3',str(scripts/'handoff-merge.py'),'pr-body','--repository','acme/widget','--plan',plan,'--branch','feature/x']
def run(label, cfg, code, contains=None, patches=None):
 ctl.write_text(json.dumps(cfg)); log.write_text('')
 p=subprocess.run(argv,text=True,capture_output=True,env=runenv)
 calls=log.read_text().splitlines(); patch_count=sum(x.startswith('PATCH ') for x in calls)
 expected=0 if code==0 else (1 if code==1 else 3)
 assert p.returncode==expected, f'{label}: exit={p.returncode}, expected={expected}; out={p.stdout!r} err={p.stderr!r} calls={calls}'
 if contains and contains not in (p.stdout+p.stderr): raise AssertionError(f'{label}: missing {contains!r}: {p.stdout!r} {p.stderr!r}')
 if patches is not None and patch_count!=patches: raise AssertionError(f'{label}: PATCH count {patch_count}, calls={calls}')
 if code==1 and any(x.split(' ',1)[0] in ('PATCH','PUT','POST','DELETE') for x in calls): raise AssertionError(f'{label}: refusal mutated forge: {calls}')
 if code==0 and 'already merged' not in (p.stdout+p.stderr):
  assert patch_count==1 and sum(x.startswith('GET repos/acme/widget/pulls/7') for x in calls)==2, f'{label}: missing PATCH/read-back: {calls}'
 return p,calls
p,calls=run('free-form',{'body':'Free-form operator text.\nKeep these bytes.'},0,'pr-body: written #7',1)
written=json.loads(ctl.read_text())['written_body']
assert written.startswith('Free-form operator text.\nKeep these bytes.\n\n<!-- handoff:merge-sections -->\n'),written
assert '## Feature\nFeature title — Do the useful thing.' in written
assert '- first.md\n- second.md' in written
assert '## Final review\nPASS — head '+head+', base '+base+', risk ordinary' in written
assert written.endswith('<!-- /handoff:merge-sections -->\n')
old='prefix\n<!-- handoff:merge-sections -->\nold managed text\n<!-- /handoff:merge-sections -->\nsuffix\n'
run('replace block',{'body':old},0,'pr-body: written #7',1)
new=json.loads(ctl.read_text())['written_body']
assert new.startswith('prefix\n<!-- handoff:merge-sections -->') and new.endswith('<!-- /handoff:merge-sections -->\nsuffix\n')
assert 'old managed text' not in new and new.count('<!-- handoff:merge-sections -->')==1
for label,body in [('lone start','x\n<!-- handoff:merge-sections -->'),('lone end','<!-- /handoff:merge-sections -->'),('reversed','<!-- /handoff:merge-sections -->\n<!-- handoff:merge-sections -->'),('two pairs','<!-- handoff:merge-sections -->\nx\n<!-- /handoff:merge-sections -->\n<!-- handoff:merge-sections -->\nx\n<!-- /handoff:merge-sections -->')]:
 run(label,{'body':body},1,'malformed managed block',0)
for label,cfg,match in [
 ('base main',{'body':'x'},'automatic PR body writes only target dev'),
 ('no PR',{'rows':[]},'pull request candidates: none'),
 ('two PRs',{'rows':[{'number':7,'state':'open','head':{'ref':'feature/x','sha':head,'repo':{'full_name':'acme/widget'}},'base':{'ref':'dev','repo':{'full_name':'acme/widget'}}},{'number':8,'state':'open','head':{'ref':'feature/x','sha':head,'repo':{'full_name':'acme/widget'}},'base':{'ref':'dev','repo':{'full_name':'acme/widget'}}}]},'pull request candidates: 7, 8'),
 ('head mismatch',{'list_head':'d'*40},'pull request candidates: none'),
 ('foreign head repo',{'head_repo':'other/repo'},'pull request candidates: none'),
 ('invalid evidence',{'body':'x','evidence':'bad'},'invalid final-review evidence'),
 ('missing evidence',{'body':'x','evidence':'missing'},'invalid final-review evidence'),
 ('missing revision',{'body':'x','revision':'missing'},'plan revision is missing'),
 ('readback missing section',{'body':'x','readback_body':'## Feature\nx\n'},'pr-body written but not verified'),
 ('patch failure',{'body':'x','patch_error':True},'pr-body written but not verified'),
 ('patch invalid JSON',{'body':'x','patch_invalid':True},'pr-body written but not verified'),
 ('readback GET failure',{'body':'x','readback_error':True},'pr-body written but not verified'),
 ('readback invalid JSON',{'body':'x','readback_invalid':True},'pr-body written but not verified'),
]:
 if label=='base main':
  ctl.write_text(json.dumps(cfg)); log.write_text('')
  p=subprocess.run(argv+['--base','main'],text=True,capture_output=True,env=runenv); calls=log.read_text().splitlines()
  assert calls==[], f'base main reached the forge: {calls}'
 elif label in ('invalid evidence','missing evidence','missing revision'):
  if label=='invalid evidence': evpath.write_text('{invalid')
  elif label=='missing evidence': evpath.unlink()
  else: (repo/'plan.md').write_text('---\nphases:\n  - name: one\n    briefs: [first.md]\n---\n# Feature\n')
  p,calls=run(label,cfg,1,match,0)
  if label in ('invalid evidence','missing evidence'): evpath.write_text(json.dumps(evidence))
  else: (repo/'plan.md').write_text('---\nrevision: r1\nphases:\n  - name: one\n    briefs: [first.md, second.md]\n---\n# Feature title\n\n## Goal\nDo the useful thing.\n')
  continue
 else: p,calls=run(label,cfg,3 if label.startswith(('readback','patch')) else 1,match,1 if label.startswith(('readback','patch')) else 0); continue
 assert p.returncode==1 and match in p.stderr, f'{label}: {p.returncode} {p.stdout} {p.stderr}'
 assert not any(x.split(' ',1)[0] in ('PATCH','PUT','POST','DELETE') for x in calls)
# Candidate identity must also match on the re-fetch before the write.
ctl.write_text(json.dumps({'body':'x','list_head':head,'head_repo':'acme/widget'})); log.write_text('')
# A valid reviewed merged PR is reconciled without writing.
run('already merged',{'merged':True,'body':'x'},0,'pr-body: already merged',0)
print('pr-body: managed block, evidence, candidate selection, refusal, write, and verification cases passed')
PY
