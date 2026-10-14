# LCS Tracker by AQAS — Google Play pre-submission blockers

## Permanent Android application ID
- Chosen application ID: `pk.aqas.lcstracker`
- Android namespace: `pk.aqas.lcstracker`
- Display name: `LCS Tracker by AQAS`

This ID is intended for the first Play Store listing and must not be changed after publishing.

## Required before a Play-ready build
1. In Firebase Console, open project `lcs-tracker-4c90d` and confirm the **Android app** with package name `pk.aqas.lcstracker` is registered. If it is missing, register it there first.
2. Confirm in Firebase Console that the Android app registered as `pk.aqas.lcstracker` has the same Firebase project ID and Android app ID represented in `android/app/google-services.json`. The repository file currently contains a client entry for the AQAS package; verify it against Firebase Console before release.
3. Verify Authentication providers, Firestore, Storage (if receipt uploads use it), and configuration for the new Android app.
4. Create/retain a private Android upload keystore and configure these GitHub Actions repository/environment secrets: `AQAS_UPLOAD_KEYSTORE_BASE64`, `AQAS_UPLOAD_STORE_PASSWORD`, `AQAS_UPLOAD_KEY_ALIAS`, and `AQAS_UPLOAD_KEY_PASSWORD`. Never commit the keystore or passwords; signing files are excluded by `.gitignore`.
5. Use the manual **Build signed Google Play AAB** workflow after secrets are configured. The Gradle config intentionally fails closed for `bundleRelease` when the upload key is missing; QA APK builds may remain debug-signed.
6. Restrict the Firebase Android API key to the correct Android package and signing certificate where supported, and confirm Firebase Auth providers and Firestore are enabled.
7. Verify the generated **signed Android App Bundle (.aab)** and enable Play App Signing in Play Console.
8. Review and test the repository's new `firestore.rules` against login, orders, receipt storage, sync jobs, and background workers. These rules are committed for review but are **not yet deployed** to the live Firebase project. Do not deploy until emulator/CI checks and admin/worker regression tests pass.
9. Run the full CI workflow and manually test login, admin/worker permissions, receipt capture/OCR, edit/delete, search/status/date filters, Sync All/background sync, return/delivered classification, CSV/JSON export, and reports.
10. Complete Play Console privacy/data safety, app access instructions, content rating, store listing, screenshots, and target API requirements.

## Current known limitations
- The repository's `google-services.json` contains both the legacy package entry and `pk.aqas.lcstracker`; verify the AQAS entry in Firebase Console rather than relying on the file alone.
- CI's APK is for device QA and uses the Android debug signing key. It is **not** a Google Play upload artifact.
- Least-privilege Firestore rules are now tracked in `firestore.rules` and configured by `firebase.json`; they still require emulator validation and deliberate deployment to the correct Firebase project.
- Cloudflare Worker deployment is manual-only in GitHub Actions, so merging this pull request will not automatically change the live proxy.
- A green CI build is necessary but not sufficient for Play approval; Play Console declarations and live-device acceptance tests remain required.
