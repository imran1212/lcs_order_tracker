# LCS Tracker by AQAS — Google Play pre-submission blockers

## Permanent Android application ID
- Chosen application ID: `pk.aqas.lcstracker`
- Android namespace: `pk.aqas.lcstracker`
- Display name: `LCS Tracker by AQAS`

This ID is intended for the first Play Store listing and must not be changed after publishing.

## Required before a Play-ready build
1. In Firebase Console, open project `lcs-tracker-4c90d` and register a new **Android app** with package name `pk.aqas.lcstracker`.
2. Confirm in Firebase Console that the Android app registered as `pk.aqas.lcstracker` has the same Firebase project ID and Android app ID represented in `android/app/google-services.json`. The repository file currently contains a client entry for the AQAS package; verify it against Firebase Console before release.
3. Verify Authentication providers, Firestore, Storage (if receipt uploads use it), and configuration for the new Android app.
4. Configure a private Android upload keystore in GitHub Actions secrets or Codemagic. Never commit the keystore or passwords.
5. Build and verify a **signed Android App Bundle (.aab)** with the upload key; enable Play App Signing in Play Console.
6. Review and test the repository's new `firestore.rules` against login, orders, receipt storage, sync jobs, and background workers. These rules are committed for review but are **not yet deployed** to the live Firebase project. Do not deploy until emulator/CI checks and admin/worker regression tests pass.
7. Run the full CI workflow and manually test login, admin/worker permissions, receipt capture/OCR, edit/delete, search/status/date filters, Sync All/background sync, return/delivered classification, CSV/JSON export, and reports.
8. Complete Play Console privacy/data safety, app access instructions, content rating, store listing, screenshots, and target API requirements.

## Current known limitations
- The repository's `google-services.json` contains both the legacy package entry and `pk.aqas.lcstracker`; verify the AQAS entry in Firebase Console rather than relying on the file alone.
- CI's APK is for device QA and uses the Android debug signing key. It is **not** a Google Play upload artifact.
- Least-privilege Firestore rules are now tracked in `firestore.rules` and configured by `firebase.json`; they still require emulator validation and deliberate deployment to the correct Firebase project.
- A green CI build is necessary but not sufficient for Play approval; Play Console declarations and live-device acceptance tests remain required.
