---
name: handoff-close
description: Close out an implementation run from a brief by emitting the self-checked COMPLETION REPORT block. Use when a brief or prompt says "finish by running /handoff-close", when a run of a brief is complete or has to stop, or when the user says "close the run", "completion report", "handoff close".
---

You are the last act of a session that executed an implementation brief. Your job is to
report what actually happened, audited against the repository — not remembered. Do not
substitute another completion, verification or plan-execution skill for this one; the
author's tooling parses exactly the block below.

## 0. Stop changing things

From this point: no new edits, no new commits, no pushes, no branch changes. If work is
genuinely unfinished, it goes under `NOT DONE`, not into a last-minute commit.

## 1. Collect the facts from git and the shell, not from memory

In one batched Bash call: `git branch --show-current`, `git status --short`,
`git log --oneline <base>..HEAD` (the base is the branch the brief said you started from,
or `origin/<branch>` if you pushed), `git diff --stat <base>..HEAD`, and the open PR if
any (`gh pr view --json number,url,state,title` when `gh` exists; on a GitLab origin,
`glab mr list --source-branch <branch>` — `gh` cannot reach GitLab).

Re-run the brief's verification commands now — every one its Done-when names
(`scripts/verify.sh`, the test runners, the grep gates). Capture the exact exit codes and
the one output line that proves each result. A verification you did not run in this step
does not exist.

Run each verification command as its own foreground Bash call with `timeout: 900000`, never
chained or batched with another: two long ones in one call can pass the timeout together,
and a session that ends "I'll write the verdict when it finishes" leaves no report at all.

## 2. Self-check — yours alone

Check each `DONE` claim you are about to make against what step 1 printed: the commit
exists and holds what the claim says, the files match the task, the verification result
is the one you saw. Hand this to no other agent: the check is yours, and the `audit:`
line counts it — a claim you did not re-check is unconfirmed.

It is not the verdict. After this session the launcher re-runs every §4 command itself,
and a fresh close session judges those results and this report. A long session is the
least reliable witness to its own run and its failure mode is over-reporting success, so
anything you refute or cannot confirm rules out `COMPLETE` here too.

## 3. Outcome — mechanical

- every task done, every claim confirmed, verification exit 0 → `COMPLETE`
- some tasks done, or any claim unconfirmed/refuted, or a verification not 0 → `PARTIAL`
- nothing shippable landed, or the run could not proceed → `BLOCKED`

## 4. Emit the block — exactly this shape

```
=== COMPLETION REPORT ===
brief-revision: <the revision you echoed at session start>
repo: <basename of the working directory>   branch: <actual>   tree: clean | <n> modified
audit: <n> checked, <n> refuted, <n> unconfirmed
audit-refuted: <the claim, one line each — omit this key when none>
outcome: COMPLETE | PARTIAL | BLOCKED
--- DONE ---
- <task> — <commit sha> — evidence: <command> -> <exit code / key output>
--- DIVERGED ---
- <what the brief said> -> <what was done instead> — because: <reason>
--- BRIEF WAS WRONG ---
- <claim> -> <reality>
--- NOT DONE ---
- <task> — <why: out of context, blocked, deliberately deferred>
--- STATE AT STOP ---
branch / PR / migrations / running services / anything left dirty
--- VERIFICATION RUN ---
<command> -> <exit code>, <the actual output line that proves it>
--- PAIN POINTS ---
- <what cost time> — <machine-catchable? y/n>
=== END COMPLETION REPORT ===
```

Rules for the block:
- `--- VERIFICATION RUN ---` may not contain a claim without its command and its output.
  "Tests pass" with nothing behind it is the exact assertion this step exists to refuse.
- `DIVERGED` is for choices you made against the brief's text, each with its reason;
  `BRIEF WAS WRONG` is for facts the brief stated that the repo contradicted. Keep them
  apart — one becomes a recorded decision, the other corrects the next brief.
- `PAIN POINTS`: what cost time, stated as what happened and what it cost. Do not
  prescribe the fix; say whether a hook, test or lint could have caught it (y/n).
- An empty section keeps its header and one line `- none`, exactly that token first; an
  explanation may follow it on the same line (`- none — all of §7 done`). A launcher
  reads `NOT DONE` literally, so anything that is not `- none` counts as unfinished work.
- `NOT DONE` covers §4 Done-when and §7 tasks only. The brief's §11 *Human checks (after
  the run)* is not yours: do not attempt those items, do not list them anywhere in the
  report, not even as "deferred". If a §4 or §7 item turned out to need a human (a live
  browser, credentials you lack), it is genuinely `NOT DONE` — say why, and the debrief
  moves it.
- Files you were told not to touch (pre-existing dirty files, other people's work) are
  listed under `STATE AT STOP` as left alone, so the author can tell them from yours.
- After `=== END COMPLETION REPORT ===`, nothing. No summary, no offer of next steps.
