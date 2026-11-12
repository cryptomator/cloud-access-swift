# Reads the action log of a pass from stdin and prints its in-process retries as lines of the summary.
#
# Usage: retry_log.py <pass name>

import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from failure_reason import reason

def retry_lines(log, pass_name):
    retries = []
    for match in re.finditer(r'\[integration-retry\] (\S+) (\S+) attempt (\d+): ([^\n\\"]*)', log):
        test, backend, attempt, error = match.groups()
        failure_reason = reason(error) or "no failure message"
        retries.append(f"- {pass_name}: `{test}` `{backend}` attempt {attempt}: {failure_reason}")
    # The action log repeats the console output.
    return list(dict.fromkeys(retries))

if __name__ == "__main__":
    print("\n".join(retry_lines(sys.stdin.read(), sys.argv[1])))
