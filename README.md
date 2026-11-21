# ON AIR for macOS

ON AIR is a menu bar companion for a Wi-Fi sign built around a Seeed Studio
XIAO ESP32-C3. The light follows the Mac's microphone or camera activity.
The menu shows the live connection and light level. A red dot pulses when
the sign confirms the light is on.

[Download the macOS app](https://github.com/Anderoo16/onair/releases/latest)

## What you need

- Apple silicon Mac running macOS 14.2 or later.
- A XIAO ESP32-C3 and an LED driver connected to D2 / GPIO4.
- A USB-C data cable and a local Wi-Fi network with 2.4 GHz enabled.
- One Mac per sign with the current firmware.

## Set up a sign

1. Disconnect wall power and the LED plugs. Plug the Mac directly into the
   XIAO's USB-C socket.
2. Unzip the app, open it, and choose **ON AIR → Set Up Sign…**.
3. Enter the Wi-Fi name and password, then choose **Install & Pair**.
   First-time setup replaces the program on the selected XIAO.
4. Unplug the Mac cable, reconnect the LED plugs, and restore sign power.
   Allow Local Network access if macOS asks.
5. Choose **Test Light for 10 Seconds**, then try a camera preview or mic-only call.

The release is ad hoc signed. A downloaded copy may require approval in
macOS Privacy & Security because it is not notarized. See
[Apple's guidance on opening downloaded apps](https://support.apple.com/en-us/102445).

## How it works

The app reads device activity using macOS Core Audio and camera APIs. It
doesn't record audio or video. It sends the light level to the paired sign
on the local network. The sign turns off if commands stop arriving.
The Wi-Fi password travels over USB during setup and is saved on the XIAO.
Each installation generates its own pairing key, which the Mac stores locally.

## Build from source

[Build instructions and dependency sources](BUILDING.md)
