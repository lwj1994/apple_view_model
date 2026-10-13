#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Enable OSLog's lazy debug interpolation in this test process only.
OS_ACTIVITY_MODE=debug swift test --no-parallel --enable-code-coverage

build_dir="$(swift build --show-bin-path)"
# SwiftPM's native and Swift Build backends use different test bundle names.
# Resolve each bundle's executable explicitly; native builds also put a .dSYM
# directory beside it, which must not be counted as another executable.
test_binaries=()
for test_bundle in "$build_dir"/*.xctest; do
  test_binary="$test_bundle/Contents/MacOS/$(basename "$test_bundle" .xctest)"
  if [[ -f "$test_binary" ]]; then
    test_binaries+=("$test_binary")
  fi
done
if [[ ${#test_binaries[@]} -ne 1 ]]; then
  echo "Expected one XCTest executable in $build_dir" >&2
  exit 1
fi

xcrun llvm-cov export \
  -format=lcov \
  -instr-profile="$build_dir/codecov/default.profdata" \
  -ignore-filename-regex='(/Tests/|/\.build/)' \
  "${test_binaries[0]}" > .build/coverage.lcov

test -s .build/coverage.lcov
echo "Coverage report: .build/coverage.lcov"
awk -F: '
  /^LF:/ { found += $2 }
  /^LH:/ { hit += $2 }
  END {
    if (found == 0) {
      print "No executable source lines found in coverage report." > "/dev/stderr"
      exit 1
    }
    printf "Source line coverage: %d/%d (%.2f%%)\n", hit, found, 100 * hit / found
    if (hit != found) {
      print "Source line coverage must be 100%." > "/dev/stderr"
      exit 1
    }
  }
' .build/coverage.lcov
