# Prints each failure of a test result bundle as one line: the test, the message and where it was recorded.
#
# Usage: /usr/bin/python3 -I Scripts/print-test-failures.py <xcresult>
#
# It exits 0 when it finds no readable bundle, so that the test step stays the only failed step.

import json, os, subprocess, sys


def failure_messages(node):
    return [child for child in node.get("children", []) if child.get("nodeType") == "Failure Message"]


def failure_line(identifier, message):
    location = message.get("sourceLocation")
    suffix = f" ({os.path.basename(location['filePath'])}:{location['lineNumber']})" if location else ""
    # A Swift Testing message lists the expression's values on lines of their own.
    text = " | ".join(line.strip() for line in message.get("name", "").splitlines() if line.strip())
    return f"{identifier}: {text}{suffix}"


def walk(node, lines):
    if node.get("nodeType") == "Test Case":
        identifier = node.get("nodeIdentifier", node.get("name", ""))
        for message in failure_messages(node):
            lines.append(failure_line(identifier, message))
        for argument in node.get("children", []):
            if argument.get("nodeType") == "Arguments":
                for message in failure_messages(argument):
                    lines.append(failure_line(f"{identifier}[{argument.get('name', '')}]", message))
        return
    for child in node.get("children", []):
        walk(child, lines)


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print(f"print-test-failures: no result bundle at {sys.argv[1] if len(sys.argv) > 1 else '(none given)'}")
        return
    try:
        output = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", sys.argv[1], "--compact"], check=True, capture_output=True, text=True).stdout
        results = json.loads(output)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"print-test-failures: can't read {sys.argv[1]}: {error}")
        return
    lines = []
    for node in results.get("testNodes", []):
        walk(node, lines)
    print("\n".join(lines) if lines else "print-test-failures: the result bundle holds no failure")


main()
