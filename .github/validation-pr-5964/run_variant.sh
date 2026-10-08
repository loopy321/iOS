#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=$1
VARIANT=$2
TEST_SHA=$3
HA_VERSION=$4
ARTIFACT_ROOT=$5
ARTIFACT_DIR="$ARTIFACT_ROOT/$VARIANT"
mkdir -p "$ARTIFACT_DIR"

export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer
export TEST_VARIANT="$VARIANT"
if [[ "$VARIANT" == "after" ]]; then
  export EXPECTED_MORE_INFO=true
else
  export EXPECTED_MORE_INFO=false
fi

cd "$SOURCE_DIR"

cleanup() {
  if [[ -n "${VIDEO_PID:-}" ]]; then
    kill -INT "$VIDEO_PID" 2>/dev/null || true
    wait "$VIDEO_PID" 2>/dev/null || true
  fi
  if [[ -n "${LOG_PID:-}" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
  fi
  if [[ -n "${HASS_PID:-}" ]]; then
    kill "$HASS_PID" 2>/dev/null || true
    wait "$HASS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

{
  echo "runner_label=xcode-27"
  echo "variant=$VARIANT"
  echo "sha=$TEST_SHA"
  echo "home_assistant_version=$HA_VERSION"
  echo "architecture=$(uname -m)"
  xcodebuild -version
  sw_vers
  echo "runtimes:"
  xcrun simctl list runtimes
  echo "available_devices:"
  xcrun simctl list devices available
} > "$ARTIFACT_DIR/environment.txt" 2>&1

UDID=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
candidates = []
for runtime, devices in data.items():
    for device in devices:
        if device.get("isAvailable") and device.get("name") == "iPhone 17":
            version = tuple(int(part) for part in re.findall(r"\d+", runtime))
            candidates.append((version, runtime, device["udid"], device["name"]))
if not candidates:
    raise SystemExit("No available iPhone 17 simulator")
_, runtime, udid, name = max(candidates)
print(udid)
print(runtime, file=sys.stderr)
')

RUNTIME=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
udid = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if any(device.get("udid") == udid for device in devices):
        print(runtime)
        break
' "$UDID")
{
  echo "simulator_model=iPhone 17"
  echo "simulator_udid=$UDID"
  echo "simulator_runtime=$RUNTIME"
} >> "$ARTIFACT_DIR/environment.txt"

xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

xcodebuild -resolvePackageDependencies \
  -project HomeAssistant.xcodeproj \
  -scheme Tests-Unit \
  > "$ARTIFACT_DIR/package-resolution.log" 2>&1

UI_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/PR5964-$VARIANT"
UNIT_RESULT="$RUNNER_TEMP/Tests-Unit-$VARIANT.xcresult"
SECONDS=0
set +e
xcodebuild test \
  -project HomeAssistant.xcodeproj \
  -scheme Tests-Unit \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$UI_DERIVED" \
  -only-testing:Tests-App/WebViewControllerTests \
  -only-testing:Tests-App/WebViewExternalMessageHandlerTests \
  -collect-test-diagnostics never \
  -resultBundlePath "$UNIT_RESULT" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  2>&1 | tee "$ARTIFACT_DIR/tests-$VARIANT.log"
UNIT_STATUS=${PIPESTATUS[0]}
UNIT_DURATION=$SECONDS
set -e

if [[ -d "$UNIT_RESULT" ]]; then
  xcrun xcresulttool get test-results summary \
    --path "$UNIT_RESULT" --format json \
    > "$ARTIFACT_DIR/unit-summary.json" 2> "$ARTIFACT_DIR/unit-summary-error.log" || true
fi

python3 -m venv "$RUNNER_TEMP/ha-venv"
"$RUNNER_TEMP/ha-venv/bin/pip" install --upgrade pip wheel > "$ARTIFACT_DIR/ha-install.log" 2>&1
"$RUNNER_TEMP/ha-venv/bin/pip" install "homeassistant==$HA_VERSION" >> "$ARTIFACT_DIR/ha-install.log" 2>&1
cp -R .github/e2e/homeassistant "$RUNNER_TEMP/homeassistant"
"$RUNNER_TEMP/ha-venv/bin/hass" --config "$RUNNER_TEMP/homeassistant" \
  > "$ARTIFACT_DIR/home-assistant.log" 2>&1 &
HASS_PID=$!

for _ in $(seq 1 120); do
  if ! kill -0 "$HASS_PID" 2>/dev/null; then
    echo "Home Assistant exited before becoming reachable" >&2
    exit 1
  fi
  if curl -fsS -o /dev/null http://localhost:8123/manifest.json; then
    break
  fi
  sleep 5
done
curl -fsS -o /dev/null http://localhost:8123/manifest.json

python3 Tools/home_assistant_e2e_auth.py \
  --url http://localhost:8123 \
  --username citest \
  --password 'h7jk99&U' \
  --timeout 300 \
  --require-component mobile_app \
  --require-component websocket_api \
  > "$ARTIFACT_DIR/ha-verification.log" 2>&1

# Start onboarding from a pristine device, then build and explicitly install App-Debug.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

SECONDS=0
set +e
xcodebuild build-for-testing \
  -project HomeAssistant.xcodeproj \
  -scheme Tests-UI \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$UI_DERIVED" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  2>&1 | tee "$ARTIFACT_DIR/build-$VARIANT.log"
BUILD_STATUS=${PIPESTATUS[0]}
BUILD_DURATION=$SECONDS
set -e

xcodebuild -showBuildSettings -json \
  -project HomeAssistant.xcodeproj \
  -scheme Tests-UI \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$UI_DERIVED" \
  > "$ARTIFACT_DIR/build-settings.json"

APP_PATH=$(python3 - "$ARTIFACT_DIR/build-settings.json" <<'PY'
import json, pathlib, sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
app = next(item for item in settings if item.get("target") == "App")["buildSettings"]
print(pathlib.Path(app["TARGET_BUILD_DIR"]) / app["WRAPPER_NAME"])
PY
)
BUNDLE_ID=$(python3 - "$ARTIFACT_DIR/build-settings.json" <<'PY'
import json, pathlib, sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
app = next(item for item in settings if item.get("target") == "App")["buildSettings"]
print(app["PRODUCT_BUNDLE_IDENTIFIER"])
PY
)
{
  echo "app_path=$APP_PATH"
  echo "bundle_id=$BUNDLE_ID"
} >> "$ARTIFACT_DIR/environment.txt"

if [[ $BUILD_STATUS -ne 0 || ! -d "$APP_PATH" ]]; then
  echo "App-Debug build failed or app product is missing" >&2
  exit 1
fi
xcrun simctl install "$UDID" "$APP_PATH"

ONBOARDING_RESULT="$RUNNER_TEMP/onboarding-$VARIANT.xcresult"
set +e
TEST_RUNNER_E2E_HOME_ASSISTANT_URL=http://localhost:8123 \
TEST_RUNNER_E2E_HOME_ASSISTANT_USERNAME=citest \
TEST_RUNNER_E2E_HOME_ASSISTANT_PASSWORD='h7jk99&U' \
xcodebuild test-without-building \
  -project HomeAssistant.xcodeproj \
  -scheme Tests-UI \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$UI_DERIVED" \
  -only-testing:Tests-UI/OnboardingE2ETests/testOnboardingConnectsAndFrontendOpensNativeSettings \
  -collect-test-diagnostics never \
  -resultBundlePath "$ONBOARDING_RESULT" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  2>&1 | tee "$ARTIFACT_DIR/onboarding-$VARIANT.log"
ONBOARDING_STATUS=${PIPESTATUS[0]}
set -e

if [[ $ONBOARDING_STATUS -ne 0 ]]; then
  echo "Onboarding failed; notification behavior cannot be tested" >&2
  exit 1
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

FULL_LOG="$ARTIFACT_DIR/$VARIANT-full.log"
xcrun simctl spawn "$UDID" log stream \
  --level debug \
  --style compact \
  --predicate 'process == "Home Assistant"' \
  > "$FULL_LOG" 2>&1 &
LOG_PID=$!

VIDEO="$ARTIFACT_DIR/$VARIANT-5964.mov"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$VIDEO" \
  > "$ARTIFACT_DIR/video-recorder.log" 2>&1 &
VIDEO_PID=$!
sleep 2

xcrun simctl push "$UDID" "$BUNDLE_ID" .github/e2e/entity-cold-launch.apns \
  > "$ARTIFACT_DIR/simctl-push.log" 2>&1

BEHAVIOR_RESULT="$RUNNER_TEMP/notification-$VARIANT.xcresult"
SECONDS=0
set +e
TEST_RUNNER_EXPECTED_MORE_INFO="$EXPECTED_MORE_INFO" \
TEST_RUNNER_TEST_VARIANT="$VARIANT" \
xcodebuild test-without-building \
  -project HomeAssistant.xcodeproj \
  -scheme Tests-UI \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$UI_DERIVED" \
  -only-testing:Tests-UI/NotificationEntityColdLaunchE2ETests/testEntityNotificationColdLaunch \
  -collect-test-diagnostics never \
  -resultBundlePath "$BEHAVIOR_RESULT" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  2>&1 | tee "$ARTIFACT_DIR/behavior-$VARIANT.log"
BEHAVIOR_STATUS=${PIPESTATUS[0]}
BEHAVIOR_DURATION=$SECONDS
set -e

kill -INT "$VIDEO_PID" 2>/dev/null || true
wait "$VIDEO_PID" 2>/dev/null || true
unset VIDEO_PID
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
unset LOG_PID

python3 - "$FULL_LOG" "$ARTIFACT_DIR/$VARIANT.log" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
pattern = re.compile(
    r"NotificationManager|IncomingURLHandler|entity[_ -]?id|more-info|navigate|external.?bus|"
    r"frontend/loaded|retry|acknowledg|fallback",
    re.IGNORECASE,
)
lines = source.read_text(errors="replace").splitlines()
target.write_text("\n".join(line for line in lines if pattern.search(line)) + "\n")
PY

python3 - \
  "$ARTIFACT_DIR/tests-$VARIANT.log" \
  "$ARTIFACT_DIR/behavior-$VARIANT.log" \
  "$ARTIFACT_DIR/unit-summary.json" \
  "$ARTIFACT_DIR/status.json" <<PY
import json, pathlib, re, sys
tests_log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
behavior_log = pathlib.Path(sys.argv[2]).read_text(errors="replace")
summary_path = pathlib.Path(sys.argv[3])
summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
match = re.search(r"PR5964_OBSERVED_MORE_INFO=(true|false)", behavior_log)
status = {
    "variant": "$VARIANT",
    "sha": "$TEST_SHA",
    "unit_exit_status": $UNIT_STATUS,
    "unit_duration_seconds": $UNIT_DURATION,
    "unit_total": summary.get("totalTestCount"),
    "unit_passed": summary.get("passedTests"),
    "unit_failed": summary.get("failedTests"),
    "unit_skipped": summary.get("skippedTests"),
    "build_exit_status": $BUILD_STATUS,
    "build_duration_seconds": $BUILD_DURATION,
    "onboarding_exit_status": $ONBOARDING_STATUS,
    "behavior_exit_status": $BEHAVIOR_STATUS,
    "behavior_duration_seconds": $BEHAVIOR_DURATION,
    "observed_more_info": None if match is None else match.group(1) == "true",
    "expected_more_info": "$EXPECTED_MORE_INFO" == "true",
    "simulator_runtime": "$RUNTIME",
    "simulator_model": "iPhone 17",
    "bundle_id": "$BUNDLE_ID",
    "home_assistant_version": "$HA_VERSION",
}
pathlib.Path(sys.argv[4]).write_text(json.dumps(status, indent=2) + "\n")
PY

exit 0
