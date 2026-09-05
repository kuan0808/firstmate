#!/bin/bash
# Run from the assigned repository worktree; all lifecycle operations use hermetic fixtures.
set -u
. tests/fm-gotmp.test.sh
printf '\nCLI evidence: %s\n' "$BASH_VERSION"
printf 'Real teardown/backend dispatch; fake adapters and orphan reaper; no live fleet.\n'
for mode in missing-sibling missing-adapter zero-exit kill-failure success; do
  id="td-child-$mode"
  fake="$TMP_ROOT/$id"
  home="$TMP_ROOT/home-$id"
  printf '\n$ FM_HOME=<fixture> bash bin/fm-teardown.sh %s --force\n' "$id"
  printf 'Fixture condition: %s\n' "$mode"
  cat "$fake/teardown.stdout" "$fake/teardown.stderr"
  case "$mode" in
    missing-sibling|missing-adapter|zero-exit)
      rc=0
      FM_HOME="$fake" PATH="$fake/bin:$PATH" TEST_CHILD_KILL_LOG="$fake/child-kill.log" TEST_CHILD_KILL_RC=0 \
        /bin/bash "$fake/bin/fm-teardown.sh" "$id" --force > "$fake/retry.stdout" 2> "$fake/retry.stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail "retry unexpectedly succeeded"
      printf 'Observed retry exit status: %s\n' "$rc"
      cmp "$fake/parent.meta.before" "$fake/state/$id.meta" || exit 1
      cmp "$fake/child.meta.before" "$home/state/child-z.meta" || exit 1
      printf 'Parent metadata: byte-identical; child metadata: byte-identical\n'
      for path in "$home/work-note" "$TMP_ROOT/work-$id/work-note" "$TMP_ROOT/fm-$id/gotmp/artifact" "$home/tasktmp/gotmp/artifact"; do
        printf '%s: ' "${path#"$TMP_ROOT/"}"
        cat "$path"
      done
      [ ! -e "$fake/child-kill.log" ] || exit 1
      printf 'Child endpoint kill was not invoked.\n'
      ;;
    *)
      for path in "$fake/state/$id.meta" "$home" "$TMP_ROOT/work-$id" "$TMP_ROOT/fm-$id"; do
        [ ! -e "$path" ] || exit 1
        printf 'Removed: %s\n' "${path#"$TMP_ROOT/"}"
      done
      printf 'Child kill received owning home twice, target, tab, label:\n'
      cat "$fake/child-kill.log"
      ;;
  esac
done
printf '\nOriginal stderr survives the best-effort kill redirection:\n'
cat "$TMP_ROOT/td-zero-z6.stderr"
printf '\nMissing and unreadable adapters return to the caller (Bash POSIX mode):\n'
for mode in missing unreadable; do
  fake=$(make_fake_root "evidence-$mode")
  if [ "$mode" = missing ]; then
    rm "$fake/bin/backends/tmux.sh"
  else
    chmod 000 "$fake/bin/backends/tmux.sh"
    [ ! -r "$fake/bin/backends/tmux.sh" ] || fail 'unreadability precondition not met'
  fi
  FM_HOME="$fake" /bin/bash --posix -c '
    . "$1/bin/fm-backend.sh"
    rc=0; fm_backend_source tmux || rc=$?
    [ "$rc" -ne 0 ] || exit 1
    printf "%s adapter: source returned %s; caller emits REFUSED and continues\n" "$2" "$rc"
  ' _ "$fake" "$mode" || exit 1
  [ "$mode" != unreadable ] || chmod 600 "$fake/bin/backends/tmux.sh"
done
printf '\nBefore/after reproduction of zero-status abort using identical fixture:\n'
git show f09de8a3d3a550b13b4d535346fbc7b9ac0d6c19:bin/fm-teardown.sh > "$TMP_ROOT/base-teardown.sh" || exit 1
id=evidence-before-after
scratch="$TMP_ROOT/fm-$id"
mkdir -p "$scratch/gotmp"
printf 'preserved scratch\n' > "$scratch/gotmp/artifact"
fake=$(make_fake_root "$id" "$scratch")
printf 'exit 0\n' > "$fake/bin/backends/tmux.sh"
cp "$fake/state/$id.meta" "$fake/meta.before"
for revision in base target; do
  rm "$fake/bin/fm-teardown.sh"
  if [ "$revision" = base ]; then
    ln -s "$TMP_ROOT/base-teardown.sh" "$fake/bin/fm-teardown.sh"
  else
    ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  fi
  rc=0
  FM_HOME="$fake" /bin/bash "$fake/bin/fm-teardown.sh" "$id" > "$fake/$revision.stdout" 2> "$fake/$revision.stderr" || rc=$?
  printf '%s exit status: %s\n' "$revision" "$rc"
  cat "$fake/$revision.stdout" "$fake/$revision.stderr"
  cmp "$fake/meta.before" "$fake/state/$id.meta" || exit 1
  [ "$(cat "$scratch/gotmp/artifact")" = 'preserved scratch' ] || exit 1
  printf 'Metadata byte-identical; scratch retained.\n'
  case "$revision:$rc" in base:0|target:1) ;; *) fail 'unexpected comparison result' ;; esac
done
printf '\nPre-fix forced mixed-backend regression (expected test failure):\n'
rc=0
(
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-base-evidence.XXXXXX")
  trap cleanup EXIT
  git show f09de8a3d3a550b13b4d535346fbc7b9ac0d6c19:bin/fm-teardown.sh > "$TMP_ROOT/base-teardown.sh" || exit 1
  TEARDOWN="$TMP_ROOT/base-teardown.sh"
  test_forced_parent_preflights_child_adapters
) > "$TMP_ROOT/base-child.log" 2>&1 || rc=$?
cat "$TMP_ROOT/base-child.log"
[ "$rc" -eq 1 ] || fail 'pre-fix child regression did not fail as expected'
printf 'Pre-fix regression exit status: %s (failure reproduced).\n' "$rc"
printf '\nCurrent target: all asserted CLI and state contracts satisfied on Bash 3.2.\n'
printf 'Linux/modern Bash remains owned by hosted CI; not exercised locally.\n'
