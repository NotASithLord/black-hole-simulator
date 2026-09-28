#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p work outputs
/usr/bin/ruby -rjson -e '
root = Dir.pwd
overlay = {version: 0, roots: [{type: "file", name: "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "external-contents" => root + "/BuildSupport/empty.modulemap"}]}
File.write("work/toolchain-overlay.json", JSON.generate(overlay))
'
flags=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ]]; then
    flags=(-vfsoverlay work/toolchain-overlay.json -Xcc -ivfsoverlay -Xcc work/toolchain-overlay.json)
fi
swiftc -O -target arm64-apple-macosx14.0 "${flags[@]}" Sources/BlackHoleDesk/DiskFlow.swift Tests/FlowValidation.swift -o work/FlowValidation
work/FlowValidation outputs/flow-validation.json
swiftc -O -target arm64-apple-macosx14.0 "${flags[@]}" Sources/BlackHoleDesk/DiskFlow.swift Tests/FlowCalibrationValidation.swift -o work/FlowCalibrationValidation
work/FlowCalibrationValidation outputs/flow-calibration-validation.json
