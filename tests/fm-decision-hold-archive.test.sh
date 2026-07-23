#!/usr/bin/env bash
# Focused integration tests for archive-aware durable captain-decision lookup.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-hold-archive)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

[ -n "$TASKS_AXI_BIN" ] || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name> [archive-path|default]
  local archive=${2:-data/done-archive.md} home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  if [ "$archive" = default ]; then
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
done_keep = 10
EOF
  else
    mkdir -p "$home/$(dirname "$archive")"
    cat > "$home/.tasks.toml" <<EOF
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "$archive"
done_keep = 10
EOF
  fi
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
  (cd "$home" && "$TASKS_AXI_BIN" "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <origin> <keys>
  local home=$1 origin=$2 keys=$3
  fm_write_meta "$home/state/$origin.meta" \
    "window=fixture" \
    "worktree=$home/projects/sample" \
    "project=$home/projects/sample" \
    "harness=pi" \
    "kind=scout" \
    "mode=scout" \
    "decisions_reviewed=1" \
    "decision_keys=$keys"
}

resolved_body() {  # [digest] [routes]
  local digest=${1:-fixture-digest} routes=${2:-sample-route-work}
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\nUse the synthetic route.\n\nRouted work:\n- %s' \
    "$digest" "$routes" "$routes"
}

create_resolved() {  # <home> <id> [body]
  local home=$1 id=$2 body=${3:-}
  [ -n "$body" ] || body=$(resolved_body)
  tasks_in "$home" add "$id" "Synthetic resolved decision" --kind captain --repo sample >/dev/null \
    || fail "could not create resolved decision fixture"
  tasks_in "$home" update "$id" --body "$body" >/dev/null \
    || fail "could not write resolved decision fixture"
  tasks_in "$home" "done" "$id" --no-prune >/dev/null \
    || fail "could not close resolved decision fixture"
}

archive_all_done() {  # <home>
  tasks_in "$1" prune --keep 0 >/dev/null || fail "could not archive resolved decision fixture"
}

file_digest() {  # <path>
  shasum -a 256 "$1" | awk '{print $1}'
}

test_live_pin_exposes_archive_contract() {
  local help home active archive ordinary_rc=0
  help=$("$TASKS_AXI_BIN" show --help 2>&1) || fail "installed tasks-axi show help failed"
  assert_contains "$help" "--include-archive" \
    "installed tasks-axi does not expose the audited archive lookup flag"

  home=$(make_home live-pin-contract default)
  create_resolved "$home" active-decision
  create_resolved "$home" archive-decision
  archive_all_done "$home"
  tasks_in "$home" add active-decision "Synthetic active shadow" --kind captain --repo sample >/dev/null
  active=$(tasks_in "$home" show active-decision --include-archive --full) \
    || fail "installed tasks-axi did not return the active shadow"
  archive=$(tasks_in "$home" show archive-decision --include-archive --full) \
    || fail "installed tasks-axi did not return the archived fixture"
  assert_contains "$active" "source: active" "installed tasks-axi lost active-first provenance"
  assert_contains "$archive" "source: archive" "installed tasks-axi lost archive provenance"
  tasks_in "$home" show archive-decision --full > "$home/ordinary.out" 2>&1 || ordinary_rc=$?
  expect_code 1 "$ordinary_rc" "ordinary show must remain active-only"
  assert_grep "code: NOT_FOUND" "$home/ordinary.out" "ordinary archive miss lost NOT_FOUND"
  pass "active local tasks-axi pin exposes the privacy-safe archive lookup contract"
}

test_active_hit_does_not_read_archive() {
  local home origin id
  home=$(make_home active-hit default)
  origin=sample-active-review
  id="$origin-decision-route"
  write_origin_meta "$home" "$origin" route
  create_resolved "$home" "$id"
  mkdir "$home/data/done-archive.md"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "active resolved decision did not verify without reading the archive"
  pass "active durable decision wins before archive fallback"
}

test_default_archive_fallback_and_active_only_mutation() {
  local home origin id decision digest before_active before_archive after_active after_archive output
  home=$(make_home default-archive default)
  origin=sample-default-review
  id="$origin-decision-route"
  write_origin_meta "$home" "$origin" route
  printf 'Use the synthetic route.\n' > "$home/decision.txt"
  decision=$(cat "$home/decision.txt")
  digest=$(printf '%s' "$decision" | shasum -a 256 | awk '{print $1}')
  create_resolved "$home" "$id" "$(resolved_body "$digest" sample-route-work)"
  archive_all_done "$home"
  tasks_in "$home" add sample-route-work "Synthetic routed work" --kind ship --repo sample >/dev/null
  run_decisions "$home" hold "$origin" layout --title "Choose synthetic layout" \
    --reason "captain layout pending" --repo sample >/dev/null \
    || fail "could not create the later active decision fixture"
  run_decisions "$home" complete "$origin" route layout >/dev/null \
    || fail "completion did not accept archived history plus the later active decision"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "default Done archive did not satisfy durable verification"
  before_active=$(file_digest "$home/data/backlog.md")
  before_archive=$(file_digest "$home/data/done-archive.md")
  output=$(run_decisions "$home" resolve "$origin" route --decision-file "$home/decision.txt" \
    --routed-to sample-route-work 2> "$home/retry.err") \
    || fail "exact archived resolution retry was not idempotent: $(cat "$home/retry.err")"
  assert_contains "$output" "resolved: $id" "archived resolution retry lost its identity"
  after_active=$(file_digest "$home/data/backlog.md")
  after_archive=$(file_digest "$home/data/done-archive.md")
  [ "$before_active" = "$after_active" ] || fail "archived resolution retry mutated the active backlog"
  [ "$before_archive" = "$after_archive" ] || fail "archived resolution retry mutated the Done archive"

  if run_decisions "$home" hold "$origin" route --title "Synthetic resolved decision" \
    --reason "captain route pending" --repo sample > "$home/hold.out" 2> "$home/hold.err"; then
    fail "archived decision became eligible for hold mutation"
  fi
  assert_grep "is archived and cannot be mutated" "$home/hold.err" \
    "archived hold retry did not report its active-only mutation boundary"
  [ "$before_active" = "$(file_digest "$home/data/backlog.md")" ] \
    || fail "archived hold retry created an active duplicate"
  [ "$before_archive" = "$(file_digest "$home/data/done-archive.md")" ] \
    || fail "archived hold retry rewrote the Done archive"
  pass "default archive fallback supports read-only retries and refuses archived mutation"
}

test_configured_archive_path() {
  local home origin id archive
  home=$(make_home configured-archive history/captain-decisions.md)
  origin=sample-configured-review
  id="$origin-decision-route"
  archive="$home/history/captain-decisions.md"
  write_origin_meta "$home" "$origin" route
  create_resolved "$home" "$id"
  archive_all_done "$home"
  assert_present "$archive" "tasks-axi did not use the configured archive path"
  assert_absent "$home/data/done-archive.md" "configured archive unexpectedly fell back to the default path"
  run_decisions "$home" verify "$origin" >/dev/null \
    || fail "configured Done archive did not satisfy durable verification"
  pass "durable lookup follows the configured archive path"
}

test_active_shadow_blocks_archive_resolution() {
  local home origin id
  home=$(make_home active-shadow default)
  origin=sample-shadow-review
  id="$origin-decision-route"
  write_origin_meta "$home" "$origin" route
  create_resolved "$home" "$id"
  archive_all_done "$home"
  tasks_in "$home" add "$id" "Synthetic active shadow" --kind captain --repo sample >/dev/null
  if run_decisions "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "valid archive history hid an invalid active shadow"
  fi
  assert_grep "neither actively held nor durably resolved" "$home/verify.err" \
    "active shadow did not retain canonical first-match behavior"
  pass "active decision identity shadows archive history"
}

test_true_miss_remains_absent() {
  local home origin
  home=$(make_home true-miss default)
  origin=sample-missing-review
  write_origin_meta "$home" "$origin" route
  if run_decisions "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "genuinely absent decision passed durable verification"
  fi
  assert_grep "is absent from the active backlog and Done archive" "$home/verify.err" \
    "true inclusive miss did not retain an absence result"
  assert_no_grep "malformed output" "$home/verify.err" "true miss was misclassified as malformed output"
  pass "genuine active-and-archive miss remains absent"
}

test_missing_capability_is_not_reported_as_absence() {
  local home origin id
  home=$(make_home missing-capability default)
  origin=sample-old-tool-review
  id="$origin-decision-route"
  write_origin_meta "$home" "$origin" route
  create_resolved "$home" "$id"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi show <id> [--full]\n'
  exit 0
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "decision verification accepted tasks-axi without archive lookup"
  fi
  assert_grep "tasks-axi show <id> --include-archive --full is required" "$home/verify.err" \
    "missing archive capability did not report the concrete tool requirement"
  assert_no_grep "is absent from" "$home/verify.err" \
    "missing archive capability was falsely reported as decision absence"
  pass "missing tasks-axi archive capability is distinct from absence"
}

test_malformed_tool_output_is_not_reported_as_absence() {
  local home origin id
  home=$(make_home malformed-output default)
  origin=sample-malformed-tool-review
  id="$origin-decision-route"
  write_origin_meta "$home" "$origin" route
  create_resolved "$home" "$id"
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = "$id" ] && [ "\${3:-}" = --include-archive ]; then
  printf 'task:\n  id: %s\n  source: archive\n' "$id"
  exit 0
fi
exec "\$REAL_TASKS_AXI" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "malformed archive lookup output passed durable verification"
  fi
  assert_grep "returned malformed output for $id" "$home/verify.err" \
    "malformed archive lookup did not report its concrete incompatibility"
  assert_no_grep "is absent from" "$home/verify.err" \
    "malformed archive lookup was falsely reported as decision absence"
  pass "malformed tasks-axi archive output is distinct from absence"
}

test_live_pin_exposes_archive_contract
test_active_hit_does_not_read_archive
test_default_archive_fallback_and_active_only_mutation
test_configured_archive_path
test_active_shadow_blocks_archive_resolution
test_true_miss_remains_absent
test_missing_capability_is_not_reported_as_absence
test_malformed_tool_output_is_not_reported_as_absence
