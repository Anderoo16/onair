import Darwin
import Foundation

struct USBSetup {
    struct Result {
        let pairing: Pairing
        let joinedWiFi: Bool
    }

    static func ports() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    static func validateWiFi(ssid: String, password: String) throws {
        guard (1...32).contains(ssid.utf8.count), !ssid.utf8.contains(0) else {
            throw SignFailure("Enter a Wi-Fi network name between 1 and 32 bytes.")
        }
        guard password.isEmpty || ((8...63).contains(password.utf8.count) && !password.utf8.contains(0)) else {
            throw SignFailure("Use the 8–63 character Wi-Fi password, or leave it blank for an open network.")
        }
    }

    static func installAndPair(port: String, ssid: String, password: String,
                               progress: (String) -> Void) throws -> Result {
        try validateWiFi(ssid: ssid, password: password)
        guard ports().contains(port) else { throw SignFailure("The selected USB port disappeared. Reconnect the XIAO and try again.") }
        let key = try Pairing.makeKey()
        var serial = try? USBSerial(port)
        if serial?.ready(timeout: 1.8) == nil {
            serial = nil
            progress("Installing firmware over USB…")
            try flash(port: port)
            progress("Waiting for the sign to restart…")
            for _ in 0..<12 {
                let candidates = ports()
                if let nextPort = candidates.contains(port) ? port : (candidates.count == 1 ? candidates.first : nil),
                   let next = try? USBSerial(nextPort), next.ready(timeout: 0.8) != nil {
                    serial = next
                    break
                }
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        guard let serial else {
            throw SignFailure("The sign did not answer over USB. Unplug and reconnect the XIAO with BOOT released, then retry.")
        }

        progress("Saving Wi-Fi and pairing over USB…")
        let hex: (String) -> String = { $0.utf8.map { String(format: "%02x", $0) }.joined() }
        try serial.write("ON-AIR-SET \(hex(ssid)) \(hex(password)) \(key)\n")
        guard let reply = serial.readLine(timeout: 4, matching: {
            $0.hasPrefix("ON-AIR-SAVED ") || $0.hasPrefix("ON-AIR-ERROR ")
        }) else {
            throw SignFailure("The sign did not confirm setup. Try again with the XIAO plugged in.")
        }
        if reply.hasPrefix("ON-AIR-ERROR ") { throw SignFailure(String(reply.dropFirst(13))) }
        let host = String(reply.dropFirst(13))
        guard Pairing.validHost(host) else { throw SignFailure("The sign returned an invalid address.") }
        let pairing = Pairing(host: host, key: key)
        try pairing.save()

        progress("Waiting for the sign to join Wi-Fi…")
        for _ in 0..<12 {
            if let response = serial.ready(timeout: 0.9), response.last != "-" {
                return Result(pairing: pairing, joinedWiFi: true)
            }
            Thread.sleep(forTimeInterval: 0.75)
        }
        return Result(pairing: pairing, joinedWiFi: false)
    }

    private static func flash(port: String) throws {
        guard let files = Bundle.main.resourceURL?.appending(path: "Firmware") else {
            throw SignFailure("The app is missing its firmware folder. Open the complete app bundle.")
        }
        let command = Process()
        command.executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/esptool")
        command.currentDirectoryURL = files
        command.arguments = [
            "--chip", "esp32c3", "--port", port, "--baud", "460800", "--before", "default-reset",
            "--after", "hard-reset", "write-flash", "-z", "--flash-mode", "keep",
            "--flash-freq", "keep", "--flash-size", "keep", "0x0", "bootloader.bin",
            "0x8000", "partitions.bin", "0xe000", "boot_app0.bin", "0x10000", "app.bin"
        ]
        let log = Pipe()
        command.standardOutput = log
        command.standardError = log
        try command.run()
        let output = log.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            let tail = String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
            throw SignFailure("""
                Upload failed. Unplug the XIAO, hold BOOT while plugging it back into the Mac, release BOOT, and retry Set Up Sign.

                \(tail)
                """)
        }
    }
}

private final class USBSerial {
    let fd: Int32
    var incoming = Data()

    init(_ port: String) throws {
        let handle = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw SignFailure("Could not open the USB port. Close any Serial Monitor windows.") }
        var settings = termios()
        guard tcgetattr(handle, &settings) == 0 else {
            close(handle)
            throw SignFailure("Could not read USB serial settings.")
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&settings, speed_t(B115200))
        guard tcsetattr(handle, TCSANOW, &settings) == 0 else {
            close(handle)
            throw SignFailure("Could not set USB serial speed.")
        }
        fd = handle
        tcflush(fd, TCIFLUSH)
    }

    deinit { close(fd) }

    func write(_ message: String) throws {
        let payload = Array(message.utf8)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var offset = 0
        while offset < payload.count, ProcessInfo.processInfo.systemUptime < deadline {
            let count = payload.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno != EAGAIN && errno != EINTR { break }
            else { Thread.sleep(forTimeInterval: 0.025) }
        }
        guard offset == payload.count else { throw SignFailure("Could not send setup over USB.") }
    }

    func ready(timeout: TimeInterval) -> [Substring]? {
        try? write("ON-AIR-PING\n")
        guard let line = readLine(timeout: timeout, matching: { $0.hasPrefix("ON-AIR-READY ") }) else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count == 3, Pairing.validHost(String(fields[1])) else { return nil }
        return fields
    }

    func readLine(timeout: TimeInterval, matching: (String) -> Bool) -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 512)
        while ProcessInfo.processInfo.systemUptime < deadline {
            while let newline = incoming.firstIndex(of: 10) {
                let text = String(decoding: incoming[..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                incoming.removeSubrange(...newline)
                if matching(text) { return text }
            }
            if incoming.count > 2048 { incoming.removeAll() }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { incoming.append(contentsOf: buffer.prefix(count)) }
            else if count < 0 && errno != EAGAIN && errno != EINTR { break }
            else { Thread.sleep(forTimeInterval: 0.025) }
        }
        return nil
    }
}
