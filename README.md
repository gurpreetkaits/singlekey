# SingleKey

**Type on two Macs with one keyboard. Press a shortcut to switch.**

SingleKey is a tiny menu-bar app for macOS. Run it on two (or more) Macs, press
**⌃⌥⌘Space**, and everything you type goes to the other Mac. Press it again to come back.
Your mouse stays on the Mac it's plugged into, unless you turn on **Also Send Mouse**.

- **Shortcut switching.** No dragging the pointer to a screen edge. The shortcut is configurable.
- **Keyboard only by default.** Optionally sends the mouse, clicks and scrolling too.
- **Finds your Macs automatically** on the same Wi-Fi/LAN, or anywhere over [Tailscale](https://tailscale.com).
- **Encrypted and private.** Macs only connect when they share a pairing code, and all input is
  sent over TLS using a key derived from that code. No accounts, no servers, no telemetry.
- **Safe switching.** If the connection drops, control returns to your Mac immediately, and any keys
  held down on the other Mac are released.
- Native Swift with no dependencies. Runs on macOS 13 or later, on Apple silicon and Intel.

## Install

### Option A: download

1. Download `SingleKey.zip` from the [latest release](../../releases/latest), unzip it, and move
   **SingleKey.app** to **Applications** on each Mac.
2. The app isn't notarized by Apple, so the first launch is blocked. Allow it with:
   ```sh
   xattr -dr com.apple.quarantine /Applications/SingleKey.app
   ```
   Or open it, then go to System Settings → Privacy & Security and click **Open Anyway**.

### Option B: build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/gurpreetkaits/singlekey.git
cd singlekey
./scripts/create-signing-cert.sh   # optional, one time: keeps permissions across rebuilds
./scripts/build-app.sh             # creates build/SingleKey.app and build/SingleKey.zip
cp -R build/SingleKey.app /Applications/
```

Copy `build/SingleKey.zip` to your other Mac, or build it there too.

## Set up (on each Mac)

1. Open **SingleKey**. A keyboard icon appears in the menu bar.
2. Grant the permissions macOS asks for, in System Settings → Privacy & Security:
   - **Accessibility**: to capture the shortcut and to type on this Mac for the other one
   - **Input Monitoring**: to read the keyboard
   - **Local Network**: to find your other Macs
3. Enter a **pairing code**. Use the same code on every Mac, and pick something hard to guess:
   it's the key that encrypts your keystrokes.

Within a few seconds each Mac lists the others in its menu. Press **⌃⌥⌘Space** to start typing
on the next Mac.

## Using it

| Menu item | What it does |
| --- | --- |
| *Mac names* | Choose which Mac gets your keyboard. The shortcut cycles through them in order. |
| Change Shortcut… | Press any key combination to use instead (Esc cancels). |
| Set Pairing Code… | Change the code. It must match on every Mac. |
| Also Send Mouse | Send the mouse, clicks and scrolling as well (the local pointer freezes and hides). |
| Launch at Login | Start SingleKey automatically. |

The menu-bar icon shows the state: **→** while you're controlling another Mac, **←** while
another Mac is controlling this one.

## Troubleshooting

- **The shortcut does nothing, or keys still type locally.** SingleKey lacks Accessibility or Input
  Monitoring permission. Remove SingleKey from both lists with **−**, add it again with **+**, then
  quit and reopen the app. After rebuilding without `create-signing-cert.sh`, you must grant them
  again each time.
- **The other Mac never shows up.**
  - Check that both Macs use the exact same pairing code (the menu says so if they don't).
  - Check that they're on the same network or the same tailnet.
  - Check that Local Network access is allowed.
  - If you use a firewall, allow incoming connections to SingleKey (TCP port 24804).
- **Keys arrive but nothing types on the other Mac.** The other Mac needs Accessibility permission too.
- **Wrong characters.** Keys are sent by position, not by character, so both Macs should use the same
  keyboard layout.
- **Diagnostics.** Run `log stream --predicate 'subsystem == "io.github.gurpreetkaits.singlekey"'`.

## How it works

- **Discovery.** Each Mac advertises itself over Bonjour (`_singlekey._tcp`) and listens on TCP
  port 24804. Bonjour doesn't cross Tailscale, so SingleKey also reads `tailscale status` and dials
  other online Macs on your tailnet directly.
- **Encryption.** Connections use TLS 1.2 with a pre-shared key: an HMAC-SHA256 of the pairing code.
  A Mac with a different code fails the handshake and never sees any input.
- **Capturing input.** A Quartz event tap on the controlling Mac captures the input. While you're
  switched away, it swallows key events locally and sends them as small length-prefixed JSON messages.
  Modifier keys are delivered on both Macs so their state never gets stuck.
- **Replaying input.** The receiving Mac replays events with `CGEvent`, tagged so its own tap ignores
  them.

```
Sources/SingleKey/
  AppDelegate.swift         menu bar, switching logic, permissions
  InputCapture.swift        event tap, shortcut detection, forwarding
  InputInjector.swift       replays received input
  PeerManager.swift         Bonjour + Tailscale discovery, TLS-PSK connections
  TailscaleDiscovery.swift  finds Macs on your tailnet
  Message.swift             wire protocol
  Hotkey.swift              shortcut + settings
  HUD.swift                 the "switched to…" banner
```

## Limitations

- The app isn't notarized, so Gatekeeper asks once (see Install).
- Clipboard isn't shared. For copy and paste between Macs, use Apple's Universal Clipboard.
- Secure input fields (password prompts, the login window) may ignore typed input, by macOS design.
- Trackpad gestures (pinch, swipe between spaces) aren't sent; scrolling is.

## License

[MIT](LICENSE)
