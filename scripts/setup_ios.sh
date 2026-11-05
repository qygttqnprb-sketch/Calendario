#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir/ios"
if ! command -v xcodegen >/dev/null; then
  echo 'Installa XcodeGen: brew install xcodegen' >&2
  exit 1
fi
if [ ! -f Config.xcconfig ]; then cp Config.public.xcconfig Config.xcconfig; fi
xcodegen generate
printf '%s\n' 'Apri ios/Coppia.xcodeproj in Xcode e scegli lo scheme Coppia.'
