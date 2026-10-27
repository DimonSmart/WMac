# WMac!

Native Swift/AppKit taskbar for macOS 14+. The default runtime now displays one nonactivating panel per connected display, saved pins and real process buttons, exact-instance switching and menus, independent launch requests, horizontal overflow, clock/date and persistent WMac menu bar controls. This is an **intermediate development build**, not the completed MVP. Persistent native settings and explicit login registration controls are implemented; local universal DMG preparation is implemented. Pin gestures are implemented; actual Finder-drop acceptance and the broader accessibility/display matrix still need manual verification.

Open `WMac.xcodeproj` in Xcode and run the shared **WMac** scheme, or use:

```sh
./scripts/build.sh Debug
open .build/products/Debug/WMac.app
./scripts/test.sh
./scripts/build.sh Release
./scripts/verify-build.sh
```

Xcode with its macOS SDK and command line tools is required. The project has Debug/Release configurations, macOS 14.0 deployment, Swift 6, and universal arm64/x86_64 builds. The build command produces local development products. For a GitHub Releases DMG, use the release preparation command below; it builds only the shipping target in an isolated directory and applies an ad-hoc signature with Hardened Runtime.

Click a running button to switch to its exact process and last available active window. Shift-click or middle-click requests an independent process of the exact application URL. Right-click for windows and process actions; force termination requires confirmation. Idle pins use ordinary launch. Drop GUI `.app` bundles from Finder onto a panel to pin them; drag pinned buttons to persist their order. Process menus offer Pin/Unpin. The WMac menu’s Pinned applications submenu also offers Unpin and Move left/right, plus a native replacement picker for missing apps. Failed storage preserves the original file and visible state; use Retry pins after correcting access or restoring a valid file. The left Applications button opens a native searchable catalog. Type a name, use Up/Down and Enter to open the exact selected bundle, Escape to dismiss, or Tab into results and Shift-F10 (or right-click) → Pin. The list refreshes asynchronously on opening and through Refresh; loading, empty and no-match states are explicit. Search works for unpinned applications too. Orange indicators and accessible pending counts track independent requests; error/unconfirmed details are available in the WMac menu. Menu bar and panel controls provide Settings (Cmd-comma), manual hide/show, instructions, permission status/settings, Dock settings and Quit. Closing an information window leaves this route available. Reopening WMac also restores hidden panels.

The system Dock stays available. Enable auto-hide or move it to a side manually in Desktop & Dock if desired; WMac never changes Dock preferences or reserves workspace. Panels use public all-Spaces behavior with fullscreen participation disabled; actual multi-display/fullscreen behavior needs the manual matrix below.

For the former diagnostic interface, run `open .build/products/Debug/WMac.app --args --diagnostics` after quitting the normal runtime. It retains launch, AX and pin test controls. Pins remain compatible at `~/Library/Application Support/WMac/pins.json`. A separate developer harness, `--panel-test-width 480`, narrows real panels for overflow inspection without synthetic buttons.

Process discovery, launches, exact-process switching and termination work without Accessibility. Window selection, restore and minimize need an explicit grant. The first user window-control action explains the limitation and requests access once per run; the menu offers explicit permission controls. Startup and passive checks never prompt. WMac requests no Screen Recording. Panel buttons and menus use native keyboard/VoiceOver semantics, with Tab/Space and Shift-F10 for focused-button menus; full assistive-technology acceptance remains manual.

`./scripts/test.sh --require-ax` requires real AX access. `./scripts/test.sh --require-no-ax` requires a genuinely untrusted host; it exits 3 if the current host already has access. Run in a logged-in, unlocked local GUI session and avoid interacting with other apps during foreground assertions. The probe launches real test apps, briefly changes foreground focus, then terminates only the processes it launched. Test fixtures are verification tools, not WMac helpers.

Current product requirements and acceptance criteria live in `.idd/intent/`; durable implementation rules live in `.idd/engineering/`.

Inspect the installed GUI application catalog without launching anything:

```sh
.build/products/Debug/WMacProbe --catalog
.build/products/Debug/WMacProbe --catalog --search "редактор"
```

This scans the standard application roots asynchronously, reports the total and prints at most 30 name/identity/path entries. The same catalog backs the native Applications popup.

Settings has General, Appearance, Behavior, Applications and Permissions tabs in a normal resizable/minimizable window. All/primary display selection uses the primary display identity. Height is 40–64 pt (52 default), background opacity 35–100% (85% default), and theme is System/Light/Dark. Middle-click defaults on; active-window minimization defaults off; Shift-click is fixed. Exclusions match bundle ID plus canonical URL, hide matching pins/processes and keep saved pins recoverable. Pin menus in Applications retain reorder/unpin/relink controls.

Settings are saved atomically in `~/Library/Application Support/WMac/settings.json`, schema version 2, independently of compatible `pins.json`. Version 1 settings migrate on load. Invalid/unsupported settings block edits and remain intact; General offers Retry or explicit recovery that preserves an exact uniquely named backup before saving defaults. Reset preserves pins/order and does not alter OS login registration. Changes propagate after successful save, including newly attached panels. First-run Dock guidance is remembered; system Dock preferences are never modified.

Launch at login is controlled only by explicit Enable/Disable actions through `SMAppService.mainApp`; status reflects the operating system, including denied/approval-required, missing installation and errors. Registration and actual login have not been exercised on this local development bundle (observed service-not-found). Install the packaged app in Applications for final acceptance. WMac does not silently register on startup or reset.


## Prepare a GitHub Releases DMG

```sh
./scripts/release.sh               # default version 0.1.0, build 1
./scripts/release.sh 0.1.1 2       # explicit numeric major.minor[.patch], positive build
```

This local command needs Xcode and the macOS tools above, with no credentials, certificate or network operations. Each invocation builds only WMac into a fresh `.build/distribution/release-VERSION-BUILD.XXXXXX/` directory. It retains `WMac-VERSION-BUILD.dmg`, relative `SHA256.txt`, build and verification logs, and `AUTOMATED-CHECKS-PASSED.txt` after successful checks. Failures exit nonzero and produce no success marker; an image awaiting verification has an `.unverified.dmg` suffix. Products and intermediates remain outside the image. The DMG contains WMac.app and an Applications link.

The command verifies both executable slices, macOS 14.0 deployment metadata, identity `app.wmac.WMac`, RU/EN WMac! names, requested versions, the actual ad-hoc signature, Hardened Runtime and absence of debug entitlements. It checks image integrity, mounts the actual DMG read-only, checks its payload/link and re-verifies the contained app. To repeat checks:

```sh
./scripts/verify-release-dmg.sh /absolute/path/WMac-0.1.0-1.dmg 0.1.0 1
cd /absolute/path/to/output
shasum -a 256 -c SHA256.txt
```

Open the DMG in Finder and drag WMac.app onto Applications. Eject the image and open WMac! from Applications. This MVP uses local ad-hoc signing; it has no trusted Developer ID signature, notarization or stapling. macOS may block a downloaded unnotarized app and require its ordinary first-launch approval in System Settings → Privacy & Security → Open Anyway, if available, followed by confirmation. A seamless first double-click on every Mac is not guaranteed. Only approve an app you trust; WMac never changes Gatekeeper, quarantine or system trust. After a system-permitted launch, ordinary use needs no Terminal. Downloaded/quarantined behavior must be checked on an appropriate host; local copy launch evidence does not establish that acceptance. Publication/upload is a separate explicit action.
