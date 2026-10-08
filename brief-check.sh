#!/usr/bin/env bash
# Checks a brief's perishable claims against its repo, as of any time, and prints a
# branch's git facts in one command. Standard library only; git run through subprocess
# argument lists, never a shell string. Read-only: never writes into a repo, never
# fetches.
set -euo pipefail
export PYTHONIOENCODING=utf-8
BRIEF_CHECK_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export BRIEF_CHECK_DIR
exec python3 - "$@" <<'PY'
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone

USAGE_LINES = [
    "brief-check <brief.md> [--at <ISO time>] [--repo <dir>] [--branch <name>]",
    "brief-check --facts <repo> <branch>",
    "brief-check --done-when <brief.md>",
    "brief-check --backtest <labels.tsv> [--vault <dir>] [--fail <checks>]",
    "brief-check --help",
]


def usage_error():
    sys.stderr.write("usage: " + USAGE_LINES[0] + "\n")
    for l in USAGE_LINES[1:]:
        sys.stderr.write("       " + l + "\n")
    sys.exit(2)


def print_help():
    for l in USAGE_LINES:
        print(l)


# ---------------------------------------------------------------------------
# git plumbing
# ---------------------------------------------------------------------------

def run_git(repo, args):
    try:
        p = subprocess.run(['git', '-C', repo] + args,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except (OSError, FileNotFoundError):
        return 127, '', ''
    out = p.stdout.decode('utf-8', errors='replace')
    err = p.stderr.decode('utf-8', errors='replace')
    return p.returncode, out, err


def is_git_repo(repo):
    if not os.path.isdir(repo):
        return False
    rc, out, err = run_git(repo, ['rev-parse', '--show-toplevel'])
    return rc == 0


def toplevel(repo):
    rc, out, err = run_git(repo, ['rev-parse', '--show-toplevel'])
    return out.strip() if rc == 0 else repo


def git_time(dt):
    return dt.isoformat()


def ref_exists_now(repo, full_ref):
    if full_ref == 'HEAD':
        rc, out, err = run_git(repo, ['rev-parse', '-q', '--verify', 'HEAD'])
        return rc == 0
    rc, out, err = run_git(repo, ['rev-parse', '-q', '--verify', full_ref])
    return rc == 0


def reflog_lines(repo, full_ref):
    rc, out, err = run_git(repo, ['reflog', 'show', '--date=iso-strict', '--format=%gd', full_ref])
    if rc != 0:
        return None
    lines = [l for l in out.split('\n') if l.strip()]
    return lines


def parse_reflog_time(line):
    idx = line.rfind('@{')
    tstr = line[idx + 2:-1]
    dt = datetime.fromisoformat(tstr)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def oldest_reflog_time(repo, full_ref):
    lines = reflog_lines(repo, full_ref)
    if not lines:
        return None
    return parse_reflog_time(lines[-1])


def ref_exists_at_T(repo, full_ref, T):
    if not ref_exists_now(repo, full_ref):
        return False
    if full_ref == 'HEAD':
        return True
    oldest = oldest_reflog_time(repo, full_ref)
    if oldest is None:
        return True
    return oldest <= T


def rev_list_before(repo, full_ref, T):
    rc, out, err = run_git(repo, ['rev-list', '-1', '--before=' + git_time(T), full_ref])
    out = out.strip()
    return out if out else None


def commit_at_T(repo, full_ref, T, at_given):
    if not at_given:
        rc, out, err = run_git(repo, ['rev-parse', '-q', '--verify', full_ref])
        return out.strip() if rc == 0 else None
    if not ref_exists_now(repo, full_ref):
        return None
    lines = reflog_lines(repo, full_ref)
    has_reflog = bool(lines)
    if not has_reflog:
        return rev_list_before(repo, full_ref, T)
    oldest = parse_reflog_time(lines[-1])
    if oldest > T:
        if full_ref == 'HEAD':
            return rev_list_before(repo, full_ref, T)
        return None
    rc, out, err = run_git(repo, ['rev-parse', '-q', '--verify', '%s@{%s}' % (full_ref, git_time(T))])
    return out.strip() if rc == 0 else None


def resolve_branch_ref_name(repo, name, T, at_given):
    def exists(full):
        return ref_exists_at_T(repo, full, T) if at_given else ref_exists_now(repo, full)

    if name.startswith('origin/'):
        full = 'refs/remotes/' + name
        return full if exists(full) else None
    full_local = 'refs/heads/' + name
    if exists(full_local):
        return full_local
    full_origin = 'refs/remotes/origin/' + name
    return full_origin if exists(full_origin) else None


def short_ref(full):
    if full == 'HEAD':
        return 'HEAD'
    if full.startswith('refs/heads/'):
        return full[len('refs/heads/'):]
    if full.startswith('refs/remotes/'):
        return full[len('refs/remotes/'):]
    return full


def resolve_checked_ref(repo, branch, T, at_given):
    if branch:
        full = resolve_branch_ref_name(repo, branch, T, at_given)
        if full:
            commit = commit_at_T(repo, full, T, at_given)
            if commit:
                return full, commit
    for full in ('refs/remotes/origin/dev', 'refs/remotes/origin/main'):
        ok = ref_exists_at_T(repo, full, T) if at_given else ref_exists_now(repo, full)
        if ok:
            commit = commit_at_T(repo, full, T, at_given)
            if commit:
                return full, commit
    commit = commit_at_T(repo, 'HEAD', T, at_given)
    return 'HEAD', commit


def latest_tag_at_T(repo, T):
    rc, out, err = run_git(repo, ['for-each-ref', 'refs/tags',
                                   '--format=%(refname:short)\t%(creatordate:iso-strict)\t%(*objectname)\t%(objectname)'])
    if rc != 0:
        return None, None
    best = None
    for line in out.split('\n'):
        if not line.strip():
            continue
        parts = line.split('\t')
        if len(parts) < 4:
            continue
        name, dstr = parts[0], parts[1]
        sha = parts[2] if parts[2] else parts[3]
        try:
            d = datetime.fromisoformat(dstr)
        except ValueError:
            continue
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        if d > T:
            continue
        if best is None:
            best = (d, name, sha)
        else:
            bd, bname, bsha = best
            if d > bd or (d == bd and _vcmp(name, bname) > 0):
                best = (d, name, sha)
    if best is None:
        return None, None
    return best[1], best[2]


def _vkey(name):
    return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', name)]


def _vcmp(a, b):
    ka, kb = _vkey(a), _vkey(b)
    return (ka > kb) - (ka < kb)


def tag_exists_at_T(repo, tagname, T):
    rc, out, err = run_git(repo, ['for-each-ref', 'refs/tags/' + tagname, '--format=%(creatordate:iso-strict)'])
    if rc != 0 or not out.strip():
        return False
    try:
        d = datetime.fromisoformat(out.strip().split('\n')[0])
    except ValueError:
        return False
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d <= T


def ls_tree(repo, commit):
    rc, out, err = run_git(repo, ['ls-tree', '-r', '--name-only', commit])
    if rc != 0:
        return []
    return [l for l in out.split('\n') if l]


def show_file(repo, commit, path):
    rc, out, err = run_git(repo, ['show', '%s:%s' % (commit, path)])
    if rc != 0:
        return None
    return out


# ---------------------------------------------------------------------------
# brief parsing
# ---------------------------------------------------------------------------

FENCE_OPEN_RE = re.compile(r'^(\s*)(`{3,}|~{3,})(.*)$')
SECTION_RE = re.compile(r'^##\s+§(\d+)')


def compute_fence_flags(lines):
    flags = [False] * len(lines)
    in_fence = False
    fence_char = None
    fence_len = 0
    for i, l in enumerate(lines):
        m = FENCE_OPEN_RE.match(l)
        if not in_fence:
            if m:
                fence_char = m.group(2)[0]
                fence_len = len(m.group(2))
                in_fence = True
                flags[i] = True
            else:
                flags[i] = False
        else:
            flags[i] = True
            if m and m.group(2)[0] == fence_char and len(m.group(2)) >= fence_len and m.group(3).strip() == '':
                in_fence = False
    return flags


def compute_sections(lines, fence_flags):
    sections = ['-'] * len(lines)
    cur = '-'
    for i, l in enumerate(lines):
        if not fence_flags[i]:
            m = SECTION_RE.match(l)
            if m:
                cur = m.group(1)
        sections[i] = cur
    return sections


def extract_spans(line):
    spans = []
    i = 0
    n = len(line)
    while i < n:
        if line[i] == '`':
            j = i
            while j < n and line[j] == '`':
                j += 1
            run = j - i
            k = j
            found = False
            while k < n:
                if line[k] == '`':
                    m = k
                    while m < n and line[m] == '`':
                        m += 1
                    close_run = m - k
                    if close_run == run:
                        spans.append((i, m, line[j:k]))
                        i = m
                        found = True
                        break
                    else:
                        k = m
                else:
                    k += 1
            if not found:
                i = j
        else:
            i += 1
    return spans


def strip_spans(line):
    spans = extract_spans(line)
    if not spans:
        return line
    out = []
    last = 0
    for s, e, c in spans:
        out.append(line[last:s])
        last = e
    out.append(line[last:])
    return ''.join(out)


def read_frontmatter(lines):
    if not lines or lines[0].strip() != '---':
        return {}
    end = None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == '---':
            end = idx
            break
    if end is None:
        return {}
    fm = {}
    for l in lines[1:end]:
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$', l)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        val = re.sub(r'\s+#.*$', '', val)
        if len(val) >= 2 and val[0] in '"\'' and val[-1] == val[0]:
            val = val[1:-1]
        fm[key] = val
    return fm


# ---------------------------------------------------------------------------
# tokens
# ---------------------------------------------------------------------------

SHA_RE = re.compile(r'(?<![A-Za-z0-9_#-])[0-9a-fA-F]{7,40}(?![A-Za-z0-9_-])')
BRANCH_PREFIXES = ('feat/', 'fix/', 'chore/', 'release/', 'hotfix/', 'refactor/',
                    'docs/', 'test/', 'build/', 'ci/', 'perf/', 'style/')


def find_sha_tokens(line):
    out = []
    for m in SHA_RE.finditer(line):
        tok = m.group(0)
        if any(c in '0123456789' for c in tok) and any(c.lower() in 'abcdef' for c in tok):
            out.append((m.start(), m.end(), tok))
    return out


def is_branch_token_text(text, brief_branch):
    if text in ('main', 'master', 'dev'):
        return True
    if brief_branch and text == brief_branch:
        return True
    if not re.fullmatch(r'[A-Za-z0-9._/-]+', text) or text.endswith('/'):
        return False
    if text.startswith('origin/'):
        return len(text) > len('origin/')
    for p in BRANCH_PREFIXES:
        if text.startswith(p):
            last = text.rsplit('/', 1)[-1]
            if '.' in last and last.rsplit('.', 1)[-1] in PATH_EXTS:
                return False
            return len(text) > len(p)
    return False


def find_branch_tokens(line, brief_branch):
    out = []
    for s, e, c in extract_spans(line):
        if is_branch_token_text(c, brief_branch):
            out.append((s, e, c))
    return out


ANOTHER_REPO_RE = re.compile(r'(?:(?<=[\s`(])|^)(/[A-Za-z0-9_.\-/]+|~/[A-Za-z0-9_.\-/]*)')


def line_is_another_repo(line, repo_path):
    for m in re.finditer(r'`([^`]*)`', line):
        c = m.group(1)
        if c.startswith('/') or c.startswith('~/'):
            resolved = os.path.expanduser(c)
            try:
                if os.path.commonpath([os.path.realpath(resolved), os.path.realpath(repo_path)]) != os.path.realpath(repo_path):
                    return True
            except Exception:
                return True
    return False


# ---------------------------------------------------------------------------
# blocks and other repos
# ---------------------------------------------------------------------------

ITEM_RE = re.compile(r'^(\s*)(?:[-*+]|\d+[.)])\s+')
ABS_PATH_RE = re.compile(r'(?<![A-Za-z0-9_.~/-])(~?/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)')
PUSH_RE = re.compile(r'\bpush(?:es|ed|ing)?\b', re.IGNORECASE)


def compute_blocks(lines, fence_flags):
    """A block is a top-level list item with its continuation and nested lines, a
    paragraph, a heading, or a fence at column 0. Returns one block id per line."""
    blocks = [0] * len(lines)
    bid = 0
    force_new = True
    prev_blank = True
    fence_top = False
    for i, l in enumerate(lines):
        indent = len(l) - len(l.lstrip())
        if fence_flags[i]:
            if i == 0 or not fence_flags[i - 1]:
                fence_top = indent == 0
                if fence_top:
                    bid += 1
            blocks[i] = bid
            if fence_top:
                force_new = True
            prev_blank = False
            continue
        if not l.strip():
            blocks[i] = bid
            prev_blank = True
            continue
        heading = l.lstrip().startswith('#')
        top_item = ITEM_RE.match(l) is not None and indent <= 1
        if force_new or heading or top_item or (prev_blank and indent == 0):
            bid += 1
        blocks[i] = bid
        force_new = heading
        prev_blank = False
    return blocks


_TOPLEVEL_OF = {}


def repo_toplevel_of(path):
    if path in _TOPLEVEL_OF:
        return _TOPLEVEL_OF[path]
    p = path
    while p and p != '/' and not os.path.exists(p):
        p = os.path.dirname(p)
    top = None
    if p and p != '/':
        d = p if os.path.isdir(p) else os.path.dirname(p)
        rc, out, err = run_git(d, ['rev-parse', '--show-toplevel'])
        if rc == 0 and out.strip():
            top = os.path.realpath(out.strip())
    _TOPLEVEL_OF[path] = top
    return top


_SIBLINGS = {}


def sibling_repos(top_real):
    """(name, path) of every checkout beside the brief's repo."""
    if top_real in _SIBLINGS:
        return _SIBLINGS[top_real]
    parent = os.path.dirname(top_real)
    out = []
    try:
        names = sorted(os.listdir(parent))
    except OSError:
        names = []
    for d in names:
        full = os.path.join(parent, d)
        if os.path.realpath(full) == top_real:
            continue
        if os.path.exists(os.path.join(full, '.git')):
            out.append((d, os.path.realpath(full)))
    _SIBLINGS[top_real] = out
    return out


def other_repos_in_text(text, top_real, siblings):
    found = []
    for m in ABS_PATH_RE.finditer(text):
        t = repo_toplevel_of(os.path.expanduser(m.group(1)))
        if t and t != top_real and t not in found:
            found.append(t)
    for name, full in siblings:
        if full in found:
            continue
        if re.search(r'(?<![A-Za-z0-9_-])' + re.escape(name) + r'(?![A-Za-z0-9_-])', text):
            found.append(full)
    return found


def build_context(lines, fence_flags, repo):
    blocks = compute_blocks(lines, fence_flags)
    raw = {}
    start = {}
    for i, l in enumerate(lines):
        raw.setdefault(blocks[i], []).append(l)
        start.setdefault(blocks[i], i)
    block_raw = {b: '\n'.join(ls) for b, ls in raw.items()}
    top_real = os.path.realpath(toplevel(repo))
    sibs = sibling_repos(top_real)
    alts = {}
    for b, text in block_raw.items():
        a = other_repos_in_text(text, top_real, sibs)
        if a:
            alts[b] = a
    return {'lines': lines, 'fence_flags': fence_flags, 'blocks': blocks,
            'block_raw': block_raw, 'block_start': start, 'alts': alts}


def ctx_alts(ctx, i):
    return ctx['alts'].get(ctx['blocks'][i], []) if ctx else []


def ctx_block_raw(ctx, i):
    return ctx['block_raw'].get(ctx['blocks'][i], '') if ctx else ''


def ctx_prefix(ctx, i, s):
    """The block's text before column s of line i, spans stripped, fences left out."""
    if not ctx:
        return ''
    lines = ctx['lines']
    parts = []
    for j in range(ctx['block_start'][ctx['blocks'][i]], i):
        if not ctx['fence_flags'][j]:
            parts.append(strip_spans(lines[j]).strip())
    parts.append(strip_spans(lines[i][:s]).strip())
    return ' '.join(p for p in parts if p) + ' '


_ALT_FACTS = {}


def alt_repo_facts(alt, T, at_given):
    key = (alt, T.isoformat() if at_given else 'now')
    if key in _ALT_FACTS:
        return _ALT_FACTS[key]
    commits = []
    for full in ('refs/remotes/origin/dev', 'refs/remotes/origin/main', 'refs/remotes/origin/master',
                 'refs/heads/dev', 'refs/heads/main', 'refs/heads/master', 'HEAD'):
        ok = ref_exists_at_T(alt, full, T) if at_given else ref_exists_now(alt, full)
        if not ok:
            continue
        c = commit_at_T(alt, full, T, at_given)
        if c and c not in commits:
            commits.append(c)
    tree = set()
    for c in commits:
        tree.update(ls_tree(alt, c))
    dirs = set()
    for f in tree:
        parts = f.split('/')
        for k in range(1, len(parts)):
            dirs.add('/'.join(parts[:k]))
    basenames = {}
    for f in tree:
        basenames.setdefault(f.rsplit('/', 1)[-1], []).append(f)
    facts = {'tree': tree, 'dirs': dirs, 'basenames': basenames,
             'dir_basenames': set(d.rsplit('/', 1)[-1] for d in dirs)}
    _ALT_FACTS[key] = facts
    return facts


def sha_in_alts(sha, alts):
    for alt in alts:
        rc, out, err = run_git(alt, ['rev-parse', '-q', '--verify', sha + '^{commit}'])
        if rc == 0:
            return alt
    return None


def branch_in_alts(b, alts, T, at_given):
    for alt in alts:
        if resolve_branch_ref_name(alt, b, T, at_given):
            return alt
    return None


# ---------------------------------------------------------------------------
# path candidates
# ---------------------------------------------------------------------------

PATH_EXTS = ('py', 'js', 'ts', 'tsx', 'jsx', 'mjs', 'cjs', 'vue', 'json', 'yml', 'yaml',
             'toml', 'md', 'sh', 'sql', 'html', 'css', 'scss', 'txt', 'cfg', 'ini', 'conf',
             'lock', 'service', 'tsv', 'csv', 'go', 'rs', 'rb', 'java', 'kt', 'c', 'h', 'cpp')

NOT_CANDIDATE_CHARS = set('*<>{}()=$~|,')


def is_path_candidate(span, tree_dirs):
    if not span:
        return False
    if any(ch in NOT_CANDIDATE_CHARS for ch in span):
        return False
    if re.search(r'\s', span) or ':' in span:
        return False
    if span.startswith('-') or span.startswith('../') or span.startswith('http') or span.startswith('git@'):
        return False
    if span.startswith('/') or span.startswith('~'):
        return False
    if re.match(r'^v?\d+(\.\d+)+$', span):
        return False
    if re.match(r'^\d+$', span):
        return False
    if '/' not in span and span.startswith('.'):
        return False
    if re.search(r':\d+(-\d+)?$', span):
        return False
    has_slash = '/' in span
    trailing_slash = span.endswith('/')
    stripped = span[:-1] if trailing_slash else span
    last = stripped.rsplit('/', 1)[-1]
    ext = last.rsplit('.', 1)[-1] if '.' in last[1:] else None
    has_ext = ext is not None and ext in PATH_EXTS
    if ext is not None and not has_ext and (not re.fullmatch(r'[a-z0-9]{1,5}', ext) or ext.isdigit()):
        return False
    if not has_slash and not has_ext:
        return False
    if has_slash and not trailing_slash and ext is None:
        first = span.split('/', 1)[0]
        if first not in tree_dirs:
            return False
    return True


def path_exists(span, tree_set, tree_dirs, basenames, dir_basenames=None):
    span = span[:-1] if span.endswith('/') else span
    if '/' in span:
        for f in tree_set:
            if f == span or f.endswith('/' + span) or f.startswith(span + '/') or ('/' + span + '/') in f:
                return True
        return False
    return span in basenames or (dir_basenames is not None and span in dir_basenames)


def path_candidates_in_span(c, tree_dirs):
    """A span with whitespace is a command or a phrase: only its words that look like
    files (a slash and a known extension) are checked."""
    if not re.search(r'\s', c):
        chk = c[2:] if c.startswith('@/') else c
        chk = chk[:-1] if chk.endswith('/.') else chk
        return [c] if chk and is_path_candidate(chk, tree_dirs) else []
    out = []
    for w in c.split():
        if '://' in w or '@' in w or '"' in w or "'" in w or w.startswith('-') or '/' not in w:
            continue
        last = (w[:-1] if w.endswith('/') else w).rsplit('/', 1)[-1]
        if '.' in last[1:] and last.rsplit('.', 1)[-1] in PATH_EXTS and is_path_candidate(w, tree_dirs):
            out.append(w)
    return out


SPAN_NEG_BEFORE_RE = re.compile(
    r'(?:\bno|\buntracked|\b(?:git)?ignored|\bnot\s+(?:under|in|inside|within)(?:\s+(?:a|an|the|any))?)\s*$',
    re.IGNORECASE)
SPAN_NEG_AFTER_RE = re.compile(r'^[\s*_]*(?:is|are)\s+(?:(?:git)?ignored|untracked)\b', re.IGNORECASE)
COND_BEFORE_RE = re.compile(r'\bif\s+(?:(?:a|an|the|any)\s+)?$', re.IGNORECASE)
CREATE_DEST_RE = re.compile(r'\b(?:to|as|into)\s+$', re.IGNORECASE)


def span_negated(raw, s, e):
    return (SPAN_NEG_BEFORE_RE.search(strip_spans(raw[:s])) is not None or
            SPAN_NEG_AFTER_RE.search(raw[e:]) is not None)


NEGATION_RE = re.compile(
    r"does not exist|doesn't exist|do not exist|no longer exists|not yet created|not created yet|there is no|there are no|nowhere",
    re.IGNORECASE)

CREATE_VERBS = ('add', 'adds', 'added', 'create', 'creates', 'created', 'new', 'write',
                 'writes', 'written', 'introduce', 'introduces', 'rename', 'renames',
                 'becomes', 'generate', 'generates', 'copy', 'copies', 'copied',
                 'port', 'ports', 'ported')


def line_has_word(text, word):
    return re.search(r'\b' + re.escape(word) + r'\b', text, re.IGNORECASE) is not None


# ---------------------------------------------------------------------------
# symbol candidates
# ---------------------------------------------------------------------------

IDENT_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


def camel_or_snake(ident):
    if '_' in ident:
        return True
    return re.search(r'[a-z][A-Z]', ident) is not None


def symbol_candidates_in_span(span):
    out = []
    m = re.match(r'^var\(--([A-Za-z0-9_-]+)\)$', span)
    if m:
        out.append(m.group(1))
        return out
    if re.match(r'^--[A-Za-z0-9_-]+$', span):
        out.append(span[2:])
        return out
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\(\)$', span)
    if m:
        parts = m.group(1).split('.')
        last = parts[-1]
        if last.rsplit('.', 1)[-1] not in PATH_EXTS and len(last) >= 1:
            out.append(last)
        return out
    if '.' in span and re.match(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$', span):
        parts = span.split('.')
        last = parts[-1]
        if last not in PATH_EXTS:
            out.append(last)
        return out
    if IDENT_RE.match(span) and len(span) >= 4 and camel_or_snake(span):
        out.append(span)
    return out


# ---------------------------------------------------------------------------
# brief-mode
# ---------------------------------------------------------------------------

class Finding:
    def __init__(self, check, section, line, message):
        self.check = check
        self.section = section
        self.line = line
        self.message = message


CHECK_ORDER = {'sweep': 0, 'git': 1, 'path': 2, 'line': 3, 'symbol': 4, 'size': 5,
               'boundary': 6, 'done-when': 7}


# The kit's own repo holds the three engine scripts at its top level. "vault" is the kit's
# word for the notes repo it works with, so a brief for the kit may say it; a note path
# is still a pointer the run cannot follow.
KIT_TOP_FILES = frozenset({'handoff-launch.sh', 'handoff-orchestrate.sh', 'brief-check.sh'})


def sweep_pattern(has_top_level_projects, is_kit=False):
    alts = [r'\[\[[^\[\]\n,]+\]\]', r'02-projects/', r'/mnt/c/', r'obsidian/', r'ADR-[0-9]+', r'\bvault\b',
            r'see [^.]*\.md', r'brief-[0-9]+-[a-z-]*\.md', r'plan-[a-z-]*\.md']
    if has_top_level_projects:
        alts = [a for a in alts if a not in (r'02-projects/', r'\bvault\b')]
    elif is_kit:
        alts = [a for a in alts if a != r'\bvault\b']
    return re.compile('|'.join(alts))


def run_sweep(lines, fm_end, repo_dirs_toplevel, sections):
    findings = []
    has_projects = '02-projects' in repo_dirs_toplevel
    pat = sweep_pattern(has_projects, KIT_TOP_FILES <= set(repo_dirs_toplevel))
    for i in range(fm_end, len(lines)):
        m = pat.search(lines[i])
        if m:
            findings.append((i + 1, Finding('sweep', sections[i], i + 1, 'matched %r' % m.group(0))))
    return findings


def collect_git_findings(lines, fence_flags, sections, repo, repo_path, brief_branch, T, at_given, findings_out, ctx=None):
    git_sections = {'0', '1', '2', '3', '6'}
    for i, raw in enumerate(lines):
        sec = sections[i]
        in_fence = fence_flags[i]
        check_e1 = sec == '0'
        if in_fence and not check_e1:
            continue
        if sec not in git_sections and not (check_e1 and in_fence):
            continue
        if line_is_another_repo(raw, repo_path):
            continue
        text_for_words = strip_spans(raw).lower()

        # rule e.1: command patterns (fences included), §0 only
        if sec == '0':
            for m in re.finditer(r'git checkout -b ([A-Za-z0-9_./-]+)', raw):
                b = m.group(1)
                if not b.startswith('-'):
                    check_branch_not_exist(repo, b, T, at_given, i, findings_out, sec)
            for m in re.finditer(r'git switch -c ([A-Za-z0-9_./-]+)', raw):
                b = m.group(1)
                if not b.startswith('-'):
                    check_branch_not_exist(repo, b, T, at_given, i, findings_out, sec)
            for m in re.finditer(r'git branch ([A-Za-z0-9_./-]+)', raw):
                b = m.group(1)
                if not b.startswith('-'):
                    check_branch_not_exist(repo, b, T, at_given, i, findings_out, sec)

        if in_fence:
            continue

        branch_tokens = find_branch_tokens(raw, brief_branch)
        sha_tokens = find_sha_tokens(raw)
        alts = ctx_alts(ctx, i)
        foreign_shas = set()
        foreign_branches = set()
        if alts:
            for s, e, b in branch_tokens:
                if not resolve_branch_ref_name(repo, b, T, at_given) and branch_in_alts(b, alts, T, at_given):
                    foreign_branches.add(b)

        # rule e.2/e.3
        if sec in ('0', '2'):
            low = text_for_words
            if ('branch to create' in low or 'create the branch' in low or 'new branch' in low) and branch_tokens:
                for s, e, b in branch_tokens:
                    if b in ('main', 'master', 'dev') or b.startswith('origin/'):
                        continue
                    check_branch_not_exist(repo, b, T, at_given, i, findings_out, sec)
            if re.search(r"does not exist|doesn't exist|not yet created|not created yet", low) and len(branch_tokens) == 1:
                b = branch_tokens[0][2]
                check_branch_not_exist(repo, b, T, at_given, i, findings_out, sec)

        # rule a: every SHA token must resolve
        for s, e, sha in sha_tokens:
            rc, out, err = run_git(repo, ['rev-parse', '-q', '--verify', sha + '^{commit}'])
            if rc != 0:
                if alts and sha_in_alts(sha, alts):
                    foreign_shas.add(sha)
                    continue
                add_finding(findings_out, i, 'git', sec,
                            'SHA `%s` does not resolve to a commit' % sha)

        # rule b / b2: head & branch-point claims
        claimed_shas = set(foreign_shas)
        for s_sha, e_sha, sha in sha_tokens:
            if sha in foreign_shas:
                continue
            nearest = None
            for s_b, e_b, b in branch_tokens:
                if e_b <= s_sha:
                    if nearest is None or s_b > nearest[0]:
                        nearest = (s_b, e_b, b)
            if nearest is None:
                continue
            s_b, e_b, b = nearest
            if b in foreign_branches:
                claimed_shas.add(sha)
                continue
            between = raw[e_b:s_sha]
            between_stripped = between.replace('`', '')
            allowed = re.match(
                r'^[\s@=():,]*$', re.sub(
                    r'\b(is|now|at|tip|head|currently|the|current|checkout|checked|out)\b', '',
                    between_stripped, flags=re.IGNORECASE)) is not None
            if not allowed:
                continue
            before_branch = raw[:s_b]
            is_branch_point = re.search(
                r'(cut from|branched from|forked from|created from|branched off)\s*$',
                strip_spans(before_branch), re.IGNORECASE) is not None
            claimed_shas.add(sha)
            if is_branch_point:
                if brief_branch and b != brief_branch:
                    brief_full = resolve_branch_ref_name(repo, brief_branch, T, at_given)
                    other_full = resolve_branch_ref_name(repo, b, T, at_given)
                    if brief_full and other_full:
                        bc = commit_at_T(repo, brief_full, T, at_given)
                        oc = commit_at_T(repo, other_full, T, at_given)
                        if bc and oc:
                            rc, out, err = run_git(repo, ['merge-base', bc, oc])
                            mb = out.strip()
                            ok = rc == 0 and mb.startswith(sha)
                            if not ok:
                                add_finding(findings_out, i, 'git', sec,
                                            '`%s` is not the merge-base of `%s` and `%s`' % (sha, brief_branch, b))
                    continue
                full = resolve_branch_ref_name(repo, b, T, at_given)
                if full:
                    c = commit_at_T(repo, full, T, at_given)
                    if not (c and c.startswith(sha)):
                        add_finding(findings_out, i, 'git', sec,
                                    '`%s` is not `%s`\'s commit at T' % (sha, b))
            else:
                full = resolve_branch_ref_name(repo, b, T, at_given)
                ok = False
                if full:
                    c = commit_at_T(repo, full, T, at_given)
                    ok = bool(c and c.startswith(sha))
                if not ok and not b.startswith('origin/'):
                    for cand in ('refs/heads/' + b, 'refs/remotes/origin/' + b):
                        c = commit_at_T(repo, cand, T, at_given)
                        if c and c.startswith(sha):
                            ok = True
                            break
                if not ok:
                    add_finding(findings_out, i, 'git', sec,
                                'head claim: `%s` is not `%s`\'s commit at T' % (sha, b))

        # rule b2: own-branch claims for SHAs not already covered by a b claim
        for s_sha, e_sha, sha in sha_tokens:
            if sha in claimed_shas:
                continue
            before = strip_spans(raw[:s_sha])
            if re.search(r'\bhead\b|\btip\b', before, re.IGNORECASE) or \
               re.search(r'in sync with origin at', before, re.IGNORECASE) or \
               re.search(r'(measured|verified|checked out|read)\b.*\bat\b', before, re.IGNORECASE):
                other_branches = [b for s2, e2, b in branch_tokens if b != brief_branch]
                if other_branches:
                    continue
                if not brief_branch:
                    continue
                full = resolve_branch_ref_name(repo, brief_branch, T, at_given)
                if not full:
                    continue
                c = commit_at_T(repo, full, T, at_given)
                if not (c and c.startswith(sha)):
                    add_finding(findings_out, i, 'git', sec,
                                '`%s` is not `%s`\'s commit at T' % (sha, brief_branch))

        # rule c: tags
        low = text_for_words
        if re.search(r'\b(latest|last|newest|most recent)\b', low) and re.search(r'\b(tag|release)\b', low):
            vm = re.search(r'v?\d+(\.\d+)+', raw)
            if vm:
                claimed = vm.group(0).lstrip('v')
                tagname, tagsha = latest_tag_at_T(repo, T)
                actual = tagname.lstrip('v') if tagname else None
                if actual != claimed:
                    add_finding(findings_out, i, 'git', sec,
                                'latest tag is `%s`, not `%s`' % (tagname, vm.group(0)))
        if re.search(r'\btags?\b|\btagged\b', low) and not re.search(r'\b(will|next|new|create|bump)\b', low):
            for vm in re.finditer(r'v\d+(\.\d+)+', raw):
                tagname = vm.group(0)
                if not (tag_exists_at_T(repo, tagname, T) or tag_exists_at_T(repo, tagname[1:], T)):
                    add_finding(findings_out, i, 'git', sec, 'tag `%s` does not exist at T' % tagname)

        # rule d: counts
        for m in re.finditer(r'(\d+)\s+commits?\s+ahead\s+of\s+', low):
            n = int(m.group(1))
            after = low[m.end():]
            # find X as nearest branch token after the phrase
            x_tok = None
            for s_b, e_b, b in branch_tokens:
                if s_b >= m.end() - 20:
                    if x_tok is None or s_b < x_tok[0]:
                        x_tok = (s_b, b)
            if x_tok is None:
                continue
            x = x_tok[1]
            s_tok = None
            for s_b, e_b, b in branch_tokens:
                if e_b <= m.start():
                    if s_tok is None or s_b > s_tok[0]:
                        s_tok = (s_b, b)
            s_name = s_tok[1] if s_tok else brief_branch
            if not s_name:
                continue
            xf = resolve_branch_ref_name(repo, x, T, at_given)
            sf = resolve_branch_ref_name(repo, s_name, T, at_given)
            if not (xf and sf):
                continue
            xc = commit_at_T(repo, xf, T, at_given)
            sc = commit_at_T(repo, sf, T, at_given)
            if not (xc and sc):
                continue
            rc, out, err = run_git(repo, ['rev-list', '--count', xc + '..' + sc])
            if rc == 0:
                actual = int(out.strip() or '0')
                if actual != n:
                    add_finding(findings_out, i, 'git', sec,
                                '`%s` is %d commits ahead of `%s`, not %d' % (s_name, actual, x, n))
            rest = low[m.end():]
            bm = re.match(r'[a-z0-9_./-]+`?,\s*(\d+)\s+behind', rest)
            if bm:
                bn = int(bm.group(1))
                rc, out, err = run_git(repo, ['rev-list', '--count', sc + '..' + xc])
                if rc == 0:
                    actualb = int(out.strip() or '0')
                    if actualb != bn:
                        add_finding(findings_out, i, 'git', sec,
                                    '`%s` is %d commits behind `%s`, not %d' % (s_name, actualb, x, bn))
        m_sync = re.search(r'in sync with origin\b', low)
        if m_sync and not re.search(r'in sync with origin at', low):
            b = brief_branch
            for s_b, e_b, bt in branch_tokens:
                if e_b <= m_sync.start():
                    b = bt
            full_local = resolve_branch_ref_name(repo, b, T, at_given) if b else None
            if full_local and full_local.startswith('refs/heads/'):
                lc = commit_at_T(repo, full_local, T, at_given)
                oc = commit_at_T(repo, 'refs/remotes/origin/' + b, T, at_given)
                if lc and oc and lc != oc:
                    add_finding(findings_out, i, 'git', sec, '`%s` is not in sync with origin' % b)

        # rule f: every branch token must resolve, unless exempted
        exempt = re.search(
            r'\bcreate[sd]?\b|\bcut\b|\bnew\b|(?<![A-Za-z0-9_-])-b(?![A-Za-z0-9_-])|(?<![A-Za-z0-9_-])-c(?![A-Za-z0-9_-])|\bwill\b|does not exist|doesn\'t exist|\bnot yet\b|\bdeleted\b|\bremoved\b|there is no|\bno longer\b|\bhas no\b',
            low)
        if not exempt:
            push_block = PUSH_RE.search(ctx_block_raw(ctx, i)) is not None
            for s_b, e_b, b in branch_tokens:
                if b in foreign_branches:
                    continue
                if push_block and b in ('main', 'master', 'dev'):
                    continue
                full = resolve_branch_ref_name(repo, b, T, at_given)
                if not full:
                    add_finding(findings_out, i, 'git', sec, 'branch `%s` does not resolve at T' % b)

        # rule g
        if re.search(r'no upstream|not on origin|not pushed|has no remote|no remote branch|never pushed', low):
            non_origin = [b for s_b, e_b, b in branch_tokens if not b.startswith('origin/')]
            if len(non_origin) <= 1:
                b = non_origin[0] if non_origin else (None if branch_tokens else brief_branch)
                if b:
                    if ref_exists_at_T(repo, 'refs/remotes/origin/' + b, T) if at_given else ref_exists_now(repo, 'refs/remotes/origin/' + b):
                        add_finding(findings_out, i, 'git', sec, '`origin/%s` exists' % b)


def check_branch_not_exist(repo, b, T, at_given, line_idx, findings_out, sec):
    exists = ref_exists_at_T(repo, 'refs/heads/' + b, T) if at_given else ref_exists_now(repo, 'refs/heads/' + b)
    exists_o = ref_exists_at_T(repo, 'refs/remotes/origin/' + b, T) if at_given else ref_exists_now(repo, 'refs/remotes/origin/' + b)
    if exists or exists_o:
        add_finding(findings_out, line_idx, 'git', sec, 'branch `%s` already exists' % b)


def add_finding(findings_out, line_idx, check, sec, message):
    findings_out.append((line_idx + 1, check, sec, message))


def collect_path_symbol_findings(lines, fence_flags, sections, repo, commit, findings_out, ctx=None,
                                 T=None, at_given=False):
    path_sections = {'0', '2', '5', '9', '10'}
    tree = ls_tree(repo, commit)
    tree_set = set(tree)
    tree_dirs = set()
    for f in tree:
        parts = f.split('/')
        for k in range(1, len(parts)):
            tree_dirs.add('/'.join(parts[:k]))
    basenames = {}
    for f in tree:
        bn = f.rsplit('/', 1)[-1]
        basenames.setdefault(bn, []).append(f)
    dir_basenames = set(d.rsplit('/', 1)[-1] for d in tree_dirs)

    def exists_anywhere(span, i):
        if path_exists(span, tree_set, tree_dirs, basenames, dir_basenames):
            return True
        alts = ctx_alts(ctx, i)
        for alt in alts:
            f = alt_repo_facts(alt, T, at_given)
            if path_exists(span, f['tree'], f['dirs'], f['basenames'], f['dir_basenames']):
                return True
        for r in [repo] + alts:
            rc, out, err = run_git(r, ['check-ignore', '-q', '--', span])
            if rc == 0:
                return True
        return False

    def add_created(c):
        for w in [c] + (c.split() if re.search(r'\s', c) else []):
            creates.add(w)
            span = w[:-1] if w.endswith('/') else w
            if span.startswith('./'):
                span = span[2:]
            creates.add(span)

    creates = set()
    creates_sections = {'3', '4', '6', '7'}
    for i, raw in enumerate(lines):
        if fence_flags[i]:
            continue
        if sections[i] not in creates_sections:
            continue
        low = strip_spans(raw).lower()
        if any(re.search(r'\b' + v + r'\b', low) for v in CREATE_VERBS):
            for s, e, c in extract_spans(raw):
                add_created(c)
        elif ctx is not None:
            before = ctx_prefix(ctx, i, 0).lower()
            if any(re.search(r'\b' + v + r'\b', before) for v in CREATE_VERBS):
                for s, e, c in extract_spans(raw):
                    if CREATE_DEST_RE.search(ctx_prefix(ctx, i, s)):
                        add_created(c)

    all_symbol_candidates = []
    for i, raw in enumerate(lines):
        if fence_flags[i]:
            continue
        for s, e, c in extract_spans(raw):
            for cand in symbol_candidates_in_span(c):
                all_symbol_candidates.append(cand)
    uniq_symbols = sorted(set(all_symbol_candidates))
    grep_out_lines = []
    if uniq_symbols:
        args = ['grep', '-F', '-n', '-I', '--no-color']
        for c in uniq_symbols:
            args += ['-e', c]
        args.append(commit)
        rc, out, err = run_git(repo, args)
        if rc in (0, 1):
            grep_out_lines = [l for l in out.split('\n') if l]

    def word_class_for(cand):
        return r'[A-Za-z0-9_]'

    def occurs_in_output(cand):
        cls = word_class_for(cand)
        pat = re.compile(r'(?<!%s)%s(?!%s)' % (cls, re.escape(cand), cls))
        hits = []
        for l in grep_out_lines:
            parts = l.split(':', 3)
            if len(parts) < 4:
                continue
            _sha, path, lineno, content = parts
            if pat.search(content):
                try:
                    hits.append((path, int(lineno)))
                except ValueError:
                    continue
        return hits

    for i, raw in enumerate(lines):
        if fence_flags[i]:
            continue
        sec = sections[i]
        low = strip_spans(raw)
        is_negation = NEGATION_RE.search(low) is not None
        spans = extract_spans(raw)
        path_spans = []
        for s, e, c0 in spans:
            for c in path_candidates_in_span(c0, tree_dirs):
                span = c[2:] if c.startswith('@/') else c
                span = span[:-1] if span.endswith('/.') else span
                span = span[:-1] if span.endswith('/') else span
                path_spans.append((s, e, c, span))

        if sec in path_sections:
            if is_negation:
                if len(path_spans) == 1:
                    s, e, c, span = path_spans[0]
                    if c not in creates and span not in creates:
                        if path_exists(span, tree_set, tree_dirs, basenames, dir_basenames):
                            add_finding(findings_out, i, 'path', sec, '`%s` exists' % c)
            else:
                for s, e, c, span in path_spans:
                    if c in creates or span in creates:
                        continue
                    if ctx is not None and COND_BEFORE_RE.search(ctx_prefix(ctx, i, s)):
                        continue
                    if span_negated(raw, s, e):
                        if path_exists(span, tree_set, tree_dirs, basenames, dir_basenames):
                            add_finding(findings_out, i, 'path', sec, '`%s` exists' % c)
                        continue
                    if not exists_anywhere(span, i):
                        add_finding(findings_out, i, 'path', sec, '`%s` does not exist' % c)

        symbol_spans = []
        for s, e, c in spans:
            for cand in symbol_candidates_in_span(c):
                symbol_spans.append((s, e, c, cand))

        line_file = None
        line_file_candidates = [c for s, e, c, span in path_spans]
        if len(line_file_candidates) == 1:
            line_file = line_file_candidates[0].rstrip('/')

        if sec in {'2', '5', '9', '10'}:
            if is_negation:
                if len(symbol_spans) == 1:
                    s, e, c, cand = symbol_spans[0]
                    if c not in creates and cand not in creates:
                        if occurs_in_output(cand):
                            add_finding(findings_out, i, 'symbol', sec, '`%s` occurs in the tree' % c)
            else:
                for s, e, c, cand in symbol_spans:
                    if c in creates or cand in creates:
                        continue
                    hits = occurs_in_output(cand)
                    if not hits:
                        add_finding(findings_out, i, 'symbol', sec, '`%s` occurs in no tracked file' % c)
                    elif line_file:
                        resolved_file = resolve_file_for_ref(line_file, tree_set, basenames)
                        if resolved_file and not any(f == resolved_file for f, ln in hits):
                            add_finding(findings_out, i, 'symbol', sec,
                                        '`%s` does not occur in `%s`' % (c, resolved_file))


def resolve_file_for_ref(fname, tree_set, basenames):
    if fname in tree_set:
        return fname
    matches = [f for f in tree_set if f.endswith('/' + fname)]
    if len(matches) == 1:
        return matches[0]
    bn = fname.rsplit('/', 1)[-1]
    if bn in basenames and len(basenames[bn]) == 1:
        return basenames[bn][0]
    return None


LINE_REF_RE = re.compile(r'([A-Za-z0-9_./-]+\.[A-Za-z0-9]+):(\d+)(?:[-–](\d+))?')
BARE_LINE_REF_RE = re.compile(r'(?<![\w/.]):(\d+)(?:[-–](\d+))?')
LINES_COUNT_RE = re.compile(r'`?([A-Za-z0-9_./-]+\.[A-Za-z0-9]+)`?\s*\((\d+(?:,\d+)*)\s+lines\)')


def collect_line_findings(lines, fence_flags, sections, repo, commit, findings_out):
    tree = ls_tree(repo, commit)
    tree_set = set(tree)
    basenames = {}
    for f in tree:
        bn = f.rsplit('/', 1)[-1]
        basenames.setdefault(bn, []).append(f)

    file_cache = {}

    def get_file_lines(fname):
        resolved = resolve_file_for_ref(fname, tree_set, basenames)
        if resolved is None:
            return None, None
        if resolved not in file_cache:
            content = show_file(repo, commit, resolved)
            file_cache[resolved] = content
        content = file_cache[resolved]
        if content is None:
            return resolved, None
        n = content.count('\n')
        if content and not content.endswith('\n'):
            n += 1
        return resolved, n

    block_file = None
    for i, raw in enumerate(lines):
        if raw.strip() == '' or SECTION_RE.match(raw) or raw.lstrip().startswith('- '):
            block_file = None
        if fence_flags[i]:
            continue

        sec = sections[i]

        for m in LINES_COUNT_RE.finditer(raw):
            fname, ncount = m.group(1), int(m.group(2).replace(',', ''))
            resolved, actual = get_file_lines(fname)
            if resolved and actual is not None and abs(actual - ncount) > 1:
                add_finding(findings_out, i, 'line', sec,
                            '`%s` has %d lines, not %d' % (resolved, actual, ncount))

        refs = []
        covered_spans = []
        for m in LINE_REF_RE.finditer(raw):
            fname = m.group(1)
            ext = fname.rsplit('.', 1)[-1] if '.' in fname else None
            if ext not in PATH_EXTS:
                continue
            n = int(m.group(2))
            mm = int(m.group(3)) if m.group(3) else n
            refs.append((m.start(), fname, n, mm))
            covered_spans.append((m.start(), m.end()))

        line_file_candidates = []
        for s, e, c in extract_spans(raw):
            span = c[:-1] if c.endswith('/') else c
            base = span.rsplit('/', 1)[-1]
            ext = base.rsplit('.', 1)[-1] if '.' in base else None
            if ext in PATH_EXTS:
                line_file_candidates.append((s, span))

        for m in BARE_LINE_REF_RE.finditer(raw):
            pos = m.start()
            if any(cs <= pos < ce for cs, ce in covered_spans):
                continue
            candidates_before = [c for s, c in line_file_candidates if s < pos]
            fname = candidates_before[-1] if candidates_before else block_file
            if fname is None:
                continue
            n = int(m.group(1))
            mm = int(m.group(2)) if m.group(2) else n
            refs.append((pos, fname, n, mm))

        if line_file_candidates:
            block_file = line_file_candidates[-1][1]

        for s, fname, n, mm in refs:
            resolved, total = get_file_lines(fname)
            if resolved is None:
                continue
            if total is None:
                continue
            if n > total or (mm and mm > total):
                add_finding(findings_out, i, 'line', sec, '`%s` has %d lines; :%d is past the end' % (fname, total, mm))
                continue
            symbol_hits = []
            for ss, ee, c in extract_spans(raw):
                for cand in symbol_candidates_in_span(c):
                    symbol_hits.append((ss, cand))
            if symbol_hits:
                nearest = min(symbol_hits, key=lambda t: abs(t[0] - s))
                cand = nearest[1]
                content = file_cache.get(resolved)
                if content is not None:
                    file_lines = content.split('\n')
                    lo = max(1, n - 2)
                    hi = mm + 2
                    found_in_range = False
                    nearest_line = None
                    cls = r'[A-Za-z0-9_]'
                    pat = re.compile(r'(?<!%s)%s(?!%s)' % (cls, re.escape(cand), cls))
                    for ln_idx, fl in enumerate(file_lines, start=1):
                        if pat.search(fl):
                            if lo <= ln_idx <= hi:
                                found_in_range = True
                            if nearest_line is None or abs(ln_idx - n) < abs(nearest_line - n):
                                nearest_line = ln_idx
                    if not found_in_range:
                        if nearest_line:
                            add_finding(findings_out, i, 'line', sec,
                                        '`%s` nearest to `%s:%d`, not `%s:%d-%d`' % (cand, resolved, nearest_line, fname, n, mm))
                        else:
                            add_finding(findings_out, i, 'line', sec, '`%s` not in `%s`' % (cand, resolved))


def collect_size_findings(lines, sections, findings_out):
    if len(lines) > 450:
        add_finding(findings_out, 0, 'size', '-', 'file has %d lines (> 450)' % len(lines))
    heading_idx = None
    for i, l in enumerate(lines):
        if re.match(r'^##\s+§7\b', l):
            heading_idx = i
            break
    if heading_idx is None:
        return
    task_re = re.compile(r'^\d+\.\s')
    count = 0
    for i in range(heading_idx + 1, len(lines)):
        if re.match(r'^##\s+§\d', lines[i]):
            break
        if task_re.match(lines[i]):
            count += 1
    if count > 6:
        add_finding(findings_out, heading_idx, 'size', '7', '§7 has %d tasks (> 6)' % count)


def collect_boundary_findings(lines, fence_flags, sections, findings_out):
    for i, raw in enumerate(lines):
        if fence_flags[i] or sections[i] != '6':
            continue
        if re.search(r'\b(except|exception|exceptions|exempt|allowed|carve-out|carve out)\b', raw, re.IGNORECASE):
            add_finding(findings_out, i, 'boundary', '6', 'names an exception')


DW_MARKERS = ['visual', 'visually', 'looks right', 'looks good', 'looks like', 'look and feel',
              'feels', 'feel right', 'browser', 'screenshot', 'dev stack', 'on the device',
              'by eye', 'eyeball', 'judgement', 'judgment', 'judge', 'credentials', 'network',
              'internet', 'hardware', 'manually', 'git push', 'gh pr', 'gh api', 'glab mr', 'glab api', 'curl http', 'ssh']


def find_dw_marker(text):
    low = text.lower()
    for mk in DW_MARKERS:
        if mk in low:
            return mk
    return None


def collect_done_when_findings(lines, fence_flags, sections, findings_out):
    heading_idx = None
    for i, l in enumerate(lines):
        if re.match(r'^##\s+§4\b', l):
            heading_idx = i
            break
    if heading_idx is None:
        return
    end = len(lines)
    for i in range(heading_idx + 1, len(lines)):
        if re.match(r'^##\s+§\d', lines[i]):
            end = i
            break
    item_re = re.compile(r'^\d+\.\s')
    first_item = None
    for i in range(heading_idx + 1, end):
        if item_re.match(lines[i]):
            first_item = i
            break
    if first_item is None:
        first_item = end
    for i in range(heading_idx + 1, first_item):
        mk = find_dw_marker(lines[i])
        if mk:
            add_finding(findings_out, i, 'done-when', '4', 'goal names a marker: %s' % mk)
            break
    i = first_item
    while i < end:
        if item_re.match(lines[i]):
            j = i + 1
            while j < end and not item_re.match(lines[j]):
                j += 1
            block = '\n'.join(lines[i:j])
            reasons = []
            mk = find_dw_marker(block)
            if mk:
                reasons.append('a marker: %s' % mk)
            if re.search(r'~\s?\d|≈|about \d|roughly|approximately|around \d|or so', block, re.IGNORECASE):
                reasons.append('a fuzzy bound')
            has_span = any(extract_spans(l) for l in lines[i:j])
            has_fence = any(FENCE_OPEN_RE.match(l) for l in lines[i:j])
            if not has_span and not has_fence:
                reasons.append('judged')
            if reasons:
                add_finding(findings_out, i, 'done-when', '4', '; '.join(reasons))
            i = j
        else:
            i += 1


# ---------------------------------------------------------------------------
# brief mode driver
# ---------------------------------------------------------------------------

# Only these checks may FAIL a brief; every other finding is a WARN. --backtest --fail
# measures another set without changing this one.
FAIL_CHECKS = frozenset({'sweep'})


def analyze_brief(text, repo_raw, branch, T, at_given, fail_checks=None):
    """Run every check on a brief's text. Returns (info, findings): info holds the header
    facts, findings is a sorted list of (level, line, Finding)."""
    lines = text.split('\n')
    fm_end = 0
    if lines and lines[0].strip() == '---':
        for idx in range(1, len(lines)):
            if lines[idx].strip() == '---':
                fm_end = idx + 1
                break

    fence_flags = compute_fence_flags(lines)
    sections = compute_sections(lines, fence_flags)

    findings = []
    unusable = False
    reason = None
    repo = None
    checked_ref = None
    checked_commit = None
    tree_top = ''

    if not repo_raw or repo_raw == '-':
        unusable = True
        reason = 'no repo given'
    else:
        repo = os.path.expanduser(repo_raw)
        if not is_git_repo(repo):
            unusable = True
            reason = '`%s` is not a git repo' % repo_raw
        else:
            full, commit = resolve_checked_ref(repo, branch, T, at_given)
            if not commit:
                unusable = True
                reason = 'no candidate ref has a commit at T'
            else:
                checked_ref = full
                checked_commit = commit

    if not unusable:
        tree = ls_tree(repo, checked_commit)
        tree_top = set(f.split('/')[0] for f in tree)

    if not unusable:
        for ln, f in run_sweep(lines, fm_end, tree_top, sections):
            findings.append((ln, f))
        ctx = build_context(lines, fence_flags, repo)
        gitf = []
        collect_git_findings(lines, fence_flags, sections, repo, repo, branch, T, at_given, gitf, ctx)
        for ln, check, sec, msg in gitf:
            findings.append((ln, Finding('git', sec, ln, msg)))
        pathf = []
        collect_path_symbol_findings(lines, fence_flags, sections, repo, checked_commit, pathf, ctx,
                                     T, at_given)
        for ln, check, sec, msg in pathf:
            findings.append((ln, Finding(check, sec, ln, msg)))
        linef = []
        collect_line_findings(lines, fence_flags, sections, repo, checked_commit, linef)
        for ln, check, sec, msg in linef:
            findings.append((ln, Finding(check, sec, ln, msg)))
    else:
        for ln, f in run_sweep(lines, fm_end, set(), sections):
            findings.append((ln, f))

    sizef = []
    collect_size_findings(lines, sections, sizef)
    for ln, check, sec, msg in sizef:
        findings.append((ln, Finding('size', sec, ln, msg)))
    boundaryf = []
    collect_boundary_findings(lines, fence_flags, sections, boundaryf)
    for ln, check, sec, msg in boundaryf:
        findings.append((ln, Finding('boundary', sec, ln, msg)))
    dwf = []
    collect_done_when_findings(lines, fence_flags, sections, dwf)
    for ln, check, sec, msg in dwf:
        findings.append((ln, Finding('done-when', sec, ln, msg)))

    def sort_key(item):
        ln, f = item
        return (ln, CHECK_ORDER.get(f.check, 99), f.message)

    findings.sort(key=sort_key)

    fail_set = FAIL_CHECKS if fail_checks is None else fail_checks
    levelled = []
    for ln, f in findings:
        is_fail = f.check in fail_set
        if f.check == 'line' and ('nearest to' in f.message or (f.message.startswith('`') and 'not in `' in f.message)):
            is_fail = False
        levelled.append(('FAIL' if is_fail else 'WARN', ln, f))

    info = {'unusable': unusable, 'reason': reason, 'repo': repo,
            'checked_ref': checked_ref, 'checked_commit': checked_commit}
    return info, levelled


def brief_mode(brief_path, repo_override, branch_override, at_str, T):
    text = open(brief_path, encoding='utf-8', errors='replace').read()
    fm = read_frontmatter(text.split('\n'))
    repo_raw = repo_override if repo_override is not None else fm.get('repo')
    branch = branch_override if branch_override is not None else fm.get('branch')

    info, findings = analyze_brief(text, repo_raw, branch, T, at_str is not None)
    unusable = info['unusable']
    repo = info['repo']

    if unusable:
        line1 = 'brief-check %s · repo %s @ none' % (
            brief_path, repo_raw if repo_raw else '-')
    else:
        line1 = 'brief-check %s · repo %s @ %s %s' % (
            brief_path, toplevel(repo), short_ref(info['checked_ref']), info['checked_commit'][:7])
    if at_str:
        line1 += ' (as of %s)' % at_str

    out_lines = [line1]
    if unusable:
        out_lines.append('SKIP repo checks — %s' % info['reason'])

    n_fail = 0
    n_warn = 0
    for level, ln, f in findings:
        if level == 'FAIL':
            n_fail += 1
        else:
            n_warn += 1
        sec = f.section if f.section else '-'
        out_lines.append('%s %s §%s %d — %s' % (level, f.check, sec, ln, f.message))

    if any(f.check == 'boundary' for level, ln, f in findings) and not unusable:
        for note in collect_boundary_notes(repo, info['checked_commit'])[:20]:
            out_lines.append(note)

    out_lines.append('RESULT %d FAIL · %d WARN' % (n_fail, n_warn))

    print('\n'.join(out_lines))
    return 1 if n_fail > 0 else 0


NEVER_RE = re.compile(r'\b(never|must not|do not|don\'t)\b', re.IGNORECASE)


def collect_boundary_notes(repo, commit):
    notes = []
    for fname in ('AGENTS.md', 'CLAUDE.md'):
        content = show_file(repo, commit, fname)
        if content is None:
            continue
        for idx, l in enumerate(content.split('\n'), start=1):
            if NEVER_RE.search(l):
                text = l.strip()
                text = re.sub(r'^(- |\* |\d+\.\s)', '', text)
                notes.append('NOTE boundary %s:%d — %s' % (fname, idx, text))
    return notes


# ---------------------------------------------------------------------------
# --facts mode
# ---------------------------------------------------------------------------

def facts_mode(repo_arg, branch_arg):
    if not is_git_repo(repo_arg):
        usage_error()
    repo = repo_arg
    top = toplevel(repo)
    print('repo %s' % top)

    rc, out, err = run_git(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])
    head_name = out.strip() if rc == 0 else 'detached'
    if head_name == 'HEAD':
        head_name = 'detached'
    rc2, out2, err2 = run_git(repo, ['rev-parse', 'HEAD'])
    head_sha = out2.strip()[:7] if rc2 == 0 else ''
    print('head %s %s' % (head_name, head_sha))

    local_full = 'refs/heads/' + branch_arg
    origin_full = 'refs/remotes/origin/' + branch_arg
    local_exists = ref_exists_now(repo, local_full)
    origin_exists = ref_exists_now(repo, origin_full)

    if local_exists:
        rc, out, err = run_git(repo, ['rev-parse', local_full])
        sha = out.strip()[:7]
        print('branch %s local %s' % (branch_arg, sha))
    elif origin_exists:
        rc, out, err = run_git(repo, ['rev-parse', origin_full])
        sha = out.strip()[:7]
        print('branch %s origin-only %s' % (branch_arg, sha))
    else:
        print('branch %s missing' % branch_arg)

    upstream = None
    if local_exists:
        rc, out, err = run_git(repo, ['rev-parse', '--abbrev-ref', branch_arg + '@{upstream}'])
        if rc == 0:
            upstream = out.strip()
    if upstream:
        print('upstream %s' % upstream)
    else:
        print('upstream none')

    if upstream and local_exists:
        rc, out, err = run_git(repo, ['rev-list', '--left-right', '--count', '%s...%s' % (branch_arg, upstream)])
        if rc == 0:
            parts = out.split()
            ahead, behind = parts[0], parts[1]
            print('upstream-delta %s ahead %s behind' % (ahead, behind))
        else:
            print('upstream-delta -')
    else:
        print('upstream-delta -')

    if ref_exists_now(repo, 'refs/remotes/origin/dev'):
        base_full = 'refs/remotes/origin/dev'
        base_name = 'origin/dev'
    elif ref_exists_now(repo, 'refs/remotes/origin/main'):
        base_full = 'refs/remotes/origin/main'
        base_name = 'origin/main'
    else:
        base_full = None
        base_name = None

    if base_full:
        rc, out, err = run_git(repo, ['rev-parse', base_full])
        base_sha = out.strip()
        rc2, out2, err2 = run_git(repo, ['log', '-1', '--format=%s', base_full])
        subject = out2.strip()
        print('base %s %s %s' % (base_name, base_sha[:7], subject))
    else:
        print('base none')

    branch_full = local_full if local_exists else (origin_full if origin_exists else None)
    if branch_full and base_full:
        rc, out, err = run_git(repo, ['rev-parse', branch_full])
        branch_sha = out.strip()
        rc2, out2, err2 = run_git(repo, ['rev-list', '--left-right', '--count', '%s...%s' % (branch_full, base_full)])
        rc3, out3, err3 = run_git(repo, ['merge-base', branch_full, base_full])
        if rc2 == 0 and rc3 == 0:
            parts = out2.split()
            ahead, behind = parts[0], parts[1]
            mb = out3.strip()[:7]
            print('base-delta %s ahead %s behind merge-base %s' % (ahead, behind, mb))
        else:
            print('base-delta -')
    else:
        print('base-delta -')

    tagname, tagsha = latest_tag_at_T(repo, datetime.now(timezone.utc))
    if tagname:
        print('latest-tag %s %s' % (tagname, tagsha[:7]))
    else:
        print('latest-tag none')

    rc, out, err = run_git(repo, ['--no-optional-locks', 'status', '--porcelain'])
    n_changed = len([l for l in out.split('\n') if l])
    if n_changed == 0:
        print('tree clean')
    else:
        print('tree %d changed' % n_changed)

    rc, out, err = run_git(repo, ['rev-parse', '--path-format=absolute', '--git-path', 'FETCH_HEAD'])
    candidates = []
    if rc == 0:
        p = out.strip()
        if os.path.isfile(p):
            candidates.append(os.path.getmtime(p))
    rc2, out2, err2 = run_git(repo, ['rev-parse', '--git-common-dir'])
    if rc2 == 0:
        common = out2.strip()
        if not os.path.isabs(common):
            common = os.path.join(top, common)
        p2 = os.path.join(common, 'FETCH_HEAD')
        if os.path.isfile(p2):
            candidates.append(os.path.getmtime(p2))
    if candidates:
        newest = max(candidates)
        dt = datetime.fromtimestamp(newest, tz=timezone.utc)
        print('fetched %s' % dt.strftime('%Y-%m-%dT%H:%M:%S+00:00'))
    else:
        print('fetched never')


# ---------------------------------------------------------------------------
# --done-when mode
# ---------------------------------------------------------------------------
# The commands of a brief's §4 that the launcher re-runs before the close stage. One JSON
# line per numbered §4 item, in order: {"item": <ordinal>, "line": <1-based line>,
# "commands": [{"line", "kind": "span"|"fence", "cmd"}], "skipped": [{... "why"}]}.
# A command is a fenced shell block, or a code span that opens with a command word and is
# followed by its verdict ("prints", "exits", "→" ...). Commands with a placeholder, a
# write to git or the network, or a grep that names no file are skipped, with the reason.
# An item with no command is a judged item: the close session checks it itself.

DW_ITEM_RE = re.compile(r'^\d+\.\s')
DW_COMMAND_WORDS = {
    'bash', 'sh', 'git', 'grep', '/usr/bin/grep', 'rg', 'python3', 'python', 'pytest', 'uv',
    'npx', 'npm', 'pnpm', 'yarn', 'node', 'make', 'ruff', 'mypy', 'shellcheck', 'eslint',
    'test', '[', 'for', 'if', '!', 'cat', 'wc', 'ls', 'find', 'sed', 'awk', 'head', 'tail',
    'diff', 'cmp', 'jq', 'cut', 'sort', 'stat', 'env', 'timeout', 'docker',
}
DW_SCRIPT_RE = re.compile(r'^(?:\./|[\w.-]+/)+[\w.-]+\.(?:sh|py)$|^(?:[\w.-]+/)*\.?venv/bin/[\w.-]+$')
DW_VERDICT_RE = re.compile(
    r'(?:prints?|printing|exits?|→|shows?|showing|pass(?:es)?|is|are|lists?|finds?|reports?|'
    r'returns?|green|match(?:es)?|empty|clean|equals|succeeds?|outputs?|gives?|counts?|yields?|'
    r'emits?|fails?|reads?|says|≥|≤|==?)(?![A-Za-z])', re.IGNORECASE)
DW_FILLER_RE = re.compile(r'^(?:it|this|which|then|still|now|also|both|each|all|that|and|or|they|'
                          r'run|from\s+the\s+repo\s+root)\b\s*', re.IGNORECASE)
DW_PLACEHOLDER_RE = re.compile(r'<[A-Za-z][A-Za-z0-9 _./|-]*>|…')
DW_DENY_RE = re.compile(
    r'(?:^|[;&|(]\s*|\s)(?:git\s+(?:push|reset\s+--hard|clean|checkout|switch|rebase|merge(?!-)|'
    r'commit|stash|fetch|pull)\b|gh\s|glab\s|ssh\s|scp\s|rsync\s|curl\s|wget\s|sudo\s|'
    r'docker\s+(?:compose\s+)?(?:up|down|build|rm|stop|kill|restart|run)\b|rm\s+-[rRf])')
DW_SHELL_INFO = {'', 'bash', 'sh', 'shell', 'console', 'zsh'}
DW_ASSIGN_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=')
DW_GREP_WORDS = {'grep', '/usr/bin/grep', 'egrep', 'fgrep'}
DW_GREP_VALUE_SHORT = set('efmABCdD')          # short options whose value follows
DW_GREP_VALUE_LONG = {'--regexp', '--file', '--max-count', '--after-context', '--before-context',
                      '--context', '--label', '--devices', '--directories', '--binary-files',
                      '--include', '--exclude', '--exclude-dir', '--exclude-from'}
DW_CMD_END = {'|', '||', '&&', ';', '&', ')', '|&', ';;'}


def dw_skip_word(c, i):
    """Index just past the shell word starting at c[i]: quotes and $( ) nesting respected."""
    depth, q = 0, None
    while i < len(c):
        ch = c[i]
        if q:
            if ch == q:
                q = None
            elif ch == '\\' and q == '"':
                i += 1
        elif ch in '\'"':
            q = ch
        elif c.startswith('$(', i):
            depth += 1
            i += 1
        elif ch == '(' and depth:
            depth += 1
        elif ch == ')' and depth:
            depth -= 1
        elif depth == 0 and (ch.isspace() or ch in ';&|'):
            break
        i += 1
    return i


def dw_first_word(cmd):
    """The command a check line runs: past `set -o pipefail;`, variable assignments
    (`d=$(mktemp -d) &&` included), a leading `(` and a leading `cd <dir> &&`."""
    c = cmd.strip()
    for _ in range(8):
        c0 = c
        c = re.sub(r'^set\s+-o\s+pipefail\s*;\s*', '', c)
        m = DW_ASSIGN_RE.match(c)
        if m:
            c = c[dw_skip_word(c, m.end()):].lstrip()
            c = re.sub(r'^(?:&&|;)\s*', '', c)
        c = c.lstrip('( ')
        c = re.sub(r'^cd\s+\S+\s*&&\s*', '', c)
        if c == c0:
            break
    w = c.split()
    return w[0] if w else ''


def dw_is_command(cmd):
    fw = dw_first_word(cmd)
    return fw in DW_COMMAND_WORDS or bool(DW_SCRIPT_RE.match(fw))


def dw_grep_without_file(cmd):
    """True when the command opens with a grep that names no file and no -r: run with
    stdin at /dev/null it would read nothing and print a count of 0, whatever the repo
    holds. The file is then in the item's prose ("In `f`, `grep -c x` prints 0")."""
    if dw_first_word(cmd) not in DW_GREP_WORDS:
        return False
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return False
    idx = next((k for k, t in enumerate(toks) if t in DW_GREP_WORDS), None)
    if idx is None:
        return False
    pattern_opt = recursive = False
    operands = []
    i = idx + 1
    while i < len(toks):
        t = toks[i]
        if t in DW_CMD_END:
            break
        if t and set(t) <= set('<>&'):                   # a redirection and its target
            if t.startswith('<'):
                return False                             # stdin is a file
            i += 2
            continue
        if t.isdigit() and i + 1 < len(toks) and toks[i + 1][:1] in '<>':
            i += 1
            continue
        if t == '--':
            operands += [x for x in toks[i + 1:] if x not in DW_CMD_END]
            break
        if t.startswith('--') and len(t) > 2:
            name = t.split('=', 1)[0]
            pattern_opt |= name in ('--regexp', '--file')
            recursive |= name in ('--recursive', '--dereference-recursive')
            if '=' not in t and name in DW_GREP_VALUE_LONG:
                i += 1
        elif t.startswith('-') and len(t) > 1:
            for j, ch in enumerate(t[1:], 1):
                recursive |= ch in 'rR'
                if ch in DW_GREP_VALUE_SHORT:
                    pattern_opt |= ch in 'ef'
                    if j == len(t) - 1:
                        i += 1                           # the value is the next word
                    break
        else:
            operands.append(t)
        i += 1
    files = operands if pattern_opt else operands[1:]
    return not files and not recursive


def dw_verdict_follows(rest):
    """rest = the item text right after a span, later spans kept in backticks. 'yes' when
    a verdict word comes next, 'chain' when another span does (it shares that verdict)."""
    r = rest
    for _ in range(4):
        r = r.lstrip()
        r = re.sub(r'^\*\*', '', r)
        m = re.match(r'^\((?:[^()]|\([^()]*\))*\)', r)   # a parenthetical, one level of nesting
        if m:
            r = r[m.end():]
            continue
        m = re.match(r'^[,;:—–]\s*', r)
        if m:
            r = r[m.end():]
            continue
        m = DW_FILLER_RE.match(r)
        if m and m.end():
            r = r[m.end():]
            continue
        break
    r = r.lstrip().lstrip('*')
    if r.startswith('`'):
        return 'chain'
    return 'yes' if DW_VERDICT_RE.match(r) else 'no'


def dw_items(lines, fence_flags):
    """(start, end) line ranges of the numbered items of §4, outside fences."""
    h = next((i for i, l in enumerate(lines) if not fence_flags[i] and re.match(r'^##\s+§4\b', l)), None)
    if h is None:
        return []
    end = next((i for i in range(h + 1, len(lines))
                if not fence_flags[i] and re.match(r'^##\s+§\d', lines[i])), len(lines))
    starts = [i for i in range(h + 1, end) if not fence_flags[i] and DW_ITEM_RE.match(lines[i])]
    return [(s, starts[k + 1] if k + 1 < len(starts) else end) for k, s in enumerate(starts)]


def done_when_commands(text):
    lines = text.split('\n')
    ff = compute_fence_flags(lines)
    out = []
    for n, (s, e) in enumerate(dw_items(lines, ff), 1):
        cmds, skipped = [], []
        i = s
        while i < e:                                     # fenced shell blocks
            if ff[i] and (i == 0 or not ff[i - 1]):
                m = FENCE_OPEN_RE.match(lines[i])
                info = (m.group(3) if m else '').strip().lower()
                j = i + 1
                while j < e and ff[j] and not (FENCE_OPEN_RE.match(lines[j]) and lines[j].strip().strip('`~') == ''):
                    j += 1
                indent = m.group(1) if m else ''
                body = '\n'.join(l[len(indent):] if l.startswith(indent) else l for l in lines[i + 1:j])
                first = next((l for l in body.split('\n') if l.strip() and not l.strip().startswith('#')), '')
                if info in DW_SHELL_INFO and dw_is_command(first):
                    cmds.append({'line': i + 1, 'kind': 'fence', 'cmd': body.strip('\n')})
                i = j + 1
                continue
            i += 1
        flat = []                                        # the item's prose, spans kept in order
        for i in range(s, e):
            if ff[i]:
                continue
            raw = lines[i]
            last = 0
            for a, b, c in extract_spans(raw):
                flat.append(('t', raw[last:a], i))
                flat.append(('c', c, i))
                last = b
            flat.append(('t', raw[last:] + ' ', i))
        pending = []
        for k, (kind, t, ln) in enumerate(flat):
            if kind != 'c':
                continue
            rest = ''.join(x if kk == 't' else '`' + x + '`' for kk, x, _ in flat[k + 1:k + 6])
            v = dw_verdict_follows(rest)
            if v == 'chain':
                pending.append((t, ln))
                continue
            group = pending + [(t, ln)]
            pending = []
            if v != 'yes':
                continue
            for c, cl in group:
                if dw_is_command(c):
                    cmds.append({'line': cl + 1, 'kind': 'span', 'cmd': c.strip()})
        keep = []
        for c in cmds:
            if DW_PLACEHOLDER_RE.search(c['cmd']):
                skipped.append(dict(c, why='placeholder'))
            elif DW_DENY_RE.search(c['cmd']):
                skipped.append(dict(c, why='denied'))
            elif dw_grep_without_file(c['cmd']):
                skipped.append(dict(c, why='no-file'))
            elif not any(k['cmd'] == c['cmd'] for k in keep):
                keep.append(c)
        out.append({'item': n, 'line': s + 1, 'commands': keep, 'skipped': skipped})
    return out


def done_when_mode(brief_path):
    with open(brief_path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    for row in done_when_commands(text):
        print(json.dumps(row, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# --backtest mode
# ---------------------------------------------------------------------------

LABEL_HEADER = ['review_file', 'review_ts', 'brief_sha', 'repo', 'branch', 'tag',
                'category', 'section', 'finding']
TAGS = ('BLOCKER', 'WRONG')
CATEGORIES = ('git', 'path', 'line', 'symbol', 'dw-static', 'boundary', 'dw-run', 'judgment')
CATEGORY_CHECK = {'git': 'git', 'path': 'path', 'line': 'line', 'symbol': 'symbol',
                  'dw-static': 'done-when', 'boundary': 'boundary'}
BY_CHECK_ORDER = ('sweep', 'git', 'path', 'line', 'symbol', 'size', 'boundary', 'done-when')


def parse_ts(value):
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def load_labels(path):
    """Returns (groups, skipped): groups is an ordered list of row lists, one per brief."""
    if not os.path.isfile(path):
        usage_error()
    text = open(path, encoding='utf-8', errors='replace').read()
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    if not lines or lines[0].split('\t') != LABEL_HEADER:
        usage_error()
    groups = {}
    skipped = 0
    for l in lines[1:]:
        row = l.split('\t')
        if len(row) != len(LABEL_HEADER):
            usage_error()
        r = dict(zip(LABEL_HEADER, row))
        if r['tag'] not in TAGS or r['category'] not in CATEGORIES:
            usage_error()
        if r['brief_sha'] == 'NA':
            skipped += 1
            continue
        groups.setdefault((r['brief_sha'], r['review_file']), []).append(r)
    for rows in groups.values():
        first = rows[0]
        for r in rows[1:]:
            if any(r[k] != first[k] for k in ('review_ts', 'repo', 'branch')):
                usage_error()
        try:
            parse_ts(first['review_ts'])
        except ValueError:
            usage_error()
    return list(groups.values()), skipped


def label_section(section):
    m = re.match(r'^§(\d+)', section)
    return m.group(1) if m else None


def match_labels(rows, findings):
    """Pass 1 takes FAILs, pass 2 WARNs. Returns (matched, unmatched findings) where matched
    maps a row index to 'fail' or 'warn'."""
    taken = set()
    matched = {}
    for level, key in (('FAIL', 'fail'), ('WARN', 'warn')):
        for ri, r in enumerate(rows):
            check = CATEGORY_CHECK.get(r['category'])
            if check is None or ri in matched:
                continue
            sec = label_section(r['section'])
            for fi, (lv, ln, f) in enumerate(findings):
                if fi in taken or lv != level or f.check != check or f.section != sec:
                    continue
                taken.add(fi)
                matched[ri] = key
                break
    unmatched = [findings[fi] for fi in range(len(findings)) if fi not in taken]
    return matched, unmatched


def pct(a, n):
    return int(100 * a / n + 0.5) if n else 0


def backtest_mode(labels_path, vault, fail_checks=None):
    groups, skipped = load_labels(labels_path)
    if vault is None:
        base = os.environ.get('BRIEF_CHECK_DIR', '')
        if not base or not is_git_repo(base):
            usage_error()
        vault = toplevel(base)
    elif not os.path.isdir(vault):
        usage_error()

    cat_stats = {c: [0, 0, 0] for c in CATEGORIES}   # labels, fail, fail+warn
    by_check = {c: [0, 0] for c in BY_CHECK_ORDER}
    brief_lines = []
    unm_fail = []
    unm_warn = []
    n_briefs = 0
    n_labels = 0

    for rows in groups:
        first = rows[0]
        review_file = first['review_file']
        path = review_file[:-len('.review.md')] + '.md' if review_file.endswith('.review.md') else review_file
        rc, text, err = run_git(vault, ['show', '%s:%s' % (first['brief_sha'], path)])
        if rc != 0:
            reason = (err.strip().split('\n') or [''])[0] or 'git show failed'
            brief_lines.append('UNRESOLVED %s — %s' % (review_file, reason))
            skipped += len(rows)
            continue
        n_briefs += 1
        n_labels += len(rows)
        try:
            info, findings = analyze_brief(text, first['repo'], first['branch'],
                                           parse_ts(first['review_ts']), True, fail_checks)
            if info['unusable']:
                brief_lines.append('SKIP %s — %s' % (review_file, info['reason']))
        except Exception as e:
            findings = []
            brief_lines.append('ERROR %s — %s' % (review_file, str(e).replace('\n', ' ')))
        matched, unmatched = match_labels(rows, findings)
        for ri, r in enumerate(rows):
            st = cat_stats[r['category']]
            st[0] += 1
            if matched.get(ri) == 'fail':
                st[1] += 1
            if ri in matched:
                st[2] += 1
        uf = sum(1 for lv, ln, f in unmatched if lv == 'FAIL')
        uw = len(unmatched) - uf
        unm_fail.append(uf)
        unm_warn.append(uw)
        for lv, ln, f in unmatched:
            if f.check in by_check:
                by_check[f.check][0 if lv == 'FAIL' else 1] += 1
        brief_lines.append('BRIEF %s labels=%d matched=%d unmatched-fail=%d unmatched-warn=%d' % (
            review_file, len(rows), len(matched), uf, uw))

    out = ['backtest %d briefs · %d labels · skipped %d' % (n_briefs, n_labels, skipped)]
    for c in CATEGORIES:
        n, a, b = cat_stats[c]
        line = 'CAT %s labels=%d' % (c, n)
        if c in CATEGORY_CHECK and n > 0:
            line += ' fail=%d (%d%%) fail+warn=%d (%d%%)' % (a, pct(a, n), b, pct(b, n))
        if c == 'git':
            line += ' approximate'
        elif c not in CATEGORY_CHECK:
            line += ' no check'
        out.append(line)
    for name, cats in (('checkable', [c for c in CATEGORIES if c in CATEGORY_CHECK]),
                       ('labelled', list(CATEGORIES))):
        n = sum(cat_stats[c][0] for c in cats)
        a = sum(cat_stats[c][1] for c in cats)
        b = sum(cat_stats[c][2] for c in cats)
        out.append('ALL %s labels=%d fail=%d (%d%%) fail+warn=%d (%d%%)' % (
            name, n, a, pct(a, n), b, pct(b, n)))
    for name, vals in (('FAIL', unm_fail), ('WARN', unm_warn)):
        mx = max(vals) if vals else 0
        mean = sum(vals) / len(vals) if vals else 0.0
        out.append('UNMATCHED %s per brief max=%d mean=%.1f' % (name, mx, mean))
    out.append('UNMATCHED by check ' + ' '.join(
        '%s=%d/%d' % (c, by_check[c][0], by_check[c][1]) for c in BY_CHECK_ORDER))
    out.extend(brief_lines)
    print('\n'.join(out))
    return 0


def main():
    argv = sys.argv[1:]
    if not argv:
        usage_error()
    if argv[0] == '--help':
        print_help()
        return 0
    if argv[0] == '--facts':
        rest = argv[1:]
        if len(rest) != 2:
            usage_error()
        facts_mode(rest[0], rest[1])
        return 0
    if argv[0] == '--done-when':
        rest = argv[1:]
        if len(rest) != 1 or not os.path.isfile(rest[0]):
            usage_error()
        return done_when_mode(rest[0])
    if argv[0] == '--backtest':
        rest = argv[1:]
        if not rest or rest[0].startswith('--'):
            usage_error()
        vault = None
        fail_checks = None
        i = 1
        while i < len(rest):
            if rest[i] == '--vault' and i + 1 < len(rest) and vault is None:
                vault = rest[i + 1]
            elif rest[i] == '--fail' and i + 1 < len(rest) and fail_checks is None:
                fail_checks = frozenset(c for c in rest[i + 1].split(',') if c)
                if not fail_checks or not fail_checks <= set(CHECK_ORDER):
                    usage_error()
            else:
                usage_error()
            i += 2
        return backtest_mode(rest[0], vault, fail_checks)
    if argv[0].startswith('--'):
        usage_error()

    brief_path = argv[0]
    if not os.path.isfile(brief_path):
        usage_error()

    opts = argv[1:]
    at_val = None
    repo_override = None
    branch_override = None
    i = 0
    while i < len(opts):
        o = opts[i]
        if o == '--at':
            if i + 1 >= len(opts):
                usage_error()
            at_val = opts[i + 1]
            i += 2
        elif o == '--repo':
            if i + 1 >= len(opts):
                usage_error()
            repo_override = opts[i + 1]
            i += 2
        elif o == '--branch':
            if i + 1 >= len(opts):
                usage_error()
            branch_override = opts[i + 1]
            i += 2
        else:
            usage_error()

    T = datetime.now(timezone.utc)
    if at_val is not None:
        try:
            T = datetime.fromisoformat(at_val)
        except ValueError:
            usage_error()
        if T.tzinfo is None:
            T = T.replace(tzinfo=timezone.utc)

    return brief_mode(brief_path, repo_override, branch_override, at_val, T)


if __name__ == '__main__':
    sys.exit(main())
PY
