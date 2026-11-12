#!/bin/bash
#
# Runs the integration tests of an existing build in one parallel pass, then re-runs the failed tests once on the
# backends that had failures. Writes the (test, backend) pairs that are still failing to
# integration-output/still-failing.txt and a summary to the log and $GITHUB_STEP_SUMMARY.
#
# Usage: Scripts/run-integration-tests.sh [--only <file>]
#
# Environment:
#   DERIVED_DATA_PATH  DerivedData of `xcodebuild build-for-testing -scheme CryptomatorCloudAccess-Package` (default: Xcode's default)
#   DEVICE             Simulator name (default: iPhone 17)
#   BACKENDS           INTEGRATION_BACKENDS filter, e.g. `pcloud,s3-vf8` (default: all backends, ignored with --only)
#
# --only runs just the tests of a still-failing.txt of an earlier run, on the backends it lists. Each of its lines is
# `<nodeIdentifier>\t<token>`, where the token is a backend token (`pcloud-vf8`), a provider token
# (`s3`) for provider-specific tests, or `-` followed by `\t<filter of that run's main pass>` for tests of no backend.

set -uo pipefail

DEVICE="${DEVICE:-iPhone 17}"
BACKENDS="${BACKENDS:-}"
OUTPUT_DIR="integration-output"
STILL_FAILING_FILE="$OUTPUT_DIR/still-failing.txt"
TEST_BUNDLE="CryptomatorCloudAccessIntegrationTests"
PYTHON_DIR="$(dirname "$0")/integration-tests"
# A pair passes only with one of these results.
PASSED_STATUSES="Passed|Expected Failure|Skipped"
ONLY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      ONLY_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# The result bundles and logs stay out of the output directory, which CI uploads artifacts from. A failed expectation can print a credential into a result bundle, and nothing checks the logs for credentials.
# On CI, the runner empties RUNNER_TEMP after the job even when it kills the script.
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/integration-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
# --only can name the still-failing.txt that this run replaces.
if [ -n "$ONLY_FILE" ]; then
  if ! cp "$ONLY_FILE" "$WORK_DIR/only.txt"; then
    echo "Can't read the pairs to run from $ONLY_FILE." >&2
    exit 2
  fi
  ONLY_FILE="$WORK_DIR/only.txt"
fi
mkdir -p "$OUTPUT_DIR"
rm -f "$STILL_FAILING_FILE"
SUMMARY_FILE="$WORK_DIR/summary.md"

# Prints the filter and the -only-testing arguments that re-run the tests listed in the given file on all of its
# backends, which can include backends that a test didn't fail on.
selection_for() {
  python3 -I "$PYTHON_DIR/selection.py" "$1" "$TEST_BUNDLE"
}

# Runs the tests listed in the given file on its backends as the named pass.
run_selected_pass() {
  local name="$1" filter only_testing=() line
  # A selection that can't be read must not turn into a run of everything.
  if ! selection_for "$2" > "$WORK_DIR/$name.selection"; then
    echo "Can't read the pairs to run from $2." >&2
    exit 2
  fi
  {
    IFS= read -r filter
    while IFS= read -r line; do
      only_testing+=("$line")
    done
  } < "$WORK_DIR/$name.selection"
  run_pass "$name" "$filter" ${only_testing[@]+"${only_testing[@]}"}
}

# Runs a pass and writes its exit code and filter to $WORK_DIR/<name>.exit and <name>.filter. Arguments: name, filter,
# -only-testing arguments.
run_pass() {
  local name="$1" filter="$2"
  shift 2
  local formatter=(cat)
  if command -v xcbeautify > /dev/null; then
    formatter=(xcbeautify)
  fi
  echo "::group::Integration tests, $name (INTEGRATION_BACKENDS=${filter:-all})"
  local derived_data_args=()
  if [ -n "${DERIVED_DATA_PATH:-}" ]; then
    derived_data_args=(-derivedDataPath "$DERIVED_DATA_PATH")
  fi
  env NSUnbufferedIO=YES TEST_RUNNER_INTEGRATION_BACKENDS="$filter" xcodebuild test-without-building \
    -scheme CryptomatorCloudAccess-Package \
    -destination "name=$DEVICE" \
    ${derived_data_args[@]+"${derived_data_args[@]}"} \
    -resultBundlePath "$WORK_DIR/$name.xcresult" \
    -collect-test-diagnostics never \
    "$@" 2>&1 | "${formatter[@]}"
  echo "${PIPESTATUS[0]}" > "$WORK_DIR/$name.exit"
  echo "$filter" > "$WORK_DIR/$name.filter"
  echo "::endgroup::"
}

# Parses a pass into $WORK_DIR/<name>.tsv: `<status>\t<nodeIdentifier>\t<token>\t<filter of the main pass if the token is ->\t<failure reasons>` per pair.
# Both passes record the main pass's filter, which the re-run's own filter can differ from, so that their pairs match.
# Returns non-zero if the pass is incomplete, e.g. if its result can't be read, a test process crashed, or the run failed
# without a failed test. It then writes why to $WORK_DIR/<name>.incomplete.
parse_pass() {
  local name="$1"
  if ! xcrun xcresulttool get test-results tests --path "$WORK_DIR/$name.xcresult" > "$WORK_DIR/$name.json"; then
    echo "its results can't be read" > "$WORK_DIR/$name.incomplete"
    return 1
  fi
  python3 -I "$PYTHON_DIR/parse_pass.py" "$WORK_DIR/$name.json" "$(cat "$WORK_DIR/$name.exit")" "$(cat "$WORK_DIR/pass1.filter")" "$WORK_DIR/$name.incomplete" > "$WORK_DIR/$name.tsv"
  local parse_status=$?
  if [ "$parse_status" -ne 0 ] && [ ! -s "$WORK_DIR/$name.incomplete" ]; then
    echo "its results can't be parsed" > "$WORK_DIR/$name.incomplete"
  fi
  return "$parse_status"
}

# The job summary can't be read through the API, so the log gets the summary too.
publish_summary() {
  tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" < "$SUMMARY_FILE"
}

# Prints the pairs of a parsed pass that didn't pass, as lines of a still-failing.txt.
not_passed() {
  awk -F'\t' -v statuses="$PASSED_STATUSES" '
    BEGIN { split(statuses, list, "|"); for (i in list) passed[list[i]] = 1 }
    !($1 in passed) { line = $2 "\t" $3; if ($3 == "-") line = line "\t" $4; print line }
  ' "$WORK_DIR/$1.tsv"
}

if [ -n "$ONLY_FILE" ]; then
  run_selected_pass pass1 "$ONLY_FILE"
else
  # The scheme also holds the unit tests.
  run_pass pass1 "$BACKENDS" "-only-testing:$TEST_BUNDLE"
fi

if ! parse_pass pass1; then
  {
    echo "## Integration tests"
    echo
    echo ":x: The main pass did not complete: $(cat "$WORK_DIR/pass1.incomplete"). Nothing was re-run, and the next attempt runs everything."
  } >> "$SUMMARY_FILE"
  publish_summary
  exit 1
fi

not_passed pass1 > "$WORK_DIR/failed-pass1.txt"
if [ -s "$WORK_DIR/failed-pass1.txt" ]; then
  run_selected_pass pass2 "$WORK_DIR/failed-pass1.txt"
  if ! parse_pass pass2; then
    : > "$WORK_DIR/pass2.tsv"
  fi
fi

python3 -I "$PYTHON_DIR/summary.py" "$WORK_DIR" "$STILL_FAILING_FILE" "$ONLY_FILE" "$PASSED_STATUSES" >> "$SUMMARY_FILE"
# A failed summary script fails the run, because still-failing.txt may then be incomplete.
summary_status=$?

# The retries within a pass are only logged to the console of the test process, so they are read from the action log.
for name in pass1 pass2; do
  if [ -d "$WORK_DIR/$name.xcresult" ]; then
    xcrun xcresulttool get log --path "$WORK_DIR/$name.xcresult" --type action 2> /dev/null | python3 -I "$PYTHON_DIR/retry_log.py" "$name"
  fi
done | grep -v '^$' > "$WORK_DIR/retries.md"
if [ -s "$WORK_DIR/retries.md" ]; then
  {
    echo
    echo "<details><summary>Retried in-process ($(wc -l < "$WORK_DIR/retries.md" | tr -d ' '))</summary>"
    echo
    cat "$WORK_DIR/retries.md"
    echo
    echo "</details>"
  } >> "$SUMMARY_FILE"
fi
publish_summary

if [ "$summary_status" -ne 0 ] || [ -s "$STILL_FAILING_FILE" ] || [ -s "$WORK_DIR/pass2.incomplete" ]; then
  exit 1
fi
