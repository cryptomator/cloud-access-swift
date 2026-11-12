# Prints the filter and the -only-testing arguments that re-run the tests listed in a file on every backend the file lists, which can include backends that a test didn't fail on.
#
# Usage: selection.py <pairs file> <test bundle>

import sys
lines = [line.rstrip("\n").split("\t") for line in open(sys.argv[1]) if line.strip()]
if not lines or any(len(fields) < 2 or not fields[0].strip() or not fields[1].strip() for fields in lines):
    sys.exit(f"{sys.argv[1]} lists no pairs, or a line has no test or token")
tokens = []
all_backends = False
for fields in lines:
    if fields[1] == "-":
        original = fields[2] if len(fields) > 2 else ""
        # An empty filter selects all backends, so it must not narrow the filter to the other lines' tokens.
        all_backends = all_backends or not original
        tokens += [token for token in original.split(",") if token]
    else:
        tokens.append(fields[1])
print("" if all_backends else ",".join(dict.fromkeys(tokens)))
for node_identifier in dict.fromkeys(fields[0] for fields in lines):
    print(f"-only-testing:{sys.argv[2]}/{node_identifier}")
