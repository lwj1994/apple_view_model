#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Enable OSLog's lazy debug interpolation in this test process only.
OS_ACTIVITY_MODE=debug swift test --no-parallel --enable-code-coverage

build_dir="$(swift build --show-bin-path)"
# SwiftPM's native and Swift Build backends use different test bundle names.
test_binaries=("$build_dir"/*.xctest/Contents/MacOS/*)
if [[ ${#test_binaries[@]} -ne 1 || ! -f "${test_binaries[0]}" ]]; then
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
