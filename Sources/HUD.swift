import Cocoa

/// A small on-screen banner at the top-center of the screen.
/// It never takes keyboard focus, so typing keeps going to the app you're in.
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(_ text: String, isError: Bool = false, duration: TimeInterval = 2.5) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = 440

        let textSize = label.fittingSize
        let size = NSSize(width: min(max(textSize.width, 120), 440) + 36, height: textSize.height + 22)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = (isError
            ? NSColor(calibratedRed: 0.62, green: 0.12, blue: 0.12, alpha: 0.93)
            : NSColor(calibratedWhite: 0.1, alpha: 0.9)).cgColor

        label.frame = NSRect(x: 18, y: 11, width: size.width - 36, height: textSize.height)
        background.addSubview(label)
        panel.contentView = background

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
