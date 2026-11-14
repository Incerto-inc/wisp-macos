# Permissions

Wisp asks macOS for up to three permissions. The panel shows which ones are missing and
walks you through them; this page is for when that does not work.

| Permission | Why Wisp needs it | Needed for |
| --- | --- | --- |
| **Screen & System Audio Recording** | To record the chosen window, display or tab, and the sound of the meeting app | Meeting recordings |
| **Microphone** | To record your voice | Meeting and Room recordings |
| **Automation**, once per browser | To list a browser's tabs and bring a tab to the front of its window | Recording a browser tab (optional) |

In System Settings, Wisp appears as **Wisp** (bundle id `tech.incerto.wisp.mac`). Recordings
stay on your Mac; none of these permissions lets Wisp send anything anywhere.

## Allow Wisp

1. Install the app with `./Scripts/package-app.sh` and open **/Applications/Wisp.app**.
   Run Wisp from the app, not with `swift run Wisp`: from a terminal, macOS gives the
   permissions to the terminal instead.
2. Click the Wisp icon in the menu bar. The panel says **Before you record**.
3. **Screen & System Audio**: click **Allow…**. macOS shows its own prompt the first time;
   after that, Wisp opens System Settings → Privacy & Security → Screen & System Audio
   Recording. Turn on **Wisp**.
4. **Reopen Wisp**: macOS applies screen recording permission only when the app starts again.
   Use the **Reopen Wisp** button in the panel.
5. **Microphone**: click **Allow…** and answer the macOS prompt. If you declined it before,
   Wisp opens System Settings → Privacy & Security → Microphone instead; turn on
   **Wisp**.

Room mode needs only the microphone.

## Browser tabs (Automation)

To record a single tab, Wisp reads the tabs of Google Chrome, Microsoft Edge, Brave, Vivaldi,
Chromium, Arc, Dia or Safari through the browser's scripting interface. macOS asks once per
browser, the first time Wisp asks to read that browser's tabs, whether **Wisp** may
control that browser. Click **Allow**.

Wisp uses this access only to read window and tab titles and addresses, and to bring the tab
you record to the front of its window. It never opens a browser that is not running. Private and incognito windows are skipped in Chrome-family browsers and Arc; Safari and Dia do not tell scripts which windows are private, so tabs in their private windows can appear in the list (they are never recorded unless you pick one). Firefox has no scripting interface for tabs, so Firefox
tabs cannot be listed (Firefox windows can still be recorded as windows).

Automation is optional. Without it, Wisp still lists windows and displays, just not that
browser's tabs.

If you clicked **Don't Allow**, macOS does not ask again. Turn it on in System Settings →
Privacy & Security → **Automation** → **Wisp** → the browser.

## Troubleshooting

**System Settings shows Wisp turned on, but the panel still asks for screen recording.**
Quit Wisp completely and open it again (the panel's **Reopen Wisp** button, or ⋯ → Quit Wisp,
then open `/Applications/Wisp.app`). The permission applies only to a newly started app.

**Wisp lost its permissions after a rebuild.** macOS ties the permission to the app's code
signature. `Scripts/package-app.sh` signs with an "Apple Development" certificate when your
keychain has one, which keeps the permissions across rebuilds. Without one it signs ad-hoc,
and every rebuild looks like a new app: turn **Wisp** off and on again in System
Settings, or remove it (−) and allow it again. To choose a certificate, set
`WISP_CODESIGN_IDENTITY`.

**System Settings lists Wisp more than once.** Older builds (for example a copy under
`.build/`) leave their own rows. Remove the extra rows with −, keep `/Applications/Wisp.app`,
turn it on, and reopen Wisp.

**Only "System Audio Recording Only" is on.** That is not enough: Wisp also records video.
Turn Wisp on under **Screen & System Audio Recording**.

**No tabs from a browser.** Check System Settings → Privacy & Security → Automation → Wisp
macOS. The browser must be running. Tabs in private and incognito windows of Chrome-family
browsers and Arc are not shown.

### Useful commands

Open the right System Settings page:

```bash
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
```

Check which app is installed and how it is signed:

```bash
plutil -extract CFBundleIdentifier raw /Applications/Wisp.app/Contents/Info.plist   # tech.incerto.wisp.mac
codesign -dv /Applications/Wisp.app 2>&1 | grep -E 'Identifier|Signature'
```

Start over (macOS asks again on the next use; quit Wisp first):

```bash
tccutil reset ScreenCapture tech.incerto.wisp.mac
tccutil reset Microphone tech.incerto.wisp.mac
tccutil reset AppleEvents tech.incerto.wisp.mac   # Automation, for every browser
```
