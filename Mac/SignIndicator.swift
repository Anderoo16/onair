import AppKit

enum SignStatus: Equatable {
    case unpaired
    case connecting
    case settingUp(String)
    case connected(Int)
    case offline(String)
    case needsPairing(String)

    var connectionTitle: String {
        switch self {
        case .unpaired: "Sign: Not set up"
        case .connecting: "Sign: Connecting…"
        case .settingUp(let message): message
        case .connected: "Sign: Connected"
        case .offline: "Sign: Offline"
        case .needsPairing: "Sign: Pairing needed"
        }
    }

    var lightTitle: String {
        switch self {
        case .connected(let level) where level > 0: "Light: On at \(level)%"
        case .connected: "Light: Off"
        default: "Light: Unconfirmed"
        }
    }

    var detail: String {
        switch self {
        case .unpaired: "Choose Set Up Sign to pair by USB."
        case .connecting: "Waiting for the sign to reply over Wi-Fi."
        case .settingUp: "Keep the XIAO connected over USB."
        case .connected: "The sign confirmed the light command over Wi-Fi."
        case .offline(let detail), .needsPairing(let detail): detail
        }
    }

    var isLive: Bool {
        if case .connected(let level) = self { return level > 0 }
        return false
    }
}

/// A stable-width dot next to the menu bar label.
final class SignIndicator {
    private weak var button: NSStatusBarButton?
    private var pulse: Timer?
    private var frame = 0
    private let disconnected = SignIndicator.dot(color: .secondaryLabelColor, outline: true)
    private let connected = SignIndicator.dot(color: NSColor(srgbRed: 0.20, green: 0.71, blue: 0.36, alpha: 1))
    private let red = SignIndicator.dot(color: liveRed)
    private let liveFrames = (0..<18).map { index in
        let phase = Double(index) / 18
        let wave = (1 - cos(phase * 2 * .pi)) / 2
        return dot(color: liveRed, halo: 0.32 * wave, radius: 4.4 + 2.6 * wave)
    }

    private static let liveRed = NSColor(srgbRed: 0.96, green: 0.23, blue: 0.26, alpha: 1)

    init(_ button: NSStatusBarButton) {
        self.button = button
        button.title = "ON AIR"
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
    }

    deinit { pulse?.invalidate() }

    func show(_ state: SignStatus) {
        guard let button else { return }
        button.setAccessibilityLabel("ON AIR. \(state.connectionTitle). \(state.lightTitle).")
        button.toolTip = "\(state.connectionTitle) · \(state.lightTitle)\n\(state.detail)"

        if state.isLive {
            if pulse == nil {
                frame = 0
                tick()
                let timer = Timer(timeInterval: 0.085, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer, forMode: .common)
                pulse = timer
            }
        } else {
            pulse?.invalidate()
            pulse = nil
            if case .connected = state {
                button.image = connected
            } else {
                button.image = disconnected
            }
        }
    }

    private func tick() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button?.image = red
        } else {
            button?.image = liveFrames[frame]
            frame = (frame + 1) % liveFrames.count
        }
    }

    private static func dot(color: NSColor, outline: Bool = false,
                            halo: Double = 0, radius: Double = 4) -> NSImage {
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            if halo > 0 {
                color.withAlphaComponent(halo).setFill()
                NSBezierPath(ovalIn: NSRect(x: 8 - radius, y: 8 - radius,
                                           width: radius * 2, height: radius * 2)).fill()
            }
            let core = NSBezierPath(ovalIn: NSRect(x: 4.5, y: 4.5, width: 7, height: 7))
            if outline {
                color.setStroke()
                core.lineWidth = 1.3
                core.stroke()
            } else {
                color.setFill()
                core.fill()
            }
            return true
        }
        icon.isTemplate = false
        return icon
    }
}
