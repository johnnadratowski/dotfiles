#!/bin/bash
set -xe
echo "Building Gcal"
nativefier -m -n Gcal -i ./gcal.icns --inject ./custom.css --internal-urls "calendar.google.com.*" --internal-urls "apis.google.*" --internal-urls "cal.google.*" "calendar.google.com" --counter ../build
echo "Installing Gcal"
[[ -x /Applications/Gcal.app ]] && rm -rf /Applications/Gcal.app
mv ../build/Gcal-darwin-x64/Gcal.app /Applications
