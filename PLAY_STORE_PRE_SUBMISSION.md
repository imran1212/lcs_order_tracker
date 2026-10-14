# LCS Tracker by AQAS — Google Play pre-submission blockers

## Permanent Android application ID
- Chosen application ID: `pk.aqas.lcstracker`
- Android namespace: `pk.aqas.lcstracker`
- Display name: `LCS Tracker by AQAS`

This ID is intended for the first Play Store listing and must not be changed after publishing.

## Required before a Play-ready build
1. In Firebase Console, open project `lcs-tracker-4c90d` and register a new **Android app** with package name `pk.aqas.lcstracker`.
2. Download the new app's `google-services.json` and replace `android/app/google-services.json`. Do not edit the old app's package name by hand: Firebase must issue a real app ID for this package.
3. Verify Authentication providers, Firestore, Storage (if receipt uploads use it), and configuration for the new Android app.
4. Configure a private Android upload keystore in GitHub Actions secrets or Codemagic. Never commit the keystore or passwords.
5. Build and verify a **signed Android App Bundle (.aab)** with the upload key; enable Play App Signing in Play Console.
6. Review and test Firestore rules against login, orders, receipt storage, sync jobs, and background workers. Do not loosen rules just to silence permission errors.
7. Run the full CI workflow and manually test login, admin/worker permissions, receipt capture/OCR, edit/delete, search/status/date filters, Sync All/background sync, return/delivered classification, CSV/JSON export, and reports.
8. Complete Play Console privacy/data safety, app access instructions, content rating, store listing, screenshots, and target API requirements.

## Current known limitations
- The repository's existing `google-services.json` is registered to `com.example.lcs_order_tracker`; it is not valid proof of Firebase registration for `pk.aqas.lcstracker`. Replace it through Firebase Console.
- CI's APK is for device QA and uses the Android debug signing key. It is **not** a Google Play upload artifact.
- Firestore rules are not tracked in this repository. Review and deploy rules separately after testing.
- A green CI build is necessary but not sufficient for Play approval; Play Console declarations and live-device acceptance tests remain required.
