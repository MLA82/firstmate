# Live drive of bin/fm-teardown.sh (backend=orca) - stale recorded worktree

Each run stands up an isolated FM_HOME with a task record, a live worker
process whose cwd is the recorded worktree, and a .claude/settings.local.json
hook file. A fake 'orca' CLI answers 'worktree show' with the path Orca
really owns for the recorded worktree id.

## 1. Forced Orca ship teardown, recorded worktree is stale - BEFORE the fix (base 9bc051f)
$ fm-teardown.sh a1-base --force      # backend=orca kind=ship, orca worktree id -> stale
--- stdout ---
--- stderr ---
teardown: reaping leaked worktree process(es) for a1-base: 1771326
REFUSED: Orca worktree id worktree-1::/orca/worktree-1 resolves to /tmp/orca-drive/a1-base/elsewhere-worktree, not inspected worktree /tmp/orca-drive/a1-base/worktree.
Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata.
--- exit code: 1
worker process 1771326 in /tmp/orca-drive/a1-base/worktree: KILLED
orca worktree show: CALLED
claude hook file .claude/settings.local.json: PRESENT
task record a1-base.meta: PRESERVED

## 2. Same scenario - AFTER the fix (8a34865)
$ fm-teardown.sh a2-fixed --force      # backend=orca kind=ship, orca worktree id -> stale
--- stdout ---
--- stderr ---
REFUSED: Orca worktree id worktree-1::/orca/worktree-1 resolves to /tmp/orca-drive/a2-fixed/elsewhere-worktree, not inspected worktree /tmp/orca-drive/a2-fixed/worktree.
Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata.
--- exit code: 1
worker process 1774785 in /tmp/orca-drive/a2-fixed/worktree: STILL ALIVE
orca worktree show: CALLED
claude hook file .claude/settings.local.json: PRESENT
task record a2-fixed.meta: PRESERVED

## 3. Orca scout teardown, recorded worktree is stale - AFTER the fix
$ fm-teardown.sh a3-scout       # backend=orca kind=scout, orca worktree id -> stale
--- stdout ---
--- stderr ---
REFUSED: Orca worktree id worktree-1::/orca/worktree-1 resolves to /tmp/orca-drive/a3-scout/elsewhere-worktree, not inspected worktree /tmp/orca-drive/a3-scout/worktree.
Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata.
--- exit code: 1
worker process 1778123 in /tmp/orca-drive/a3-scout/worktree: STILL ALIVE
orca worktree show: CALLED
claude hook file .claude/settings.local.json: PRESENT
task record a3-scout.meta: PRESERVED

## 4. Adversarial: Orca cannot resolve the worktree id (ok:false), forced ship - AFTER the fix
$ fm-teardown.sh a4-unresolvable --force      # backend=orca kind=ship, orca worktree id -> unresolvable
--- stdout ---
--- stderr ---
REFUSED: cannot resolve Orca worktree id worktree-1::/orca/worktree-1 to a path; preserving metadata.
--- exit code: 1
worker process 1779737 in /tmp/orca-drive/a4-unresolvable/worktree: STILL ALIVE
orca worktree show: CALLED
claude hook file .claude/settings.local.json: PRESENT
task record a4-unresolvable.meta: PRESERVED

## 5. Happy path: Orca resolves the id to the recorded worktree, forced ship - AFTER the fix
$ fm-teardown.sh a5-match --force      # backend=orca kind=ship, orca worktree id -> the recorded worktree
--- stdout ---
/tmp/orca-drive/a5-match/project: skipped: no origin remote
teardown a5-match complete (window term-1, worktree /tmp/orca-drive/a5-match/worktree)
Backlog: a5-match just finished (this home keeps no markdown backlog at /tmp/orca-drive/a5-match/home/data/backlog.md). Update /tmp/orca-drive/a5-match/home/data/backlog.md - move a5-match to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
--- stderr ---
teardown: reaping leaked worktree process(es) for a5-match: 1781654
--- exit code: 0
worker process 1781654 in /tmp/orca-drive/a5-match/worktree: KILLED
orca worktree show: CALLED
claude hook file .claude/settings.local.json: REMOVED
task record a5-match.meta: DELETED

## 6. Documented fallthrough: recorded worktree absent on disk - Orca is never called, teardown completes
/tmp/orca-drive/drive.sh: Zeile 54: cd: /tmp/orca-drive/a6-absent/worktree: Datei oder Verzeichnis nicht gefunden
$ fm-teardown.sh a6-absent --force      # backend=orca kind=ship, orca worktree id -> absent
--- stdout ---
/tmp/orca-drive/a6-absent/project: skipped: no origin remote
teardown a6-absent complete (window term-1, worktree /tmp/orca-drive/a6-absent/worktree)
Backlog: a6-absent just finished (this home keeps no markdown backlog at /tmp/orca-drive/a6-absent/home/data/backlog.md). Update /tmp/orca-drive/a6-absent/home/data/backlog.md - move a6-absent to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
--- stderr ---
--- exit code: 0
worker process 1787513 in /tmp/orca-drive/a6-absent/worktree: KILLED
recorded worktree: ABSENT on disk (as staged)
orca worktree show: NOT CALLED
claude hook file .claude/settings.local.json: REMOVED
task record a6-absent.meta: DELETED
