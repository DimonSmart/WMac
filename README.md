# WMac!

Native Swift/AppKit taskbar for macOS 14+. The default runtime now displays one nonactivating panel per connected display, saved pins and real process buttons, exact-instance switching and menus, independent launch requests, horizontal overflow, clock/date and persistent WMac menu bar controls. This is an **intermediate development build**, not the completed MVP. Persistent native settings and explicit login registration controls are implemented; local universal DMG preparation is implemented. Pin gestures are implemented; actual Finder-drop acceptance and the broader accessibility/display matrix still need manual verification.

## Install, update, and switch between builds

From a checkout of the official repository (Xcode command line tools and Python 3 required):

```sh
./scripts/install.sh       # download, verify, install stable GitHub release, then launch
./scripts/run.sh release   # launch exactly ~/Applications/WMac.app
./scripts/run.sh           # build and launch local Debug (run signing setup once first)
```

For a fresh checkout:

```sh
git clone https://github.com/DimonSmart/WMac.git
cd WMac
./scripts/install.sh
```

The installer reads the latest stable GitHub release, verifies its GitHub SHA-256 and the packaged application, and installs into `~/Applications/WMac.app`. A previous installation is retained in `~/Applications/.WMacPrevious.*/WMac.app`. It preserves macOS quarantine and trust settings; ordinary first-launch approval may be required. Repeat the install command to install the latest official release, or use **Check for Updates…** and **Automatically check for updates** in the installed application's menu. Background checks run on launch and daily; installing an offered update requires your action.

If an update started by WMac 0.2.0 or 0.2.1 has installed the new files but remains on “Updating WMac”, the old process may be stuck during exit. After its data save and Dock restoration, quit that stuck WMac process using Activity Monitor, then run `./scripts/run.sh release`. Version 0.2.2 fixes this termination deadlock for subsequent updates. The command-line installer is also available for manual upgrades.

Version 0.2.3 adds Finder to the searchable application catalog, independent-instance launch from search results, and per-window close controls in previews.

If window minimization does not work after installing or updating, open Settings → Permissions in WMac and check Accessibility. The first window action without access shows a nonmodal explanation with an **Open Settings…** button, once per launch. Enable the currently installed WMac in macOS Privacy & Security → Accessibility; a previous build's grant may not cover an updated ad-hoc signed build. Process switching remains available without that permission.

Both launch commands gracefully quit other running WMac copies and wait for their settings save and Dock restoration before opening the exact selected path. Local Debug displays **L** beside its menu bar symbol and on the application icon. About shows Debug/Release, version/build and the actual bundle path. A Release build in `.build/` is still a local artifact; its path identifies it. The two modes share settings, pins, and bundle identity. Use one at a time. Plain `open -a WMac` can select an unintended registered copy; use these explicit commands.

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

Click a running button to switch to its exact process and last available active window. Shift-click or middle-click requests an independent process of the exact application URL. Right-click for windows and process actions; force termination requires confirmation. Idle pins use ordinary launch. Drop GUI `.app` bundles from Finder onto a panel to pin them; drag pinned buttons to persist their order. Process menus offer Pin/Unpin. The WMac menu’s Pinned applications submenu also offers Unpin and Move left/right, plus a native replacement picker for missing apps. Failed storage preserves the original file and visible state; use Retry pins after correcting access or restoring a valid file. The left Applications button opens a native searchable catalog that includes Finder. Type a name, use Up/Down and Enter to open the exact selected bundle, Escape to dismiss, or Tab into results and Shift-F10 (or right-click) → Launch New Instance or Pin. Menu-bar apps can be launched but not pinned. The list refreshes asynchronously on opening and through Refresh; loading, empty and no-match states are explicit. Search works for unpinned applications too. Orange indicators and accessible pending counts track independent requests; error/unconfirmed details are available in the WMac menu. Menu bar and panel controls provide Settings (Cmd-comma), manual hide/show, instructions, permission status/settings, Dock settings and Quit. Closing an information window leaves this route available. Reopening WMac also restores hidden panels.

**Window previews (IDD-0010).** Hover over a running app button for 450 ms to see its window cards: the default Automatic mode opens when at least one manageable window is available, and Disabled suppresses the automatic popup. Per-app Always overrides can enable previews while the global mode is disabled. Choose **Show windows…** from the right-click menu regardless of the hover mode. Select a card (or an entry under Windows) to restore and activate that exact AX window. Use a card’s close button to close that exact window when Accessibility exposes its close button; this does not request process termination. The popup supports Escape, keyboard navigation and VoiceOver; missing capture permissions never prevent choosing an AX window. The standard button tooltip is hidden while the popup is displayed. A card without an identifiable or capturable image retains its title and shows a placeholder.

Use Settings → **Window Previews** to select the global hover mode, turn real thumbnails on/off, and override hover behavior by application (across its instances). Thumbnails use ScreenCaptureKit single-frame captures and require a separate permission under System Settings → Privacy & Security → Screen & System Audio Recording. Click **Allow window thumbnails…** in settings or the popup to request it; macOS may require restarting WMac after approval. WMac never captures windows merely on mouse movement and never stores or uploads frames. On permission denial, protected/minimized windows or ambiguous AX-to-graphics matching, placeholders are intentional. If Accessibility is unavailable, explicit Show windows explains the limitation, and ordinary PID-based taskbar switching remains available. The persisted settings schema is v4 (migrates v1–v3 without discarding pins).

The system Dock remains installed and running. By default WMac leaves its preferences untouched. General → **Hide system Dock while WMac runs** is a separately confirmed, opt-in feature: it temporarily sets only the current-user Dock `autohide`, `autohide-delay` and `autohide-time-modifier` preferences, with a one-shot crash watchdog. It restores the original values (including absent keys) on disable, manual panel hiding or normal exit, and tries recovery on the next WMac launch after a power failure. External preference changes are preserved. The menu includes **Restore system Dock** while an active transaction needs recovery. The snapshot is stored independently at `~/Library/Application Support/WMac/SystemDockVisibilityState.plist`; if that file is damaged, WMac does not guess original values and manual restoration via Desktop & Dock may be necessary. The long autohide delay is not an absolute guarantee against seeing Dock. No administrator privileges, Terminal or Accessibility grant are needed. Panels use public all-Spaces behavior with fullscreen participation disabled; actual multi-display/fullscreen behavior needs the manual matrix below.

For per-window identity diagnostics, launch the ordinary WMac runtime with `open .build/products/Debug/WMac.app --args --window-diagnostics` (after quitting WMac). Inspect local unified logs with `log stream --style compact --predicate 'subsystem == "app.wmac.WMac" && category == "WindowPreviews"'`. The opt-in messages include per-window AX lifecycle/revision, candidate graphics IDs, structured rejection reasons, cache/capture status and timing; window titles are redacted by default. To include titles during explicit investigation, launch the executable with `WMAC_WINDOW_DIAGNOSTICS=1 WMAC_WINDOW_DIAGNOSTICS_TITLES=1 .build/products/Debug/WMac.app/Contents/MacOS/WMac`. No images are written to logs.

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
./scripts/release.sh               # default version 0.2.3, build 5
./scripts/release.sh 0.1.1 2       # explicit numeric major.minor[.patch], positive build
```

This local command needs Xcode and the macOS tools above, with no credentials, certificate or network operations. Each invocation builds only WMac into a fresh `.build/distribution/release-VERSION-BUILD.XXXXXX/` directory. It retains `WMac-VERSION-BUILD.dmg`, relative `SHA256.txt`, build and verification logs, and `AUTOMATED-CHECKS-PASSED.txt` after successful checks. Failures exit nonzero and produce no success marker; an image awaiting verification has an `.unverified.dmg` suffix. Products and intermediates remain outside the image. The DMG contains WMac.app (including its universal, individually signed Contents/Helpers/WMacDockWatchdog) and an Applications link.

The command verifies both executable slices, macOS 14.0 deployment metadata, identity `app.wmac.WMac`, RU/EN WMac! names, requested versions, the actual ad-hoc signature, Hardened Runtime and absence of debug entitlements. It checks image integrity, mounts the actual DMG read-only, checks its payload/link and re-verifies the contained app. To repeat checks:

```sh
./scripts/verify-release-dmg.sh /absolute/path/WMac-0.1.0-1.dmg 0.1.0 1
cd /absolute/path/to/output
shasum -a 256 -c SHA256.txt
```

Open the DMG in Finder and drag WMac.app onto Applications. Eject the image and open WMac! from Applications. This MVP uses local ad-hoc signing; it has no trusted Developer ID signature, notarization or stapling. macOS may block a downloaded unnotarized app and require its ordinary first-launch approval in System Settings → Privacy & Security → Open Anyway, if available, followed by confirmation. A seamless first double-click on every Mac is not guaranteed. Only approve an app you trust; WMac never changes Gatekeeper, quarantine or system trust. After a system-permitted launch, ordinary use needs no Terminal. Downloaded/quarantined behavior must be checked on an appropriate host; local copy launch evidence does not establish that acceptance. Preparing the local DMG does not upload it; publishing is triggered by pushing a release tag as described below.

## Publish a stable GitHub Release

Run `pwsh ./publish-next-version.ps1` from a clean checkout to publish. The script fetches tags, fast-forward updates `main`, calculates the next patch version, updates both Xcode `MARKETING_VERSION` settings and the build number, commits the version metadata, creates an annotated `vMAJOR.MINOR.PATCH` tag, and atomically pushes `main` and the tag. It requires Git access to `origin` and PowerShell (`pwsh`). Defaults are `origin`, `main`, and first version `0.1.0`; `-Remote`, `-Branch`, and `-FirstVersion` can be overridden. The `v` tag prefix is fixed because the release workflow and update clients require it. If the push fails and the remote confirms the tag is absent, the local tag is removed while the metadata commit is kept for retry. If the remote tag status cannot be confirmed, inspect the local and remote tags before retrying.

The pushed tag starts the `Release` workflow. It checks that the tag and project versions match, builds the app and test fixture, runs the model tests, then uses `scripts/release.sh` to build and verify the universal DMG. It creates or updates the GitHub Release with exactly one `WMac-VERSION-BUILD.dmg` and `SHA256.txt`; reruns replace the package and remove stale WMac DMG assets. Release notes include the changes and the ad-hoc signing notice. The local preparation command above remains offline and does not publish anything.


WMac checks stable GitHub Releases in the background on launch and daily (Release builds only). Use **Check for Updates…** in the WMac menu to check manually, or disable **Automatically check for updates**. Installation requires your confirmation and a writable `/Applications/WMac.app` or `~/Applications/WMac.app`; other locations offer the release page. Updates use the release DMG and SHA-256 digest supplied by the [GitHub Releases API](https://docs.github.com/en/rest/releases/releases). The release workflow publishes one `WMac-*.dmg` asset per stable release, with a tag matching its marketing version (for example `v0.2.4`). Missing or invalid digests disable installation.

The updater verifies the image checksum, bundle signature, identity, version and minimum macOS version before replacement, preserves settings and pins, and restarts after the previous process has saved data and restored Dock. A hidden `.WMacPrevious-*.app` next to the installed app is retained for manual recovery and can be removed after a successful update. macOS may require launch approval and renewed Accessibility permission after an ad-hoc signed update; WMac does not remove quarantine or change system trust. Full installation/relaunch acceptance must be checked on a disposable installed copy with a newer published release.
