#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p 'Codex Activity.app/Contents/MacOS'
cp Resources/Info.plist 'Codex Activity.app/Contents/Info.plist'
swiftc main.swift -o 'Codex Activity.app/Contents/MacOS/CodexActivity' -framework AppKit
'Codex Activity.app/Contents/MacOS/CodexActivity' --self-test
codesign --force --deep --sign - 'Codex Activity.app'
