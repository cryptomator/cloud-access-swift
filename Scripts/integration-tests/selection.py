# Prints the filter and the -only-testing arguments that re-run the tests listed in a file on every backend the file lists, which can include backends that a test didn't fail on.
#
# Usage: selection.py <pairs file> <test bundle>

import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pairs

try:
    listed = pairs.read_listed(sys.argv[1])
except ValueError as error:
    sys.exit(str(error))
tokens = []
all_backends = False
for _, token, original in listed:
    if token == "-":
        # An empty filter selects all backends, so it must not narrow the filter to the other lines' tokens.
        all_backends = all_backends or not original
        tokens += [backend for backend in original.split(",") if backend]
    else:
        tokens.append(token)
print("" if all_backends else ",".join(dict.fromkeys(tokens)))
for node_identifier in dict.fromkeys(node_identifier for node_identifier, _, _ in listed):
    print(f"-only-testing:{sys.argv[2]}/{node_identifier}")
