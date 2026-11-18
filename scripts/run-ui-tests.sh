#!/usr/bin/env bash
# Runs the UI tests on an iOS simulator, setting the simulated location each test class needs.
#
# Usage: scripts/run-ui-tests.sh [simulator-udid]
# Without a UDID, the first available iPhone simulator is used.
# The app is uninstalled and its location permission reset before each test class, so every run starts like a first launch.
set -euo pipefail

cd "$(dirname "$0")/.."

SIM="${1:-$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}')}"
DERIVED="${DERIVED_DATA:-build/DerivedData}"
BUNDLE_ID=com.performiq.LocationDemo

echo "Simulator: $SIM"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null

xcodebuild build-for-testing -quiet \
  -project LocationDemo.xcodeproj -scheme LocationDemo \
  -destination "id=$SIM" -derivedDataPath "$DERIVED"

run_tests() {
  xcrun simctl uninstall "$SIM" "$BUNDLE_ID" 2>/dev/null || true
  # Uninstalling does not clear location permission for the bundle id, so reset it explicitly.
  xcrun simctl privacy "$SIM" reset location "$BUNDLE_ID" 2>/dev/null || true
  xcodebuild test-without-building \
    -project LocationDemo.xcodeproj -scheme LocationDemo \
    -destination "id=$SIM" -derivedDataPath "$DERIVED" \
    "$@"
}

status=0

# A ~50 km route west from Sydney at 15 m/s, long enough to keep moving for every moving test.
# Waypoints go on stdin because simctl reads a leading '-' (negative latitude) as an option.
xcrun simctl location "$SIM" start --speed=15 - <<'EOF'
-33.8688,151.2093
-33.8150,151.0011
-33.7700,150.9000
-33.7500,150.7000
EOF
run_tests -only-testing:LocationDemoUITests/MovingTrackerUITests || status=1

xcrun simctl location "$SIM" set -33.8688,151.2093
run_tests -only-testing:LocationDemoUITests/StationaryTrackerUITests || status=1

xcrun simctl location "$SIM" clear
exit $status
