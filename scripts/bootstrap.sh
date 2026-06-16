#!/bin/zsh
# Generate the Xcode project and open it.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo
echo "Project generated. Opening Xcode…"
echo "Reminder: set DEVELOPMENT_TEAM in project.yml (or in Xcode signing settings)"
echo "so the app and the Safari extension can share the app group."
open AIContentFilter.xcodeproj
