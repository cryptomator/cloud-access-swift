# Owns the (test, backend) pairs that the runner's steps hand to each other, and which of their results count as passed.
# A line of a parsed pass is `<status>\t<nodeIdentifier>\t<token>\t<filter>\t<failure reasons>`, where the filter is the main pass's if the token is `-` and empty otherwise.
# A listed line (still-failing.txt, --only, the pairs to re-run) is `<nodeIdentifier>\t<token>`, plus `\t<filter>` if the token is `-`.
# As a script, prints the pairs of a parsed pass to re-run, as listed lines.
#
# Usage: pairs.py <parsed pass>

import collections, os, sys

# A skip doesn't heal a pair that failed before, and it adds nothing to the re-run selection.
PASSED = {"Passed", "Expected Failure"}
SKIPPED = "Skipped"

Pair = collections.namedtuple("Pair", "status node_identifier token filter reasons")

def format_pass_line(pair):
    return f"{pair.status}\t{pair.node_identifier}\t{pair.token}\t{pair.filter if pair.token == '-' else ''}\t{pair.reasons}"

def read_pass(path):
    if not os.path.exists(path):
        return []
    return [Pair(*line.rstrip("\n").split("\t")) for line in open(path)]

def format_listed_line(node_identifier, token, filter):
    return f"{node_identifier}\t{token}" + (f"\t{filter}" if token == "-" else "")

def read_listed(path):
    lines = [line.rstrip("\n").split("\t") for line in open(path) if line.strip()]
    if not lines or any(len(fields) < 2 or not fields[0].strip() or not fields[1].strip() for fields in lines):
        raise ValueError(f"{path} lists no pairs, or a line has no test or token")
    return [(fields[0], fields[1], fields[2] if fields[1] == "-" and len(fields) > 2 else "") for fields in lines]

def not_passed(pairs):
    return [pair for pair in pairs if pair.status not in PASSED and pair.status != SKIPPED]

if __name__ == "__main__":
    for pair in not_passed(read_pass(sys.argv[1])):
        print(format_listed_line(pair.node_identifier, pair.token, pair.filter))
