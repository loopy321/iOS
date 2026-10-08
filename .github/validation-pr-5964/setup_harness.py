#!/usr/bin/env python3
import json
import pathlib
import shutil
import sys


root = pathlib.Path(sys.argv[1]).resolve()
harness = pathlib.Path(__file__).resolve().parent

test_name = "NotificationEntityColdLaunchE2ETests.swift"
shutil.copy2(harness / test_name, root / "Tests/UI" / test_name)
shutil.copy2(harness / "entity-cold-launch.apns", root / ".github/e2e/entity-cold-launch.apns")

project_path = root / "HomeAssistant.xcodeproj/project.pbxproj"
project = project_path.read_text()

replacements = {
    "\t\t42E2E0000000000000000005 /* OnboardingE2ETests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 42E2E0000000000000000002 /* OnboardingE2ETests.swift */; };":
        "\t\t42E2E0000000000000000005 /* OnboardingE2ETests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 42E2E0000000000000000002 /* OnboardingE2ETests.swift */; };\n"
        "\t\t965964000000000000000005 /* NotificationEntityColdLaunchE2ETests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 965964000000000000000002 /* NotificationEntityColdLaunchE2ETests.swift */; };",
    "\t\t42E2E0000000000000000002 /* OnboardingE2ETests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OnboardingE2ETests.swift; sourceTree = \"<group>\"; };":
        "\t\t42E2E0000000000000000002 /* OnboardingE2ETests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OnboardingE2ETests.swift; sourceTree = \"<group>\"; };\n"
        "\t\t965964000000000000000002 /* NotificationEntityColdLaunchE2ETests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NotificationEntityColdLaunchE2ETests.swift; sourceTree = \"<group>\"; };",
    "\t\t\t\t42E2E0000000000000000002 /* OnboardingE2ETests.swift */,":
        "\t\t\t\t42E2E0000000000000000002 /* OnboardingE2ETests.swift */,\n"
        "\t\t\t\t965964000000000000000002 /* NotificationEntityColdLaunchE2ETests.swift */,",
    "\t\t\t\t42E2E0000000000000000005 /* OnboardingE2ETests.swift in Sources */,":
        "\t\t\t\t42E2E0000000000000000005 /* OnboardingE2ETests.swift in Sources */,\n"
        "\t\t\t\t965964000000000000000005 /* NotificationEntityColdLaunchE2ETests.swift in Sources */,",
}

for old, new in replacements.items():
    count = project.count(old)
    if count != 1:
        raise SystemExit(f"Expected one project marker, found {count}: {old}")
    project = project.replace(old, new)

project_path.write_text(project)

# The workflow records only the short behavior phase with simctl. Disable the test plan's
# automatic full-test recording so two simultaneous simulator recorders do not contend.
plan_path = root / "Tests/UI/Tests-UI.xctestplan"
plan = json.loads(plan_path.read_text())
plan["defaultOptions"].pop("preferredScreenCaptureFormat", None)
plan["defaultOptions"].pop("uiTestingScreenshotsLifetime", None)
plan_path.write_text(json.dumps(plan, indent=2) + "\n")
