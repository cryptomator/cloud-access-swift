# Prints the summary of both passes and writes the pairs that are still failing to the given file.
#
# Usage: summary.py <work dir> <still-failing file> <only file> <passed statuses>

import collections, os, sys

work_dir, still_failing_file, only_file = sys.argv[1], sys.argv[2], sys.argv[3]
pass2_incomplete_file = os.path.join(work_dir, "pass2.incomplete")
# A skip doesn't heal a pair that failed before: a pair of the re-run pass, or a pair that --only lists. A listed pair
# that the main pass skips isn't re-run, because the re-run would select it the same way and skip it again.
healed_statuses = set(sys.argv[4].split("|")) - {"Skipped"}
# The filter of each pair that --only lists, which only a `-` token's line has.
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
if os.path.exists(pass2_incomplete_file):
    cause = open(pass2_incomplete_file).read().strip()
    print(f"\n:x: The re-run pass did not complete: {cause}. Its pairs count as still failing.")
if healed:
    print("\n### Passed only on re-run\n")
    for (node_identifier, token, _), failure_reasons in healed:
        print(f"- `{node_identifier}` `{token}`: {failure_reasons or 'no failure message'}")
if still_failing:
    print("\n### Still failing\n")
    for (node_identifier, token, _), failure_reasons in still_failing:
        print(f"- `{node_identifier}` `{token}`: {failure_reasons or 'no failure message'}")
