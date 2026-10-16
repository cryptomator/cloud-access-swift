#!/bin/bash
#
# Runs the integration tests of an existing build in one parallel pass, then re-runs the failed tests once on the
# backends that had failures. Writes the (test, backend) pairs that are still failing to
# integration-output/still-failing.txt and a summary to $GITHUB_STEP_SUMMARY.
#
# Usage: Scripts/run-integration-tests.sh [--only <file>]
#
# Environment:
#   DERIVED_DATA_PATH  DerivedData of `xcodebuild build-for-testing -scheme AllIntegrationTests` (default: Xcode's default)
#   DEVICE             Simulator name (default: iPhone 17 Pro)
#   BACKENDS           INTEGRATION_BACKENDS filter, e.g. `pcloud,s3-vf7` (default: all backends)
#
# --only runs just the tests of a still-failing.txt of an earlier run, on the backends it lists. Each of its lines is
# `<nodeIdentifier>\t<token>`, where the token is a backend token (`pcloud-vf7`), a provider token
# (`s3`) for provider-specific tests, or `-` followed by `\t<BACKENDS of that run>` for tests of no backend.

set -uo pipefail

DEVICE="${DEVICE:-iPhone 17 Pro}"
BACKENDS="${BACKENDS:-}"
OUTPUT_DIR="integration-output"
STILL_FAILING_FILE="$OUTPUT_DIR/still-failing.txt"
TEST_BUNDLE="CryptomatorCloudAccessIntegrationTests"
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

# The result bundles and logs stay out of the output directory, because S3 logs contain the access key ID.
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
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# The summary is public, and an S3 error's description can contain request URLs with credentials. So a failure message
# is reduced to a part that can't contain them: an error's domain and code, a case of a known error, a known error that
# wasn't thrown, or that an expectation failed. Anything else becomes `details withheld`. Expectations aren't quoted,
# because tests interpolate metadata, contents and errors into them.
cat > "$WORK_DIR/failure_reason.py" <<'EOF'
import re

# The cases of CloudProviderError and IntegrationTestError.
KNOWN_ERRORS = {
    "itemNotFound", "itemAlreadyExists", "itemTypeMismatch", "parentFolderDoesNotExist", "pageTokenInvalid",
    "quotaInsufficient", "unauthorized", "noInternetConnection",
    "consistencyTimeout", "itemNotVisible", "fixtureTimeout", "budgetExceeded",
}

def reason(message):
    message = message.strip()
    if not message:
        return ""
    domain_code = re.search(r"\bError Domain=([A-Za-z0-9_.-]+) Code=(-?\d+)", message)
    if domain_code:
        return f"{domain_code.group(1)} {domain_code.group(2)}"
    known_error = re.fullmatch(r"(?:Caught error: )?([A-Za-z]+)(?:\(.*\))?", message, re.DOTALL)
    if known_error and known_error.group(1) in KNOWN_ERRORS:
        return known_error.group(1)
    not_thrown = re.fullmatch(r"Expected ([A-Za-z]+), but nothing was thrown", message)
    if not_thrown and not_thrown.group(1) in KNOWN_ERRORS:
        return message
    if message.startswith("Expectation failed"):
        return "expectation failed"
    return "details withheld"
EOF

# Prints the filter and the -only-testing arguments that re-run the tests listed in the given file on all of its
# backends, which can include backends that a test didn't fail on.
selection_for() {
  python3 -I - "$1" "$TEST_BUNDLE" <<'EOF'
import sys
lines = [line.rstrip("\n").split("\t") for line in open(sys.argv[1]) if line.strip()]
if not lines or any(len(fields) < 2 or not fields[0].strip() or not fields[1].strip() for fields in lines):
    sys.exit(f"{sys.argv[1]} lists no pairs, or a line has no test or token")
tokens = []
for fields in lines:
    if fields[1] == "-":
        original = fields[2] if len(fields) > 2 else ""
        tokens += [token for token in original.split(",") if token]
    else:
        tokens.append(fields[1])
print(",".join(dict.fromkeys(tokens)))
for node_identifier in dict.fromkeys(fields[0] for fields in lines):
    print(f"-only-testing:{sys.argv[2]}/{node_identifier}")
EOF
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

# Runs a pass and writes its exit code to $WORK_DIR/<name>.exit. Arguments: name, filter, -only-testing arguments.
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
    -scheme AllIntegrationTests \
    -destination "name=$DEVICE" \
    ${derived_data_args[@]+"${derived_data_args[@]}"} \
    -resultBundlePath "$WORK_DIR/$name.xcresult" \
    -collect-test-diagnostics never \
    ${1+"$@"} 2>&1 | "${formatter[@]}"
  echo "${PIPESTATUS[0]}" > "$WORK_DIR/$name.exit"
  echo "::endgroup::"
}

# Parses a pass into $WORK_DIR/<name>.tsv: `<status>\t<nodeIdentifier>\t<token>\t<BACKENDS if the token is ->\t<failure reasons>` per pair.
# Returns non-zero if the pass is incomplete, e.g. if its result can't be read, a test process crashed, or the run failed without a failed test.
parse_pass() {
  local name="$1"
  xcrun xcresulttool get test-results tests --path "$WORK_DIR/$name.xcresult" > "$WORK_DIR/$name.json" 2> "$WORK_DIR/$name.parse-error" || return 1
  python3 -I - "$WORK_DIR/$name.json" "$(cat "$WORK_DIR/$name.exit")" "$BACKENDS" "$WORK_DIR" > "$WORK_DIR/$name.tsv" <<'EOF'
import json, re, sys

sys.path.insert(0, sys.argv[4])
from failure_reason import reason

results = json.load(open(sys.argv[1]))
exit_code = int(sys.argv[2])
backends = sys.argv[3]
backend_token = re.compile(r"^[a-z0-9]+-[a-z0-9]+$")
# A crashed test process is reported as a failure message like `Crash: xctest` of the test or its argument.
crash_marker = re.compile(r"^Crash: |did not finish|restarting after unexpected exit|lost connection", re.IGNORECASE)
pairs = []
incomplete = False

def messages(node):
    return [child.get("name", "") for child in node.get("children", []) if child.get("nodeType") == "Failure Message"]

def reasons(failure_messages):
    return "; ".join(dict.fromkeys(filter(None, map(reason, failure_messages))))

def token_for(node_identifier):
    match = re.search(r"(?:^|/)ProviderSpecific/([^/]+)Tests/", node_identifier)
    return match.group(1).lower() if match else "-"

def walk(node):
    global incomplete
    if node.get("nodeType") == "Test Case":
        node_identifier = node["nodeIdentifier"]
        # A test process that couldn't run, e.g. because the simulator couldn't be cloned, is reported as a test case whose
        # identifier names no test, like `The test runner encountered an error`.
        if "/" not in node_identifier:
            incomplete = True
            return
        arguments = [child for child in node.get("children", []) if child.get("nodeType") == "Arguments"]
        if any(crash_marker.search(message) for target in [node] + arguments for message in messages(target)):
            incomplete = True
        if arguments and all(backend_token.match(argument.get("name", "")) for argument in arguments):
            for argument in arguments:
                pairs.append((argument.get("result", "unknown"), node_identifier, argument["name"], reasons(messages(argument) + messages(node))))
        else:
            pairs.append((node.get("result", "unknown"), node_identifier, token_for(node_identifier), reasons(messages(node))))
        return
    for child in node.get("children", []):
        walk(child)

for node in results.get("testNodes", []):
    walk(node)
if not pairs:
    incomplete = True
if exit_code != 0 and not any(status == "Failed" for status, *_ in pairs):
    incomplete = True
for status, node_identifier, token, failure_reasons in pairs:
    print(f"{status}\t{node_identifier}\t{token}\t{backends if token == '-' else ''}\t{failure_reasons}")
sys.exit(1 if incomplete else 0)
EOF
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
  run_pass pass1 "$BACKENDS"
fi

if ! parse_pass pass1; then
  {
    echo "## Integration tests"
    echo
    echo ":x: The main pass did not complete (crash, unreadable results, or a failure that no test reported). Nothing was re-run, and the next attempt runs everything."
  } >> "$SUMMARY_FILE"
  echo "The main pass did not complete." >&2
  exit 1
fi

not_passed pass1 > "$WORK_DIR/failed-pass1.txt"
pass2_incomplete=false
if [ -s "$WORK_DIR/failed-pass1.txt" ]; then
  run_selected_pass pass2 "$WORK_DIR/failed-pass1.txt"
  if ! parse_pass pass2; then
    pass2_incomplete=true
    : > "$WORK_DIR/pass2.tsv"
  fi
fi

python3 -I - "$WORK_DIR" "$STILL_FAILING_FILE" "$pass2_incomplete" "$ONLY_FILE" "$PASSED_STATUSES" >> "$SUMMARY_FILE" <<'EOF'
import collections, os, sys

work_dir, still_failing_file, pass2_incomplete, only_file = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4]
# A skip doesn't heal a pair that failed before: a pair of the re-run pass, or a pair that --only lists. A listed pair
# that the main pass skips isn't re-run, because the re-run would select it the same way and skip it again.
healed_statuses = set(sys.argv[5].split("|")) - {"Skipped"}
# The BACKENDS of each pair that --only lists, which only a `-` token's line has.
only_lines = [line.rstrip("\n").split("\t") for line in open(only_file) if line.strip()] if only_file else []
listed = {tuple(fields[:2]): fields[2] if len(fields) > 2 else "" for fields in only_lines}

def read(name):
    path = os.path.join(work_dir, f"{name}.tsv")
    if not os.path.exists(path):
        return {}
    pairs = {}
    for line in open(path):
        status, node_identifier, token, backends, failure_reasons = line.rstrip("\n").split("\t")
        pairs[(node_identifier, token, backends)] = (status, failure_reasons)
    return pairs

pass1, pass2 = read("pass1"), read("pass2")
healed, still_failing = [], []
counts = collections.defaultdict(lambda: collections.Counter())
for key, (status, failure_reasons) in pass1.items():
    token = key[1]
    if status == "Skipped" and key[:2] not in listed:
        counts[token]["skipped"] += 1
    elif status in healed_statuses:
        counts[token]["passed"] += 1
    elif pass2.get(key, ("missing", ""))[0] in healed_statuses:
        counts[token]["passed on re-run"] += 1
        healed.append((key, failure_reasons))
    else:
        counts[token]["failed"] += 1
        still_failing.append((key, pass2.get(key, (None, failure_reasons))[1] or failure_reasons))
# A listed pair that the main pass has no result for stays failing, so a test that didn't run can't drop out of
# still-failing.txt. It isn't re-run either, because the re-run would select it the same way.
reported = {key[:2] for key in pass1}
for (node_identifier, token), backends in listed.items():
    if (node_identifier, token) not in reported:
        counts[token]["failed"] += 1
        still_failing.append(((node_identifier, token, backends), "no result"))

with open(still_failing_file, "w") as file:
    for (node_identifier, token, backends), _ in still_failing:
        file.write(f"{node_identifier}\t{token}" + (f"\t{backends}" if token == "-" else "") + "\n")

print("## Integration tests\n")
print("| Backend | Passed | Failed | Passed on re-run | Skipped |")
print("| --- | ---: | ---: | ---: | ---: |")
for token in sorted(counts):
    print(f"| `{token}` | {counts[token]['passed']} | {counts[token]['failed']} | {counts[token]['passed on re-run']} | {counts[token]['skipped']} |")
if pass2_incomplete:
    print("\n:x: The re-run pass did not complete, so its pairs count as still failing.")
if healed:
    print("\n### Passed only on re-run\n")
    for (node_identifier, token, _), failure_reasons in healed:
        print(f"- `{node_identifier}` `{token}`: {failure_reasons or 'no failure message'}")
if still_failing:
    print("\n### Still failing\n")
    for (node_identifier, token, _), failure_reasons in still_failing:
        print(f"- `{node_identifier}` `{token}`: {failure_reasons or 'no failure message'}")
EOF
# A failed summary script fails the run, because still-failing.txt may then be incomplete.
summary_status=$?

# The retries within a pass are only logged to the console of the test process, so they are read from the action log.
for name in pass1 pass2; do
  if [ -d "$WORK_DIR/$name.xcresult" ]; then
    xcrun xcresulttool get log --path "$WORK_DIR/$name.xcresult" --type action 2> /dev/null | python3 -I -c '
import re, sys
sys.path.insert(0, sys.argv[2])
from failure_reason import reason
retries = []
for match in re.finditer(r"\[integration-retry\] (\S+) (\S+) attempt (\d+): ([^\n\x5c\x22]*)", sys.stdin.read()):
    test, backend, attempt, error = match.groups()
    failure_reason = reason(error) or "no failure message"
    retries.append(f"- {sys.argv[1]}: `{test}` `{backend}` attempt {attempt}: {failure_reason}")
# The action log repeats the console output.
print("\n".join(dict.fromkeys(retries)))
' "$name" "$WORK_DIR"
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

if [ "$summary_status" -ne 0 ] || [ -s "$STILL_FAILING_FILE" ] || [ "$pass2_incomplete" = true ]; then
  exit 1
fi
