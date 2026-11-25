import Carbon
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Hotkeys (change them here)

    /// Step 1: send the selected / copied text to Groq.
    static let sendHotKey = (keyCode: kVK_Space, modifiers: cmdKey | shiftKey, label: "⌘⇧Space")
    /// Step 2: type (or copy) the Groq result. ⌥⇧R, because browsers use ⌘⇧R for hard reload.
    static let resultHotKey = (keyCode: kVK_ANSI_R, modifiers: optionKey | shiftKey, label: "⌥⇧R")

    // MARK: - Models

    static let defaultModel = "openai/gpt-oss-120b"
    static let presetModels = [
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",
        "qwen/qwen3.8-27b",
    ]

    /// Used until the user sets their own system prompt, so auto-typed answers don't contain **markdown**.
    static let defaultSystemPrompt = "Reply in plain text only. Do not use Markdown formatting (no **, #, or bullet symbols)."

    // MARK: - State

    enum State {
        case idle
        case sending
        case ready(String)
        case failed(String)
    }

    private var statusItem: NSStatusItem!
    private var state: State = .idle { didSet { refreshUI() } }
    private var requestCounter = 0
    private var lastPrompt: String?
    /// Set when the result hotkey is pressed while a request is still running: deliver as soon as it arrives.
    private var deliverWhenReady = false
    /// Cached so we don't hit the Keychain (and risk permission prompts) on every menu refresh.
    private var cachedAPIKey: String?

    private let client = GroqClient()
    private let typer = Typer()
    private let defaults = UserDefaults.standard

    /// Kept alive so the signal handlers keep firing.
    private var signalSources: [DispatchSourceSignal] = []

    private var apiKey: String? {
        if cachedAPIKey == nil {
            cachedAPIKey = Keychain.loadAPIKey()
            // Re-save once so the Keychain item is owned by this (stable-signed) app;
            // then rebuilt versions can read it without a permission prompt.
            if let key = cachedAPIKey, !defaults.bool(forKey: "keyOwnedByApp") {
                if Keychain.saveAPIKey(key) { defaults.set(true, forKey: "keyOwnedByApp") }
            }
        }
        return cachedAPIKey
    }

    /// "type" = auto-type like a human, "copy" = put on clipboard.
    private var outputMode: String {
        get { defaults.string(forKey: "outputMode") ?? "type" }
        set { defaults.set(newValue, forKey: "outputMode"); refreshUI() }
    }

    private var typingSpeed: Typer.Speed {
        get { Typer.Speed(rawValue: defaults.string(forKey: "typingSpeed") ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "typingSpeed"); refreshUI() }
    }

    private var model: String {
        get { defaults.string(forKey: "model") ?? Self.defaultModel }
        set { defaults.set(newValue, forKey: "model"); refreshUI() }
    }

    private var systemPrompt: String {
        get { defaults.string(forKey: "systemPrompt") ?? Self.defaultSystemPrompt }
        set { defaults.set(newValue, forKey: "systemPrompt"); refreshUI() }
    }

    /// Logs to Console and to ~/Library/Logs/GroqHotkey.log (useful for troubleshooting).
    private func log(_ message: String) {
        NSLog("[GroqHotkey] %@", message)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GroqHotkey.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let sendOK = HotKeyManager.shared.register(keyCode: Self.sendHotKey.keyCode,
                                                   modifiers: Self.sendHotKey.modifiers) { [weak self] in
            self?.sendClipboard()
        }
        let resultOK = HotKeyManager.shared.register(keyCode: Self.resultHotKey.keyCode,
                                                     modifiers: Self.resultHotKey.modifiers) { [weak self] in
            self?.deliverResult()
        }

        refreshUI()

        if !sendOK || !resultOK {
            let failed = [sendOK ? nil : Self.sendHotKey.label, resultOK ? nil : Self.resultHotKey.label]
                .compactMap { $0 }.joined(separator: ", ")
            notify("Could not register hotkey \(failed) — another app may be using it.", isError: true)
        }

        installExitLogging()
        log("launched (pid \(ProcessInfo.processInfo.processIdentifier)); hotkeys registered send=\(sendOK) result=\(resultOK)")

        if apiKey == nil {
            promptForAPIKey()
        }
        if outputMode == "type", !Typer.hasAccessibility(prompt: true) {
            log("accessibility not granted yet")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("quitting (applicationWillTerminate)")
        HotKeyManager.shared.unregisterAll()
    }

    /// Logs why the app is being stopped (SIGTERM from macOS / `kill`, etc.) before exiting.
    private func installExitLogging() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.log("received signal \(sig) — exiting")
                exit(128 + sig) // non-zero, so a login agent (if installed) restarts the app
            }
            source.resume()
            signalSources.append(source)
        }
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[GroqHotkey] uncaught exception: %@ %@", exception.name.rawValue, exception.reason ?? "")
        }
    }

    // MARK: - Hotkey actions

    /// Reads text from the clipboard: plain text first, then falls back to rich text / HTML.
    private func clipboardText() -> String {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let objs = pb.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString],
           let s = objs.first?.string, !s.isEmpty { return s }
        if let objs = pb.readObjects(forClasses: [NSString.self]) as? [String],
           let s = objs.first, !s.isEmpty { return s }
        return ""
    }

    private func sendClipboard() {
        log("send hotkey pressed")
        captureSelection { [weak self] text in
            self?.send(text)
        }
    }

    /// Copies the current selection (by pressing ⌘C for you), then hands back the clipboard text.
    /// If nothing is selected, the existing clipboard content is used, so copying first with ⌘C also works.
    private func captureSelection(_ completion: @escaping (String) -> Void) {
        guard Typer.hasAccessibility(prompt: false) else {
            completion(clipboardText())
            return
        }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Typer.waitForModifiersReleased() // otherwise ⌘C would become ⌘⇧C
            Typer.pressCopy()
            var changed = false
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.02)
                if pasteboard.changeCount != before { changed = true; break }
            }
            if changed { Thread.sleep(forTimeInterval: 0.05) } // let the app finish writing
            DispatchQueue.main.async {
                guard let self else { return }
                self.log(changed ? "copied current selection" : "nothing newly copied; using existing clipboard")
                completion(self.clipboardText())
            }
        }
    }

    private func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            log("no text: clipboard empty")
            notify("No text found. Select some text, then press \(Self.sendHotKey.label).", isError: true)
            return
        }
        guard let apiKey else {
            log("no API key")
            notify("No Groq API key set.", isError: true)
            promptForAPIKey()
            return
        }

        requestCounter += 1
        let requestID = requestCounter
        lastPrompt = text
        deliverWhenReady = false
        state = .sending
        NSSound(named: "Tink")?.play()
        log("request #\(requestID) sent (\(text.count) chars, model \(model))")

        client.complete(prompt: text, systemPrompt: systemPrompt, model: model, apiKey: apiKey) { [weak self] result in
            guard let self, requestID == self.requestCounter else { return } // a newer request replaced this one
            switch result {
            case let .success(answer):
                self.log("request #\(requestID) succeeded (\(answer.count) chars)")
                self.state = .ready(answer)
                if self.deliverWhenReady {
                    self.deliverWhenReady = false
                    self.deliverResult()
                } else {
                    self.notify("Result ready — press \(Self.resultHotKey.label) to \(self.outputMode == "type" ? "type" : "copy") it.")
                }
            case let .failure(error):
                self.log("request #\(requestID) failed: \(error.localizedDescription)")
                if case GroqError.http(status: 401, _) = error { self.cachedAPIKey = nil }
                self.deliverWhenReady = false
                self.state = .failed(error.localizedDescription)
                self.notify(error.localizedDescription, isError: true)
            }
        }
    }

    private func deliverResult() {
        log("result hotkey pressed")

        // Pressing the hotkey again while typing stops it.
        if typer.isTyping {
            typer.cancel()
            return
        }

        switch state {
        case let .ready(answer):
            if outputMode == "type" {
                typeResult(answer)
            } else {
                copyResult(answer)
            }
        case .sending:
            // Pressed too early: deliver automatically as soon as the answer arrives.
            deliverWhenReady = true
            NSSound(named: "Tink")?.play()
            notify("Still working… the result will be delivered automatically when it's ready.")
        case let .failed(message):
            notify("Last request failed: \(message)", isError: true)
        case .idle:
            notify("Nothing yet — select text and press \(Self.sendHotKey.label) first.", isError: true)
        }
    }

    private func copyResult(_ answer: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        notify("Result copied — press ⌘V to paste.")
    }

    private func typeResult(_ answer: String) {
        guard Typer.hasAccessibility(prompt: true) else {
            log("accessibility NOT granted — copying to clipboard instead of typing")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
            notify("Can't type: allow GroqHotkey in System Settings → Privacy & Security → Accessibility. Result copied to clipboard instead (⌘V).",
                   isError: true)
            return
        }
        log("typing \(answer.count) chars at \(typingSpeed.rawValue) speed")
        typer.type(answer, speed: typingSpeed) { [weak self] finished in
            self?.log(finished ? "typing finished" : "typing stopped")
            if !finished { NSSound(named: "Pop")?.play() }
            self?.refreshUI()
        }
        refreshUI()
    }

    // MARK: - UI

    private func refreshUI() {
        guard let button = statusItem?.button else { return }

        let (icon, statusLine): (String, String)
        switch state {
        case .idle:              (icon, statusLine) = ("✦", "Idle")
        case .sending:           (icon, statusLine) = ("⏳", "Sending to Groq…")
        case .ready:             (icon, statusLine) = ("✅", "Result ready — \(Self.resultHotKey.label)")
        case let .failed(msg):   (icon, statusLine) = ("❌", "Error: \(msg)")
        }
        button.title = typer.isTyping ? "⌨️" : icon
        button.toolTip = "Groq Hotkey — \(statusLine)"

        let menu = NSMenu()
        menu.addItem(disabledItem(truncate(statusLine, 70)))
        if let lastPrompt {
            menu.addItem(disabledItem("Prompt: " + truncate(lastPrompt, 60)))
        }
        if case let .ready(answer) = state {
            menu.addItem(disabledItem("Result: " + truncate(answer, 60)))
            menu.addItem(item("Copy Result to Clipboard", #selector(copyResultClicked)))
        }
        if typer.isTyping {
            menu.addItem(item("Stop Typing (Esc)", #selector(stopTypingClicked)))
        }
        menu.addItem(.separator())

        let resultAction = outputMode == "type" ? "type result (again or Esc = stop)" : "copy result to clipboard"
        menu.addItem(disabledItem("\(Self.sendHotKey.label)  send selected text"))
        menu.addItem(disabledItem("\(Self.resultHotKey.label)  \(resultAction)"))
        menu.addItem(.separator())

        let outputMenu = NSMenu()
        for (mode, title) in [("type", "Type it like a human"), ("copy", "Copy to clipboard")] {
            let outputItem = item(title, #selector(outputModeClicked(_:)))
            outputItem.representedObject = mode
            outputItem.state = (mode == outputMode) ? .on : .off
            outputMenu.addItem(outputItem)
        }
        let outputRoot = NSMenuItem(title: "Output: \(outputMode == "type" ? "Type it" : "Clipboard")", action: nil, keyEquivalent: "")
        outputRoot.submenu = outputMenu
        menu.addItem(outputRoot)

        let speedMenu = NSMenu()
        for speed in Typer.Speed.allCases {
            let speedItem = item(speed.title, #selector(speedClicked(_:)))
            speedItem.representedObject = speed.rawValue
            speedItem.state = (speed == typingSpeed) ? .on : .off
            speedMenu.addItem(speedItem)
        }
        let speedRoot = NSMenuItem(title: "Typing Speed: \(typingSpeed.title)", action: nil, keyEquivalent: "")
        speedRoot.submenu = speedMenu
        menu.addItem(speedRoot)

        let modelMenu = NSMenu()
        var models = Self.presetModels
        if !models.contains(model) { models.append(model) }
        for name in models {
            let modelItem = item(name, #selector(modelClicked(_:)))
            modelItem.representedObject = name
            modelItem.state = (name == model) ? .on : .off
            modelMenu.addItem(modelItem)
        }
        modelMenu.addItem(.separator())
        modelMenu.addItem(item("Custom Model…", #selector(customModelClicked)))
        let modelRoot = NSMenuItem(title: "Model: \(model)", action: nil, keyEquivalent: "")
        modelRoot.submenu = modelMenu
        menu.addItem(modelRoot)

        let hasSystemPrompt = !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        menu.addItem(item(hasSystemPrompt ? "System Prompt… (set)" : "System Prompt…", #selector(systemPromptClicked)))
        menu.addItem(item(cachedAPIKey == nil ? "Set Groq API Key…" : "Change Groq API Key…",
                          #selector(apiKeyClicked)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Groq Hotkey", #selector(quitClicked), key: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func truncate(_ text: String, _ length: Int) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > length ? String(oneLine.prefix(length)) + "…" : oneLine
    }

    // MARK: - Menu actions

    @objc private func copyResultClicked() {
        if case let .ready(answer) = state { copyResult(answer) }
    }

    @objc private func stopTypingClicked() { typer.cancel() }

    @objc private func outputModeClicked(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        outputMode = mode
        if mode == "type" { _ = Typer.hasAccessibility(prompt: true) }
    }

    @objc private func speedClicked(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let speed = Typer.Speed(rawValue: raw) { typingSpeed = speed }
    }

    @objc private func modelClicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { model = name }
    }

    @objc private func customModelClicked() {
        if let value = promptForText(title: "Custom Groq model",
                                     message: "Enter a model ID from console.groq.com/docs/models",
                                     initial: model),
           !value.isEmpty {
            model = value
        }
    }

    @objc private func systemPromptClicked() {
        if let value = promptForText(title: "System prompt",
                                     message: "Optional instructions sent with every request (e.g. \"Answer briefly.\"). Leave empty for none.",
                                     initial: systemPrompt,
                                     multiline: true) {
            systemPrompt = value
        }
    }

    @objc private func apiKeyClicked() { promptForAPIKey() }

    @objc private func quitClicked() { NSApp.terminate(nil) }

    // MARK: - Dialogs

    private func promptForAPIKey() {
        guard let key = promptForText(title: "Groq API key",
                                      message: "Paste your API key from console.groq.com/keys. It is stored in your macOS Keychain.",
                                      initial: "",
                                      secure: true),
              !key.isEmpty
        else { return }

        cachedAPIKey = key
        defaults.set(true, forKey: "keyOwnedByApp")
        if Keychain.saveAPIKey(key) {
            notify("API key saved.")
        } else {
            notify("Could not save the API key to the Keychain.", isError: true)
        }
        refreshUI()
    }

    /// Shows a modal text-input dialog. Returns nil if the user cancels.
    private func promptForText(title: String, message: String, initial: String,
                               secure: Bool = false, multiline: Bool = false) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field: NSTextField
        if secure {
            field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        } else if multiline {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 110))
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.usesSingleLineMode = false
        } else {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        }
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Notifications

    /// Shows a small on-screen banner (that never steals focus) plus a short sound.
    private func notify(_ message: String, isError: Bool = false) {
        NSSound(named: isError ? "Basso" : "Pop")?.play()
        HUD.shared.show(truncate(message, 200), isError: isError)
    }
}
