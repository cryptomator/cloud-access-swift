#!/bin/sh
#
# Based on https://merowing.info/2021/01/improve-build-times-by-extracting-3rd-party-tooling-to-processing-script./

cd "$(dirname "$0")/.."

if [[ "$1" == "--staged" ]]; then
  staged_mode=true
  echo "Running in --staged mode"
else
  echo "Running in full mode"
fi

final_status=0

function process_output() {
  printf '\n# Running %s\n' "$1"
  local start=$(date +%s)
  local output=$(eval "$2" 2>&1)
  if [[ ! -z "$output" ]]; then
    printf -- '---\n%s\n---\n' "$output"
    final_status=1
  fi
  local end=$(date +%s)
  printf 'Execution time was %s seconds.\n' "$((end - start))"
}

# Lints the staged contents of the staged Swift files from a scratch tree that keeps their repository paths, because SwiftLint can't be told the path of standard input, which the path-scoped custom rules need.
function lint_staged_swift() {
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/process-staged.XXXXXX") || return 1
  # Only the paths of .swiftlint.yml's `included`, because SwiftLint fails with "No lintable files found" when every copied file lies outside them (e.g. Package.swift alone).
  git diff --cached --name-only --diff-filter=ACMR -z -- 'Sources/*.swift' 'Tests/*.swift' | while IFS= read -r -d '' path; do
    mkdir -p "$scratch/$(dirname "$path")" && git show ":$path" > "$scratch/$path"
  done
  if [ -n "$(find "$scratch" -name '*.swift' -print -quit)" ]; then
    # Run from the scratch tree with the configuration copied there, because SwiftLint lints the configuration's own `included` paths instead of a path outside its directory.
    cp .swiftlint.yml "$scratch/" && (cd "$scratch" && swiftlint lint --quiet) | sed "s|^.*/$(basename "$scratch")/||"
  fi
  rm -rf "$scratch"
}

if [ "$staged_mode" = true ]; then
  process_output "SwiftFormat" "python3 ./Scripts/git-format-staged.py -f 'swiftformat stdin --stdinpath \"{}\" --quiet' '*.swift'"
  process_output "SwiftLint" "lint_staged_swift"
  if [[ "$final_status" -gt 0 ]]; then
    printf '\nChanges werde made or are required. Please review the output above for further details.\n'
  fi
else
  process_output "SwiftFormat" "swiftformat --lint --quiet ."
  process_output "SwiftLint" "swiftlint --quiet ."
  if [[ "$final_status" -gt 0 ]]; then
    printf '\nChanges are required. Please review the output above for further details.\n'
  fi
fi

exit $final_status
