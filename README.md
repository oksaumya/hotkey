# Groq Hotkey

A small macOS menu bar app. Select text in any app and press a hotkey to send it to Groq. Then press a second hotkey and the answer is typed at your cursor, letter by letter, like a person typing (or copied to the clipboard, your choice).

## Usage

1. Select some text in any app.
2. Press **⌘⇧Space** (Cmd + Shift + Space). The app copies the selection and sends it to Groq; the menu bar icon changes to ⏳. (You can also copy with ⌘C first.)
3. Click where you want the answer to go.
4. Press **⌥⇧R** (Option + Shift + R). The answer is typed out like a human, and the icon shows `⌨️` while it types.
   - To stop typing, press **Esc**, or press **⌥⇧R** again.
   - If you press ⌥⇧R before the answer is ready, the app waits and delivers it as soon as it arrives.

Menu bar icon states: `✦` idle · `⏳` sending · `✅` result ready · `⌨️` typing · `❌` error. Click the icon for details. Messages appear as a small banner at the top of the screen.

## Build and run

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open build/GroqHotkey.app
```

On first launch the app asks for your Groq API key (from https://console.groq.com/keys). The key is stored in the macOS Keychain, not in any file. Change it later from the menu with **Change Groq API Key…**.

### Permissions

- **Keychain:** when macOS asks whether GroqHotkey may use the saved key, click **Always Allow**.
- **Accessibility (needed for auto-typing and for grabbing the selection):** System Settings → Privacy & Security → Accessibility → turn **GroqHotkey** on.

### Keep permissions across rebuilds (optional)

By default `build.sh` uses an ad-hoc signature, so macOS treats each rebuild as a new app and you must re-grant permissions. To avoid that, create a stable local signing certificate once:

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: **GroqHotkey Local Signing**, Identity Type: *Self-Signed Root*, Certificate Type: *Code Signing*. Create it.
3. Run `./build.sh` again — it will pick up the certificate automatically.

## Settings (menu bar icon)

- **Output**: **Type it like a human** (default) or **Copy to clipboard** (paste with ⌘V).
- **Typing Speed**: Fast, Normal (human) or Slow.
- **Model**: a Groq model, or any model ID via **Custom Model…**. Default `openai/gpt-oss-120b`.
- **System Prompt…**: instructions sent with every request. The default asks for plain text (no Markdown) so typed answers don't contain `**` or `#`.

## Start at login and auto-restart (optional)

```bash
./install-agent.sh            # start at login + restart automatically if killed/crashed
./install-agent.sh uninstall  # undo
```

Choosing **Quit Groq Hotkey** from the menu still quits the app (it returns at next login).

## Troubleshooting

- Log: `~/Library/Logs/GroqHotkey.log` — records every hotkey press, request, and why the app quit.
- If **⌥⇧R types a symbol** like `‰`, the app isn't running. Check for the `✦` icon and reopen it.
- If typing goes to the wrong window, click the target field first so it has focus.
- Newlines are typed as **Enter**; in chat apps this may send the message early.

## Changing the hotkeys

Edit `sendHotKey` and `resultHotKey` at the top of `Sources/AppDelegate.swift`, then run `./build.sh` again. Modifiers: `cmdKey`, `shiftKey`, `optionKey`, `controlKey`, combined with `|`. Avoid shortcuts apps already use (e.g. ⌘⇧R is browser hard-reload).

## Files

| File | Purpose |
|---|---|
| `Sources/AppDelegate.swift` | Menu bar UI, hotkey actions, settings |
| `Sources/HotKeyManager.swift` | Global hotkeys (Carbon) |
| `Sources/Typer.swift` | Human-like auto-typing + copy helper |
| `Sources/HUD.swift` | On-screen banner that doesn't steal focus |
| `Sources/GroqClient.swift` | Groq chat completions API call |
| `Sources/Keychain.swift` | Saves and loads the API key |
| `Info.plist` | App bundle settings (menu bar only, no Dock icon) |
| `build.sh` | Builds `build/GroqHotkey.app` |
| `install-agent.sh` | Optional login + auto-restart agent |
