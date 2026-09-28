#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p work outputs/BlackHoleDesk.app/Contents/MacOS
cp BuildSupport/Info.plist outputs/BlackHoleDesk.app/Contents/Info.plist

# The installed CLT may contain two definitions of SwiftBridging. Hide only
# the legacy copy through a compiler-local overlay; never modify the SDK.
/usr/bin/ruby -rjson -e '
root = Dir.pwd
overlay = {version: 0, roots: [{type: "file", name: "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "external-contents" => root + "/BuildSupport/empty.modulemap"}]}
File.write("work/toolchain-overlay.json", JSON.generate(overlay))
'
flags=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ]]; then
    flags=(-vfsoverlay work/toolchain-overlay.json -Xcc -ivfsoverlay -Xcc work/toolchain-overlay.json)
fi
swiftc -O -target arm64-apple-macosx14.0 "${flags[@]}" -parse-as-library Sources/BlackHoleDesk/*.swift -o work/BlackHoleDesk
cp work/BlackHoleDesk outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk
codesign --force --sign - outputs/BlackHoleDesk.app
echo "Built outputs/BlackHoleDesk.app"
if [[ "${1:-}" == "--run" ]]; then
    open outputs/BlackHoleDesk.app
fi
