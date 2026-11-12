# Prints the pairs of a pass as tab-separated lines. Exits non-zero if the pass is incomplete, and then writes why to the given file.
#
# Usage: parse_pass.py <json> <exit code> <main pass filter> <incomplete file>

import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from failure_reason import reason

results = json.load(open(sys.argv[1]))
exit_code = int(sys.argv[2])
backends = sys.argv[3]
backend_token = re.compile(r"^[a-z0-9]+-[a-z0-9]+$")
# A crashed test process is reported as a failure message like `Crash: xctest` of the test or its argument, or as the
# underlying error of a test runner error.
crash_marker = re.compile(r"^Crash: |Underlying Error: Crash: |did not finish|restarting after unexpected exit|lost connection", re.IGNORECASE)
# A test process that exits before it starts testing is reported as `Early unexpected exit, operation never finished bootstrapping`.
bootstrap_marker = re.compile(r"never finished bootstrapping")
pairs = []
# Why the pass is incomplete, in fixed words, because the messages behind them aren't redacted.
incomplete_causes = []

def messages(node):
    return [(child.get("name", ""), child.get("sourceLocation")) for child in node.get("children", []) if child.get("nodeType") == "Failure Message"]

# The file name and line can't contain credentials, and they tell which check failed.
def located_reason(message):
    text, location = message
    failure_reason = reason(text)
    if failure_reason and location:
        return f"{failure_reason} ({os.path.basename(location['filePath'])}:{location['lineNumber']})"
    return failure_reason

def reasons(failure_messages):
    return "; ".join(dict.fromkeys(filter(None, map(located_reason, failure_messages))))

def runner_error_cause(node):
    texts = [text for text, _ in messages(node)]
    if any(bootstrap_marker.search(text) for text in texts):
        crashed = any(crash_marker.search(text) for text in texts)
        return "the test process crashed before testing started" if crashed else "the test process exited before testing started"
    return "the test runner reported an error"

def token_for(node_identifier):
    match = re.search(r"(?:^|/)ProviderSpecific/([^/]+)Tests/", node_identifier)
    return match.group(1).lower() if match else "-"

def walk(node):
    if node.get("nodeType") == "Test Case":
        node_identifier = node["nodeIdentifier"]
        # A test process that couldn't run, e.g. because the simulator couldn't be cloned, is reported as a test case whose
        # identifier names no test, like `The test runner encountered an error`.
        if "/" not in node_identifier:
            incomplete_causes.append(runner_error_cause(node))
            return
        arguments = [child for child in node.get("children", []) if child.get("nodeType") == "Arguments"]
        if any(crash_marker.search(text) for target in [node] + arguments for text, _ in messages(target)):
            incomplete_causes.append("a test process crashed")
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
# Only when the walk found no cause, because a runner error or crash also leaves no results or a failure without a failed test.
if not incomplete_causes:
    if not pairs:
        incomplete_causes.append("no test reported a result")
    elif exit_code != 0 and not any(status == "Failed" for status, *_ in pairs):
        incomplete_causes.append("it failed without a failed test")
for status, node_identifier, token, failure_reasons in pairs:
    print(f"{status}\t{node_identifier}\t{token}\t{backends if token == '-' else ''}\t{failure_reasons}")
if incomplete_causes:
    with open(sys.argv[4], "w") as file:
        file.write("; ".join(dict.fromkeys(incomplete_causes)))
    sys.exit(1)
