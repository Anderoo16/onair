# Build from source

Use an Apple silicon Mac with Xcode Command Line Tools, Python 3, and the
[Arduino CLI](https://arduino.github.io/arduino-cli/latest/installation/).
Install the pinned ESP32 core and run the build script.

```sh
arduino-cli core update-index --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core install esp32:esp32@3.3.7 --additional-urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
./build_app.sh
```

Open `dist/ON AIR.app`. If Arduino CLI is installed in a custom location,
set `ARDUINO_CLI` to its executable. Set `ARDUINO_CLI_CONFIG` to use a
custom Arduino CLI configuration file.

The Swift app is in `Mac/`. The sketch is in `Firmware/SteppedStudioSign/`.
To upload the sketch separately with Arduino IDE, select **XIAO_ESP32C3**
and enable **USB CDC On Boot**. Then use **Set Up Sign** in the Mac app to
provision the existing firmware.

## Bundled components

- [esptool 5.1.0 source](https://github.com/espressif/esptool/tree/v5.1.0)
  · [upstream binaries](https://github.com/espressif/esptool/releases/tag/v5.1.0).
  The app invokes this separate program for USB installation.
- [Arduino ESP32 core 3.3.7 source and board packages](https://github.com/espressif/arduino-esp32/releases/tag/3.3.7),
  with the [ESP32-C3 libraries](https://github.com/espressif/arduino-esp32/releases/download/3.3.7/esp32c3-libs-3.3.7.zip).
  Run the build above to recompile or relink the included firmware with an
  installed core. The compiler options only remap absolute source paths.

Copies of the relevant upstream licenses are in [Notices](Notices/).
