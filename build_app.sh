#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
project="$PWD"
build="$project/.build"
dist="$project/dist"
cli=${ARDUINO_CLI:-arduino-cli}
config=()
if [[ -n "${ARDUINO_CLI_CONFIG:-}" ]]; then
    config=(--config-file "$ARDUINO_CLI_CONFIG")
fi

core_version=3.3.7
esptool_version=5.1.0
data=$("$cli" "${config[@]}" config dump --format json | python3 -c '
import json, sys
print(json.load(sys.stdin)["config"]["directories"]["data"])
')
core="$data/packages/esp32/hardware/esp32/$core_version"
flash="$data/packages/esp32/tools/esptool_py/$esptool_version"
firmware="$build/firmware"
app="$dist/ON AIR.app"
contents="$app/Contents"
if [[ ! -d "$core" || ! -x "$flash/esptool" ]]; then
    printf '%s\n' "Install Arduino ESP32 core $core_version before building." >&2
    exit 1
fi
mkdir -p "$firmware" "$contents"/{MacOS,Helpers,Resources/Firmware}

# GCC uses source paths in assertion messages, even in a release image.
# Map project, board package and build paths before creating public binaries.
prefix_flags="\"-ffile-prefix-map=$project=onair\" \"-ffile-prefix-map=$data=arduino-data\""
"$cli" "${config[@]}" compile --clean --fqbn esp32:esp32:XIAO_ESP32C3 \
    --build-path "$firmware" --output-dir "$firmware" \
    --build-property "compiler.c.extra_flags=$prefix_flags" \
    --build-property "compiler.cpp.extra_flags=$prefix_flags" \
    Firmware/SteppedStudioSign

cp Mac/Info.plist "$contents/Info.plist"
cp "$flash/esptool" "$contents/Helpers/esptool"
cp Notices/*.txt "$contents/Resources/"
cp "$firmware/SteppedStudioSign.ino.bootloader.bin" "$contents/Resources/Firmware/bootloader.bin"
cp "$firmware/SteppedStudioSign.ino.partitions.bin" "$contents/Resources/Firmware/partitions.bin"
cp "$core/tools/partitions/boot_app0.bin" "$contents/Resources/Firmware/boot_app0.bin"
cp "$firmware/SteppedStudioSign.ino.bin" "$contents/Resources/Firmware/app.bin"
swiftc -O -target arm64-apple-macosx14.2 -file-prefix-map "$project=onair" \
    Mac/*.swift -o "$contents/MacOS/ONAir"
codesign --force --sign - "$contents/Helpers/esptool"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
