import ApplicationServices
import Carbon
import Cocoa

/// Types text into the focused app one character at a time with human-like timing.
/// Requires Accessibility permission (System Settings → Privacy & Security → Accessibility).
final class Typer {

    enum Speed: String, CaseIterable {
        case fast, normal, slow

        var title: String {
            switch self {
            case .fast:   return "Fast"
            case .normal: return "Normal (human)"
            case .slow:   return "Slow"
            }
        }

        /// Average delay between keystrokes, in seconds.
        var baseDelay: Double {
            switch self {
            case .fast:   return 0.012
            case .normal: return 0.045
            case .slow:   return 0.11
            }
        }
    }

    /// Main-thread only.
    private(set) var isTyping = false

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    private let queue = DispatchQueue(label: "local.groqhotkey.typer", qos: .userInitiated)

    /// Returns true if the app may post keystrokes. With `prompt: true` macOS shows its permission dialog.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    /// Types `text`; `completion(true)` if it finished, `false` if stopped (Esc or `cancel()`). Called on main.
    func type(_ text: String, speed: Speed, completion: @escaping (Bool) -> Void) {
        guard !isTyping else { return }
        isTyping = true
        lock.lock(); _cancelled = false; lock.unlock()

        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))

        queue.async { [self] in
            Typer.waitForModifiersReleased()

            var finished = true
            for ch in characters {
                if cancelled || escapePressed() {
                    finished = false
                    break
                }
                post(ch)
                Thread.sleep(forTimeInterval: delay(after: ch, speed: speed))
            }

            DispatchQueue.main.async {
                self.isTyping = false
                completion(finished)
            }
        }
    }

    /// Presses ⌘C in the focused app.
    static func pressCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    /// The user is still holding the hotkey's modifiers; typing now would turn letters into shortcuts.
    static func waitForModifiersReleased() {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let deadline = Date().addingTimeInterval(5)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    // MARK: - Private

    private func escapePressed() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
    }

    private func post(_ ch: Character) {
        switch ch {
        case "\n": pressKey(CGKeyCode(kVK_Return))
        case "\t": pressKey(CGKeyCode(kVK_Tab))
        default:   typeUnicode(String(ch))
        }
    }

    private func pressKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    /// Posts the character as Unicode, so it works with any keyboard layout and any symbol/emoji.
    private func typeUnicode(_ s: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(s.utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Randomised delay that mimics a person: uneven rhythm, pauses after words, punctuation and lines.
    private func delay(after ch: Character, speed: Speed) -> Double {
        let base = speed.baseDelay
        var d = base * Double.random(in: 0.5...1.6)

        switch ch {
        case " ":                d += base * Double.random(in: 0.2...1.0)
        case ".", "!", "?":      d += base * Double.random(in: 3...7)
        case ",", ";", ":":      d += base * Double.random(in: 1.5...3.5)
        case "\n":               d += base * Double.random(in: 4...9)
        default:                 break
        }

        // Occasional "thinking" pause.
        if speed != .fast, Double.random(in: 0..<1) < 0.02 {
            d += Double.random(in: 0.15...0.5) * (base / Speed.normal.baseDelay)
        }
        return d
    }
}
