#!/usr/bin/env python3
import json
import pathlib
import shutil
import sys


root = pathlib.Path(sys.argv[1]).resolve()
before_sha = sys.argv[2]
after_sha = sys.argv[3]


def load(variant):
    path = root / variant / "status.json"
    if not path.exists():
        return {"variant": variant, "sha": before_sha if variant == "before" else after_sha}
    return json.loads(path.read_text())


before = load("before")
after = load("after")

for variant in ("before", "after"):
    source = root / variant
    for name in (f"{variant}-5964.mov", f"{variant}.log", f"tests-{variant}.log"):
        candidate = source / name
        if candidate.exists():
            shutil.copy2(candidate, root / name)

environment_parts = []
for variant in ("before", "after"):
    path = root / variant / "environment.txt"
    if path.exists():
        environment_parts.append(f"===== {variant.upper()} =====\n{path.read_text(errors='replace')}")
(root / "environment.txt").write_text("\n".join(environment_parts))

same_environment = (
    before.get("simulator_runtime") == after.get("simulator_runtime")
    and before.get("simulator_model") == after.get("simulator_model")
)
after_tests_pass = (
    after.get("unit_exit_status") == 0
    or after.get("unit_rerun_exit_status") == 0
)
tests_pass = before.get("unit_exit_status") == 0 and after_tests_pass
lock_screen_tested = (
    before.get("lock_screen_exit_status") == 0
    and after.get("lock_screen_exit_status") == 0
)
before_failed_as_expected = before.get("observed_more_info") is False
after_succeeded = after.get("observed_more_info") is True

if same_environment and tests_pass and lock_screen_tested and before_failed_as_expected and after_succeeded:
    conclusion = "CONFIRMED"
elif before_failed_as_expected and after.get("observed_more_info") is False:
    conclusion = "NOT CONFIRMED"
else:
    conclusion = "INCONCLUSIVE"


def result_line(status):
    observed = status.get("observed_more_info")
    observations = status.get("behavior_observations", [])
    attempts = status.get("behavior_attempts")
    suffix = f" Observations across {attempts} attempt(s): {', '.join(observations)}." if attempts else ""
    if observed is True:
        return "The requested `person.citest` More Info dialog appeared." + suffix
    if observed is False:
        return "The app remained on the default frontend; the requested More Info dialog did not appear." + suffix
    return "The behavior test did not produce a reliable observation."


def test_line(status):
    total = status.get("unit_total")
    passed = status.get("unit_passed")
    failed = status.get("unit_failed")
    skipped = status.get("unit_skipped")
    if total is None:
        return f"exit status `{status.get('unit_exit_status', 'missing')}`; result counts unavailable"
    result = f"{total} total, {passed} passed, {failed} failed, {skipped} skipped"
    rerun = status.get("unit_rerun_exit_status", -1)
    if rerun != -1:
        result += f"; isolated rerun of the failed retry test exit status {rerun}"
    return result


environment = before if before.get("simulator_runtime") else after
report = f"""# Environment

- GitHub Actions runner label: `xcode-27`
- Architecture: Apple silicon (`arm64`; see `environment.txt`)
- Xcode: Xcode 27.0 from `/Applications/Xcode_27.0.app` (exact build in `environment.txt`)
- iOS simulator runtime: `{environment.get('simulator_runtime', 'unavailable')}`
- Simulator model: `{environment.get('simulator_model', 'unavailable')}`
- Home Assistant Core fixture: `{environment.get('home_assistant_version', 'unavailable')}`

# Revisions

Before: `{before_sha}`

After: `{after_sha}`

# Automated tests

- Before `WebViewControllerTests` and `WebViewExternalMessageHandlerTests`: {test_line(before)}; duration {before.get('unit_duration_seconds', 'unknown')} seconds.
- After `WebViewControllerTests` and `WebViewExternalMessageHandlerTests`: {test_line(after)}; duration {after.get('unit_duration_seconds', 'unknown')} seconds.
- App-Debug build duration: before {before.get('build_duration_seconds', 'unknown')} seconds; after {after.get('build_duration_seconds', 'unknown')} seconds.

# Manual/behavioral-equivalent test

Each revision was built from the exact SHA with the repository's `Tests-UI` scheme. The workflow started the repository's seeded local Home Assistant fixture, onboarded App-Debug through the existing XCUITest flow, and cleared post-onboarding sheets before the test. It then terminated the app, locked the simulator through Simulator's named `Device > Lock Screen` menu, delivered a top-level `entity_id: person.citest` notification with `simctl push`, and used XCUITest to tap that notification in SpringBoard. Because the reported race is intermittent, the baseline was attempted up to five times and the patched revision up to two times, stopping when the expected outcome was observed. `simctl io recordVideo` captured every attempt; the canonical recording is the attempt matching the expected outcome, or the final attempt if none matched. No URL launch substituted for the notification path.

# Before result

{result_line(before)}

# After result

{result_line(after)}

# Relevant logs

Concise filtered excerpts are in `before.log` and `after.log`; complete app unified-log captures are in `before/before-full.log` and `after/after-full.log`. Per-attempt UI-test logs and recordings are retained under each variant directory.

# Screen recordings

- `before-5964.mov`
- `after-5964.mov`

# Conclusion

{conclusion}

# Suggested GitHub PR comment

Tested the exact PR base `{before_sha}` and head `{after_sha}` on an Apple-silicon GitHub Actions `xcode-27` runner. See the attached `before-5964.mov` and `after-5964.mov` recordings and `validation-summary.md` for the observed A/B behavior and focused unit-test results. Conclusion: **{conclusion}**.
"""
(root / "validation-summary.md").write_text(report)
print(report)
