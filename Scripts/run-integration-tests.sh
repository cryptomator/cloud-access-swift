#!/bin/bash
#
# Runs the integration tests of an existing build in one parallel pass, then re-runs only the failed
# (test, backend) pairs once. Writes the pairs that are still failing to integration-output/still-failing.txt
# and a summary to $GITHUB_STEP_SUMMARY.
#
# Usage: Scripts/run-integration-tests.sh [--only <file>]
#
# Environment:
#   DERIVED_DATA_PATH  DerivedData of `xcodebuild build-for-testing -scheme AllIntegrationTests` (default: Xcode's default)
#   DEVICE             Simulator name (default: iPhone 17 Pro)
#   BACKENDS           INTEGRATION_BACKENDS filter, e.g. `pcloud,s3-vf7` (default: all backends)
#
# --only runs just the pairs of a still-failing.txt of an earlier run. Each of its lines is
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
mkdir -p "$OUTPUT_DIR"
rm -f "$STILL_FAILING_FILE"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# Prints the filter and the -only-testing arguments that re-run the pairs listed in the given file.
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

# Runs the pairs listed in the given file as the named pass.
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

# Parses a pass into $WORK_DIR/<name>.tsv: `<status>\t<nodeIdentifier>\t<token>\t<BACKENDS if the token is ->\t<failure message>` per pair.
# Returns non-zero if the pass is incomplete, e.g. if its result can't be read, a test process crashed, or the run failed without a failed test.
parse_pass() {
  local name="$1"
  xcrun xcresulttool get test-results tests --path "$WORK_DIR/$name.xcresult" > "$WORK_DIR/$name.json" 2> "$WORK_DIR/$name.parse-error" || return 1
  python3 -I - "$WORK_DIR/$name.json" "$(cat "$WORK_DIR/$name.exit")" "$BACKENDS" > "$WORK_DIR/$name.tsv" <<'EOF'
import json, re, sys

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
                pairs.append((argument.get("result", "unknown"), node_identifier, argument["name"], " ".join(messages(argument) + messages(node))))
        else:
            pairs.append((node.get("result", "unknown"), node_identifier, token_for(node_identifier), " ".join(messages(node))))
        return
    for child in node.get("children", []):
        walk(child)

for node in results.get("testNodes", []):
    walk(node)
if not pairs:
    incomplete = True
if exit_code != 0 and not any(status == "Failed" for status, *_ in pairs):
    incomplete = True
for status, node_identifier, token, message in pairs:
    flat_message = " ".join(message.split())
    print(f"{status}\t{node_identifier}\t{token}\t{backends if token == '-' else ''}\t{flat_message}")
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

python3 -I - "$WORK_DIR" "$STILL_FAILING_FILE" "$pass2_incomplete" "$PASSED_STATUSES" >> "$SUMMARY_FILE" <<'EOF'
import collections, os, sys

work_dir, still_failing_file, pass2_incomplete = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
passed = set(sys.argv[4].split("|"))
# A skipped re-run doesn't heal a failed pair.
healed_statuses = passed - {"Skipped"}

def read(name):
    path = os.path.join(work_dir, f"{name}.tsv")
    if not os.path.exists(path):
        return {}
    pairs = {}
    for line in open(path):
        status, node_identifier, token, backends, message = line.rstrip("\n").split("\t")
        pairs[(node_identifier, token, backends)] = (status, message)
    return pairs

pass1, pass2 = read("pass1"), read("pass2")
healed, still_failing = [], []
counts = collections.defaultdict(lambda: collections.Counter())
for key, (status, message) in pass1.items():
    token = key[1]
    if status == "Skipped":
        counts[token]["skipped"] += 1
    elif status in passed:
        counts[token]["passed"] += 1
    elif pass2.get(key, ("missing", ""))[0] in healed_statuses:
        counts[token]["passed on re-run"] += 1
        healed.append((key, message))
    else:
        counts[token]["failed"] += 1
        still_failing.append((key, pass2.get(key, (None, message))[1] or message))

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
    for (node_identifier, token, _), message in healed:
        print(f"- `{node_identifier}` `{token}`: {message or 'no failure message'}")
if still_failing:
    print("\n### Still failing\n")
    for (node_identifier, token, _), message in still_failing:
        print(f"- `{node_identifier}` `{token}`: {message or 'no failure message'}")
EOF
# A failed summary script fails the run, because still-failing.txt may then be incomplete.
summary_status=$?

# The retries within a pass are only logged to the console of the test process. The summary gets the test, backend,
# attempt and error domain and code (or else the error's first word) of each, but not the error description, which can
# contain request URLs with credentials.
for name in pass1 pass2; do
  if [ -d "$WORK_DIR/$name.xcresult" ]; then
    xcrun xcresulttool get log --path "$WORK_DIR/$name.xcresult" --type action 2> /dev/null | python3 -I -c '
import re, sys
retries = []
for match in re.finditer(r"\[integration-retry\] (\S+) (\S+) attempt (\d+): ([^\n\x5c\x22]*)", sys.stdin.read()):
    test, backend, attempt, error = match.groups()
    code = re.search(r"Domain=(\S+) Code=(-?\d+)", error)
    reason = f"{code.group(1)} {code.group(2)}" if code else re.split(r"[(:\s]", error, maxsplit=1)[0]
    retries.append(f"- {sys.argv[1]}: `{test}` `{backend}` attempt {attempt}: {reason}")
# The action log repeats the console output.
print("\n".join(dict.fromkeys(retries)))
' "$name"
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
