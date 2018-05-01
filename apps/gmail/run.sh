#!/bin/bash
set -xe
echo "Building Gmail"
nativefier -m -n Gmail -i ./gmail.icns --inject ./custom.css --internal-urls "mail.google.com.*" --internal-urls "apis.google.*" "mail.google.com" --counter ../build
# nativefier --name "Gmail" --internal-urls "mail.google.com.*" "mail.google.com" --counter ../build
echo "Installing Gmail"
[[ -x /Applications/Gmail.app ]] && rm -rf /Applications/Gmail.app
mv ../build/Gmail-darwin-x64/Gmail.app /Applications
