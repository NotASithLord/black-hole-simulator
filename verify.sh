#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
flags=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ]]; then
    flags=(-vfsoverlay work/toolchain-overlay.json -Xcc -ivfsoverlay -Xcc work/toolchain-overlay.json)
fi
swiftc -O "${flags[@]}" Sources/BlackHolePhysics/*.swift Sources/BlackHoleDesk/DiskPhysics.swift Tests/DiskPhysicsValidation.swift -o work/disk_validation
work/disk_validation | tee outputs/disk-validation.txt
swiftc -O "${flags[@]}" Sources/BlackHoleDesk/RenderSettings.swift Sources/BlackHoleDesk/AdaptiveQuality.swift Tests/QualityValidation.swift -o work/quality_validation
work/quality_validation | tee outputs/quality-validation.txt
swiftc -O "${flags[@]}" Sources/BlackHolePhysics/*.swift Sources/BlackHoleDesk/DiskPhysics.swift Sources/BlackHoleDesk/DiskMotion.swift Tests/DiskMotionValidation.swift -o work/disk_motion_validation
work/disk_motion_validation | tee outputs/disk-motion-validation.txt
outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --validate-gpu Tests/physics_cases.json outputs/gpu-validation.json
outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --validate-gpu Tests/physics_cases_max.json outputs/gpu-validation-max.json
python3 Tests/validate_physics.py --gpu outputs/gpu-validation.json --gpu-max outputs/gpu-validation-max.json
outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --benchmark outputs/gpu-benchmark.json
outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --appearance-test outputs
bash verify-flow.sh
outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --thickness-test outputs
python3 Tests/validate_thickness.py
outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --rotation-test outputs
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -loglevel error -y -framerate 30 -i work/rotation-frames/frame-%04d.png -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart outputs/rotation-preview.mp4
else
    echo "Numerical checks complete; install FFmpeg only if you want to encode the preview PNGs as MP4."
fi
