#!/usr/bin/env bash
# Archive-aware DURABLE captain-call reads, with every mutation still
# active-only.
#
# The failure this guards is quiet and late. tasks-axi archives Done rows past
# .tasks.toml's done_keep, so a captain call that was properly answered and then
# aged out of the active backlog disappears from a plain `show`. An active-only
# durable read then reports it as absent, and the completion gate refuses to
# clean up an investigation whose calls were ALL settled - long after the work,
# looking like a fresh bug rather than a dropped guarantee.
#
# The first section runs against the REAL installed tasks-axi with a genuinely
# pruned archive, because the whole point is the behavior of the actual tool.
# The second section uses a fake binary to reach the failure shapes a real tool
# will not produce on demand: absent capability, malformed output, duplicate
# load-bearing fields, and non-canonical NOT_FOUND envelopes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-archive)
HOLD="$ROOT/bin/fm-captain-hold.sh"
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

file_digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# --- real installed tasks-axi, real archive ---------------------------------

make_real_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/user-home"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  # The environment boundary matters: an operator's own backlog must be
  # unreachable from this fixture even if their shell exports a pointer to it.
  (unset TASKS_AXI_FILE TASKS_AXI_BACKEND
   cd "$home" && HOME="$home/user-home" tasks-axi "$@")
}

run_hold() {  # <home> <args...>
  local home=$1
  shift
  (unset TASKS_AXI_FILE TASKS_AXI_BACKEND
   HOME="$home/user-home" PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
     FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
     FM_CONFIG_OVERRIDE="$home/config" "$HOLD" "$@")
}

write_origin() {  # <home> <origin>
  fm_write_meta "$1/state/$2.meta" \
    "window=fixture" "worktree=$1/worktree" "project=$1/project" "kind=scout"
}

# The core regression. An answered captain call is genuinely pruned into the Done
# archive, a later call stays active, and the investigation's completion gate must
# still pass on BOTH without touching either file.
test_answered_call_survives_real_archiving() {
  local home origin archived active before_active before_archive out
  home=$(make_real_home real-archive)
  origin=sample-review
  archived=review-route-call
  active=review-layout-call
  write_origin "$home" "$origin"
  printf 'Use route B.\n' > "$home/decision.txt"

  run_hold "$home" hold "$archived" --title 'Choose the route' --repo sample \
    --reason 'captain route pending' --origin "$origin" >/dev/null \
    || fail "could not create the first captain call"
  run_hold "$home" answer "$archived" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not record the captain answer"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not prune the answered call into the archive"

  grep -Fq "$archived" "$home/data/done-archive.md" \
    || fail "the fixture did not actually archive the answered call"
  tasks_in "$home" show "$archived" --full >/dev/null 2>&1 \
    && fail "the fixture's answered call is still visible to an active-only read"

  run_hold "$home" hold "$active" --title 'Choose the layout' --repo sample \
    --reason 'captain layout pending' --origin "$origin" >/dev/null \
    || fail "could not create the later active captain call"

  before_active=$(file_digest "$home/data/backlog.md")
  before_archive=$(file_digest "$home/data/done-archive.md")

  out=$(run_hold "$home" complete "$origin" "$archived" "$active") \
    || fail "the completion gate refused an archived answered call plus an active one"
  assert_contains "$out" "complete: $origin" "completion lost its origin identity"
  out=$(run_hold "$home" verify "$origin") \
    || fail "verification refused an archived answered call plus an active one"
  assert_contains "$out" "verified: $origin" "verification lost its origin identity"

  [ "$before_active" = "$(file_digest "$home/data/backlog.md")" ] \
    || fail "a durable read changed the active backlog"
  [ "$before_archive" = "$(file_digest "$home/data/done-archive.md")" ] \
    || fail "a durable read changed the Done archive"
  pass "an answered captain call still verifies after the real tool archives it, with both files unchanged"
}

# Readable is not mutable: the archived identity resolves for durable reads but
# every hold mutation refuses rather than recreating it in the active backlog.
test_archived_identity_is_readable_but_not_mutable() {
  local home origin archived before_active before_archive
  home=$(make_real_home real-archive-mutation)
  origin=sample-mutation
  archived=mutation-route-call
  write_origin "$home" "$origin"
  printf 'Use route B.\n' > "$home/decision.txt"
  run_hold "$home" hold "$archived" --title 'Choose the route' --repo sample \
    --reason 'captain route pending' --origin "$origin" >/dev/null \
    || fail "could not create the captain call"
  run_hold "$home" answer "$archived" --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not record the captain answer"
  tasks_in "$home" prune --keep 0 >/dev/null || fail "could not archive the answered call"

  before_active=$(file_digest "$home/data/backlog.md")
  before_archive=$(file_digest "$home/data/done-archive.md")
  if run_hold "$home" hold "$archived" --title 'Choose the route' --repo sample \
      --reason 'captain route pending' --origin "$origin" >"$home/out" 2>"$home/err"; then
    fail "an archived captain call was mutated instead of refused"
  fi
  assert_grep 'is archived and cannot be mutated' "$home/err" \
    "the archived mutation refusal did not name its reason: $(cat "$home/err")"
  [ "$before_active" = "$(file_digest "$home/data/backlog.md")" ] \
    || fail "the refused archived hold still changed the active backlog"
  [ "$before_archive" = "$(file_digest "$home/data/done-archive.md")" ] \
    || fail "the refused archived hold still changed the Done archive"
  pass "an archived captain call is durably readable and refuses every hold mutation"
}

# --- fake binary: capability, malformed, and non-canonical absence ----------

make_fake_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/user-home" "$home/records"
  printf 'active fixture\n' > "$home/data/backlog.md"
  printf 'archive fixture\n' > "$home/data/done-archive.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TASKS_LOG:?}
records=${FM_FAKE_TASKS_RECORDS:?}
case "${1:-}" in
  --version)
    printf 'tasks-axi 0.2.5\n'
    exit 0
    ;;
  hold)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi hold <id> --kind captain'
      exit 0
    fi
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> --archive-body'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
      exit 0
    fi
    ;;
  show)
    if [ "${2:-}" = --help ]; then
      printf 'show-help\n' >> "$log"
      if [ "${FM_FAKE_ARCHIVE_CAPABILITY:-1}" = 1 ]; then
        printf '%s\n' 'usage: tasks-axi show <id> [--full] [--include-archive]'
      else
        printf '%s\n' 'usage: tasks-axi show <id> [--full]'
      fi
      exit 0
    fi
    id=${2:-}
    file="$records/active-$id"
    if [ "${3:-}" = --include-archive ]; then
      file="$records/durable-$id"
    fi
    if [ -f "$file" ]; then
      cat "$file"
      if [ "${FM_FAKE_DUPLICATE_TITLE_ID:-}" = "$id" ]; then
        printf '  title: Duplicate title\n'
      fi
      exit 0
    fi
    case "${FM_FAKE_MISS_MODE:-canonical}" in
      canonical)
        printf 'error: "Task \\"%s\\" not found in this backlog"\n' "$id" >&2
        printf 'code: NOT_FOUND\n' >&2
        printf 'help[1]: Run `tasks-axi list` to see existing tasks\n' >&2
        exit 1
        ;;
      code-only)
        printf 'code: NOT_FOUND\n' >&2
        exit 1
        ;;
      wrong-status)
        printf 'error: "Task \\"%s\\" not found in this backlog"\n' "$id" >&2
        printf 'code: NOT_FOUND\n' >&2
        exit 2
        ;;
    esac
    ;;
esac
printf 'mutation: %s\n' "$*" >> "$log"
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$home"
}

write_fake_task() {  # <home> <id> <source> <state> <held> <hold-kind> <title> <body>
  local home=$1 id=$2 source=$3 state=$4 held=$5 hold_kind=$6 title=$7 body=$8
  cat > "$home/records/durable-$id" <<EOF
task:
  id: $id
  source: $source
  title: $title
  state: $state
  held: $held
  kind: captain
  hold_kind: $hold_kind
  body: "$body"
EOF
  if [ "$source" = active ]; then
    sed '/^  source: /d' "$home/records/durable-$id" > "$home/records/active-$id"
  fi
}

run_fake_hold() {  # <home> <args...>
  local home=$1
  shift
  HOME="$home/user-home" PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_TASKS_LOG="$home/tasks.log" \
    FM_FAKE_TASKS_RECORDS="$home/records" "$HOLD" "$@"
}

# Absence must mean ONLY the exact canonical NOT_FOUND envelope. A missing
# capability, a malformed record, a duplicate load-bearing field, or a
# non-canonical failure must each refuse loudly instead of being read as "the
# captain never held this" - the misread that silently drops a settled call.
test_capability_absence_and_malformed_stay_distinct() {
  local home origin id mode help_count
  home=$(make_fake_home fake-failures)
  origin=sample-failures
  id=failures-route-call
  fm_write_meta "$home/state/$origin.meta" \
    "window=fixture" "worktree=$home/worktree" "project=$home/project" \
    "kind=scout" "decisions_reviewed=1" "decision_keys=$id"

  if FM_FAKE_ARCHIVE_CAPABILITY=0 run_fake_hold "$home" verify "$origin" \
      >"$home/cap.out" 2>"$home/cap.err"; then
    fail "the captain-hold lifecycle accepted a tasks-axi with no archive capability"
  fi
  assert_grep 'archive-capable tasks-axi' "$home/cap.err" \
    "a missing capability was not reported as a capability problem: $(cat "$home/cap.err")"

  if run_fake_hold "$home" verify "$origin" >"$home/miss.out" 2>"$home/miss.err"; then
    fail "a genuinely absent captain call passed verification"
  fi
  assert_grep 'absent from the active backlog and the Done archive' "$home/miss.err" \
    "canonical absence lost its absence result: $(cat "$home/miss.err")"

  write_fake_task "$home" "$id" archive 'done' no '-' 'Resolved route' \
    'Resolution recorded by fm-captain-hold.\nDecision digest: fixture\n\nCaptain decision:\nUse route.'
  run_fake_hold "$home" verify "$origin" >/dev/null 2>"$home/ok.err" \
    || fail "an archived answered call did not verify: $(cat "$home/ok.err")"
  help_count=$(grep -c '^show-help$' "$home/tasks.log" || true)
  [ "$help_count" -ge 1 ] || fail "the archive capability was never probed"
  ! grep -q '^mutation:' "$home/tasks.log" || fail "verification reached a mutation command"

  printf 'task:\n  id: %s\n  source: archive\n' "$id" > "$home/records/durable-$id"
  if run_fake_hold "$home" verify "$origin" >"$home/malformed.out" 2>"$home/malformed.err"; then
    fail "malformed durable output passed verification"
  fi
  assert_grep 'returned malformed output' "$home/malformed.err" \
    "malformed output was reported as absence: $(cat "$home/malformed.err")"

  write_fake_task "$home" "$id" active queued yes captain 'Expected title' 'Awaiting the captain.'
  : > "$home/tasks.log"
  if FM_FAKE_DUPLICATE_TITLE_ID="$id" run_fake_hold "$home" hold "$id" \
      --title 'Expected title' --reason 'captain route pending' --repo sample \
      >"$home/duplicate.out" 2>"$home/duplicate.err"; then
    fail "a duplicate load-bearing field still allowed an active mutation"
  fi
  assert_grep 'returned malformed output' "$home/duplicate.err" \
    "a duplicate field was not rejected: $(cat "$home/duplicate.err")"
  ! grep -q '^mutation:' "$home/tasks.log" || fail "a malformed read reached a mutation command"

  rm -f "$home/records/durable-$id" "$home/records/active-$id"
  for mode in code-only wrong-status; do
    : > "$home/tasks.log"
    if FM_FAKE_MISS_MODE="$mode" run_fake_hold "$home" hold "$id" \
        --title 'Choose the route' --reason 'captain route pending' --repo sample \
        >"$home/$mode.out" 2>"$home/$mode.err"; then
      fail "a $mode failure was accepted as absence and allowed creation"
    fi
    assert_grep 'failed incompatibly' "$home/$mode.err" \
      "a $mode failure was misclassified as absence: $(cat "$home/$mode.err")"
    ! grep -q '^mutation:' "$home/tasks.log" || fail "a $mode failure reached a mutation command"
  done
  pass "missing capability, canonical absence, malformed output, and non-canonical failure stay distinct"
}

test_answered_call_survives_real_archiving
test_archived_identity_is_readable_but_not_mutable
test_capability_absence_and_malformed_stay_distinct

echo '# all fm-captain-hold archive tests passed'
