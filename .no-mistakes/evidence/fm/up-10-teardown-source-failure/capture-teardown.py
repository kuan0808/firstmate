#!/usr/bin/env python3
"""Run hermetic executable-interface regressions and retain operator output/state."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
evidence = Path(__file__).parent
scratch = Path(tempfile.mkdtemp(prefix='.teardown-evidence-', dir=repo))
try:
    for revision, name in [('004fad0', 'before-replacement-fix.sh'), ('d6660d75', 'before-abort-fix.sh')]:
        (scratch / name).write_bytes(subprocess.check_output(['git', 'show', revision + ':bin/fm-teardown.sh'], cwd=repo))
    harness = scratch / 'capture.sh'
    harness.write_text(r'''set -u
export FM_GATE_REFUSE_BYPASS=1
# Capture the real subprocess streams without changing the caller's redirects.
bash() {
  local capture rc=0
  capture=$(mktemp -d "$CAPTURE_SCRATCH/invocation.XXXXXX")
  command /bin/bash "$@" >"$capture/stdout" 2>"$capture/stderr" || rc=$?
  {
    printf '\n$ FM_HOME=%q /bin/bash ' "${FM_HOME:-}"
    printf '%q ' "$@"
    printf '\nexit=%s\nstdout:\n' "$rc"
    cat "$capture/stdout"
    printf 'stderr (saved original stderr included):\n'
    cat "$capture/stderr"
  } >> "$TRANSCRIPT"
  cat "$capture/stdout"
  cat "$capture/stderr" >&2
  return "$rc"
}
. "$REPO/tests/fm-gotmp.test.sh"
{
  printf '\nPERSISTED STATE AFTER CURRENT-HEAD INTERFACE CASES\n'
  printf 'Replacement metadata retained after original cleanup:\n'
  cat "$TMP_ROOT/td-replacement-z8/state/td-replacement-z8.meta"
  for mode in missing-sibling missing-adapter zero-exit; do
    id="td-child-$mode"
    fake="$TMP_ROOT/$id"
    home="$TMP_ROOT/home-$id"
    printf '\nForced parent / child failure=%s\n' "$mode"
    cmp "$fake/parent.meta.before" "$fake/state/$id.meta" || exit 1
    cmp "$fake/child.meta.before" "$home/state/child-z.meta" || exit 1
    printf 'Parent and child metadata: byte-identical to before teardown\n'
    cat "$home/work-note" "$TMP_ROOT/work-$id/work-note" "$TMP_ROOT/fm-$id/gotmp/artifact" "$home/tasktmp/gotmp/artifact"
    [ ! -e "$fake/child-kill.log" ] || exit 1
    printf 'Child endpoint kill: not invoked\n'
  done
} >> "$TRANSCRIPT"
# Explicit unreadable adapter case, in addition to the missing adapter regression.
fake=$(make_fake_root td-unreadable)
chmod 000 "$fake/bin/backends/tmux.sh"
FM_HOME="$fake" bash --posix -c '
  . "$1/bin/fm-backend.sh"
  if fm_backend_source tmux; then exit 1; fi
  printf "unreadable adapter refused by caller\n"
' _ "$fake" || exit 1
chmod 600 "$fake/bin/backends/tmux.sh"
# Use unchanged public-interface tests against pre-fix implementations.
for variant in replacement abort; do
  printf '\nBEFORE-FIX NEGATIVE CONTROL: %s\n' "$variant" >> "$TRANSCRIPT"
  oldroot="$TMP_ROOT"
  TMP_ROOT=$(mktemp -d "$CAPTURE_SCRATCH/before-$variant.XXXXXX")
  (
    if [ "$variant" = replacement ]; then
      TEARDOWN="$CAPTURE_SCRATCH/before-replacement-fix.sh"
      test_teardown_preserves_replacement_record
    else
      TEARDOWN="$CAPTURE_SCRATCH/before-abort-fix.sh"
      test_teardown_rejects_zero_status_abort
    fi
  ) >"$CAPTURE_SCRATCH/control-$variant.log" 2>&1
  rc=$?
  cat "$CAPTURE_SCRATCH/control-$variant.log" >> "$TRANSCRIPT"
  printf 'Regression assertion exit=%s (expected nonzero before fix)\n' "$rc" >> "$TRANSCRIPT"
  [ "$rc" -ne 0 ] || exit 1
  rm -rf "$TMP_ROOT"
  TMP_ROOT="$oldroot"
done
''')
    transcript = evidence / 'teardown-cli-transcript.txt'
    transcript.write_text('Hermetic CLI evidence; no live fleet/backend lifecycle.\nTarget: ' + subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip() + '\n' + subprocess.check_output(['/bin/bash', '--version'], text=True) + '\nModern Bash/Linux execution is not claimed; hosted CI owns that axis.\n')
    env = dict(os.environ, REPO=str(repo), CAPTURE_SCRATCH=str(scratch), TRANSCRIPT=str(transcript), TMPDIR=str(scratch))
    result = subprocess.run(['/bin/bash', str(harness)], cwd=repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (evidence / 'capture-execution.log').write_text(result.stdout)
    print(result.stdout)
    print('Evidence capture exit:', result.returncode)
    sys.exit(result.returncode)
finally:
    shutil.rmtree(scratch)
