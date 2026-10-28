# WMac!

Native Swift/AppKit taskbar for macOS 14+. The default runtime now displays one nonactivating panel per connected display, saved pins and real process buttons, exact-instance switching and menus, independent launch requests, horizontal overflow, clock/date and persistent WMac menu bar controls. This is an **intermediate development build**, not the completed MVP. Persistent native settings and explicit login registration controls are implemented; local universal DMG preparation is implemented. Pin gestures are implemented; actual Finder-drop acceptance and the broader accessibility/display matrix still need manual verification.

Open `WMac.xcodeproj` in Xcode and run the shared **WMac** scheme, or use:

```sh
./scripts/setup-dev-signing.sh # once per Mac
./scripts/build.sh Debug
open .build/products/Debug/WMac.app
./scripts/test.sh
./scripts/build.sh Release
./scripts/verify-build.sh
```

Xcode with its macOS SDK and command line tools is required. The project has Debug/Release configurations, macOS 14.0 deployment, Swift 6, and universal arm64/x86_64 builds. The build command produces local development products. For a GitHub Releases DMG, use the release preparation command below; it builds only the shipping target in an isolated directory and applies an ad-hoc signature with Hardened Runtime.

## Local Debug signing and Accessibility

Run `./scripts/setup-dev-signing.sh` once on each development Mac before building Debug or using Xcode Run. It reuses a valid Apple Development identity when one is available. Otherwise it creates one self-signed Code Signing identity, imports its non-extractable private key into the default user Keychain, and reuses that identity on later runs. The self-signed identity is not added to system trust; it is used for local code identity only. Temporary key and certificate files are removed. The script writes only the certificate fingerprint to the root `LocalSigning.xcconfig`, which Git ignores. It never creates a certificate during a build. If the certificate expires or is removed, Debug builds stop with an error until the local signing setup is repaired.

The shared WMac Xcode scheme and `./scripts/build.sh Debug` use the same Debug configuration and signing identity. Xcode runs from its DerivedData product directory; the CLI opens `.build/products/Debug/WMac.app`. Both keep the stable `app.wmac.WMac` bundle ID and the same code identity, so the product keeps a stable designated requirement across source edits and builds. Xcode Debug disables its auxiliary debug dylib: with a self-signed identity that has no Apple Team ID, macOS library validation rejects that dylib at launch. The ordinary executable remains Hardened Runtime signed and LLDB attach is enabled by the Debug-only entitlement. Choose either path for development; after the first launch, approve WMac once under System Settings → Privacy & Security → Accessibility when macOS asks or when you enable its listed entry manually. The app must be re-approved if its signing identity changes. No script grants or resets TCC permissions.

`./scripts/test.sh --require-ax` checks Accessibility from the signed `WMacProbe` executable, not from WMac.app. It prints the probe's actual designated requirement so you can identify the caller macOS is checking; System Settings may list WMacProbe or its responsible Terminal/host. That test does not prove WMac.app has a grant. `--require-no-ax` likewise checks the probe's actual process and exits `3` when that process is already trusted.

For TCC diagnosis, compare the current signature and designated requirement before and after a rebuild:

```sh
security find-identity -p codesigning
codesign --verify --deep --strict .build/products/Debug/WMac.app
codesign -d -r - .build/products/Debug/WMac.app
```

The `-v` form lists Apple-valid identities. The local self-signed identity may instead appear in the command above with `CSSMERR_TP_NOT_TRUSTED`; that is expected because setup does not change system trust. Also confirm the current WMac and WMacProbe entries under Privacy & Security → Accessibility. A changed or unavailable identity is a signing configuration issue; an unchecked entry needs the user's ordinary confirmation. Do not edit TCC storage directly. Avoid resetting permissions unless a specific test requires it and the user has been warned.

Click a running button to switch to its exact process and last available active window. Shift-click or middle-click requests an independent process of the exact application URL. Right-click for windows and process actions; force termination requires confirmation. Idle pins use ordinary launch. Drop GUI `.app` bundles from Finder onto a panel to pin them; drag pinned buttons to persist their order. Process menus offer Pin/Unpin. The WMac menu’s Pinned applications submenu also offers Unpin and Move left/right, plus a native replacement picker for missing apps. Failed storage preserves the original file and visible state; use Retry pins after correcting access or restoring a valid file. The left Applications button opens a native searchable catalog. Type a name, use Up/Down and Enter to open the exact selected bundle, Escape to dismiss, or Tab into results and Shift-F10 (or right-click) → Pin. The list refreshes asynchronously on opening and through Refresh; loading, empty and no-match states are explicit. Search works for unpinned applications too. Orange indicators and accessible pending counts track independent requests; error/unconfirmed details are available in the WMac menu. Menu bar and panel controls provide Settings (Cmd-comma), manual hide/show, instructions, permission status/settings, Dock settings and Quit. Closing an information window leaves this route available. Reopening WMac also restores hidden panels.

**Window previews (IDD-0010).** Hover over a running app button for 450 ms to see its window cards: the default Automatic mode opens when at least one manageable window is available, and Disabled suppresses the automatic popup. Per-app Always overrides can enable previews while the global mode is disabled. Choose **Show windows…** from the right-click menu regardless of the hover mode. Select a card (or an entry under Windows) to restore and activate that exact AX window. The popup supports Escape, keyboard navigation and VoiceOver; missing capture permissions never prevent choosing an AX window. The standard button tooltip is hidden while the popup is displayed. A card without an identifiable or capturable image retains its title and shows a placeholder.

Use Settings → **Window Previews** to select the global hover mode, turn real thumbnails on/off, and override hover behavior by application (across its instances). Thumbnails use ScreenCaptureKit single-frame captures and require a separate permission under System Settings → Privacy & Security → Screen & System Audio Recording. Click **Allow window thumbnails…** in settings or the popup to request it; macOS may require restarting WMac after approval. WMac never captures windows merely on mouse movement and never stores or uploads frames. On permission denial, protected/minimized windows or ambiguous AX-to-graphics matching, placeholders are intentional. If Accessibility is unavailable, explicit Show windows explains the limitation, and ordinary PID-based taskbar switching remains available. The persisted settings schema is v4 (migrates v1–v3 without discarding pins).

The system Dock remains installed and running. By default WMac leaves its preferences untouched. General → **Hide system Dock while WMac runs** is a separately confirmed, opt-in feature: it temporarily sets only the current-user Dock `autohide`, `autohide-delay` and `autohide-time-modifier` preferences, with a one-shot crash watchdog. It restores the original values (including absent keys) on disable, manual panel hiding or normal exit, and tries recovery on the next WMac launch after a power failure. External preference changes are preserved. The menu includes **Restore system Dock** while an active transaction needs recovery. The snapshot is stored independently at `~/Library/Application Support/WMac/SystemDockVisibilityState.plist`; if that file is damaged, WMac does not guess original values and manual restoration via Desktop & Dock may be necessary. The long autohide delay is not an absolute guarantee against seeing Dock. No administrator privileges, Terminal or Accessibility grant are needed. Panels use public all-Spaces behavior with fullscreen participation disabled; actual multi-display/fullscreen behavior needs the manual matrix below.

For the former diagnostic interface, run `open .build/products/Debug/WMac.app --args --diagnostics` after quitting the normal runtime. It retains launch, AX and pin test controls. Pins remain compatible at `~/Library/Application Support/WMac/pins.json`. A separate developer harness, `--panel-test-width 480`, narrows real panels for overflow inspection without synthetic buttons.

Process discovery, launches, exact-process switching and termination work without Accessibility. Window selection, restore and minimize need an explicit grant. The first user window-control action explains the limitation and requests access once per run; the menu offers explicit permission controls. Startup and passive checks never prompt. Screen Recording is optional, is never requested on startup or hover, and is only requested after the user chooses to allow window thumbnails. Panel buttons and menus use native keyboard/VoiceOver semantics, with Tab/Space and Shift-F10 for focused-button menus; full assistive-technology acceptance remains manual.

`./scripts/test.sh --require-ax` requires real AX access. `./scripts/test.sh --require-no-ax` requires a genuinely untrusted host; it exits 3 if the current host already has access. Run in a logged-in, unlocked local GUI session and avoid interacting with other apps during foreground assertions. The probe launches real test apps, briefly changes foreground focus, then terminates only the processes it launched. Test fixtures are verification tools, not WMac helpers.

Current product requirements and acceptance criteria live in `.idd/intent/`; durable implementation rules live in `.idd/engineering/`.

Inspect the installed GUI application catalog without launching anything:

```sh
.build/products/Debug/WMacProbe --catalog
.build/products/Debug/WMacProbe --catalog --search "редактор"
```

This scans the standard application roots asynchronously, reports the total and prints at most 30 name/identity/path entries. The same catalog backs the native Applications popup.

Settings has General, Appearance, Behavior, Window Previews, Applications and Permissions tabs in a normal resizable/minimizable window. All/primary display selection uses the primary display identity. Height is 40–64 pt (52 default), background opacity 35–100% (85% default), and theme is System/Light/Dark. Middle-click defaults on; active-window minimization defaults off; Shift-click is fixed. Exclusions match bundle ID plus canonical URL, hide matching pins/processes and keep saved pins recoverable. Pin menus in Applications retain reorder/unpin/relink controls.

Settings are saved atomically in `~/Library/Application Support/WMac/settings.json`, schema version 3, independently of compatible `pins.json`. Versions 1 and 2 settings migrate on load with Dock hiding disabled. Invalid/unsupported settings block edits and remain intact; General offers Retry or explicit recovery that preserves an exact uniquely named backup before saving defaults. Reset preserves pins/order and does not alter OS login registration. Changes propagate after successful save, including newly attached panels. First-run Dock guidance is remembered; system Dock preferences remain unchanged unless the optional mode is confirmed.

Launch at login is controlled only by explicit Enable/Disable actions through `SMAppService.mainApp`; status reflects the operating system, including denied/approval-required, missing installation and errors. Registration and actual login have not been exercised on this local development bundle (observed service-not-found). Install the packaged app in Applications for final acceptance. WMac does not silently register on startup or reset.


## Prepare a GitHub Releases DMG

```sh
./scripts/release.sh               # default version 0.1.0, build 1
./scripts/release.sh 0.1.1 2       # explicit numeric major.minor[.patch], positive build
```

This local command needs Xcode and the macOS tools above, with no credentials, certificate or network operations. Each invocation builds only WMac into a fresh `.build/distribution/release-VERSION-BUILD.XXXXXX/` directory. It retains `WMac-VERSION-BUILD.dmg`, relative `SHA256.txt`, build and verification logs, and `AUTOMATED-CHECKS-PASSED.txt` after successful checks. Failures exit nonzero and produce no success marker; an image awaiting verification has an `.unverified.dmg` suffix. Products and intermediates remain outside the image. The DMG contains WMac.app (including its universal, individually signed Contents/Helpers/WMacDockWatchdog) and an Applications link.

The command verifies both executable slices, macOS 14.0 deployment metadata, identity `app.wmac.WMac`, RU/EN WMac! names, requested versions, the actual ad-hoc signature, Hardened Runtime and absence of debug entitlements. It checks image integrity, mounts the actual DMG read-only, checks its payload/link and re-verifies the contained app. To repeat checks:

```sh
./scripts/verify-release-dmg.sh /absolute/path/WMac-0.1.0-1.dmg 0.1.0 1
cd /absolute/path/to/output
shasum -a 256 -c SHA256.txt
```

Open the DMG in Finder and drag WMac.app onto Applications. Eject the image and open WMac! from Applications. This MVP uses local ad-hoc signing; it has no trusted Developer ID signature, notarization or stapling. macOS may block a downloaded unnotarized app and require its ordinary first-launch approval in System Settings → Privacy & Security → Open Anyway, if available, followed by confirmation. A seamless first double-click on every Mac is not guaranteed. Only approve an app you trust; WMac never changes Gatekeeper, quarantine or system trust. After a system-permitted launch, ordinary use needs no Terminal. Downloaded/quarantined behavior must be checked on an appropriate host; local copy launch evidence does not establish that acceptance. Publication/upload is a separate explicit action.
