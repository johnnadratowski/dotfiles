#!/bin/bash
set -xe
echo "Building Devdocs"
nativefier -m -n DevDocs -i ./devdocs.icns --inject ./custom.js http://devdocs.io ../build
echo "Installing Devdocs"
[[ -x /Applications/DevDocs.app ]] && rm -rf /Applications/DevDocs.app
mv ../build/DevDocs-darwin-x64/DevDocs.app /Applications
