# Automatic app updates

MobileStudio now follows SleepStudio's startup update flow: it checks GitHub Releases automatically and offers a **Download and update** dialog when a newer version is found. It also checks every six hours while foregrounded, and on resume when the last check is at least six hours old. Each release is prompted once per app launch. Offline/API errors are silent; the existing manual Update toolbar and Settings → Check Updates remain available.

Automatic prompts appear only on the dashboard, while the app is foregrounded and no recording or updater dialog is active. Availability remains badged while a module is open. A pending prompt appears after returning from a module or when a recording ends on the dashboard. Checks do not download or install anything by themselves.

Installation uses the existing platform updater: APK installer confirmation on Android, app replacement and restart on macOS, and ZIP replacement/restart on Windows. Recording checks cover both manual entry points and installation after download. If recording begins during download, installation is deferred; after stopping it, **Install and restart** reuses the downloaded package. GitHub-provided SHA-256 digests are verified when present; the UI does not claim checksum verification when no digest was supplied.

## Distribution prerequisite

The updater reads `arunsasidharan84/CCS_MobileStudio`'s latest **published GitHub release**, not Firebase App Distribution. Firebase-only deployment does not make an in-app update discoverable. No release was published as part of this implementation.

The existing `.github/workflows/desktop-release.yml` builds macOS/Windows/Android assets and publishes tag `v<pubspec version>` when `pubspec.yaml` is pushed to main, or when manually dispatched. For each subsequent update, increment `version:` including the build number in `pubspec.yaml`, update release notes, and publish through that workflow. Supported asset names include `CCSMobileStudio-macOS.zip`, `CCSMobileStudio-Windows.zip`, and `CCSMobileStudio-Android.apk`.

Android updates need the same app ID and signing key as the installed app. Configure the existing Android signing secrets for release distribution so APK updates can install over prior versions. macOS release signing/notarization uses the workflow's existing Apple secrets. These platform identities cannot be repaired by an updater after a package has been built with a different identity.

Tests cover check throttling, concurrent/disposed checks, offline behavior, deferred/one-per-release prompts, supported release asset selection and recording-state installation gating. No test replaces or restarts an installed application.
