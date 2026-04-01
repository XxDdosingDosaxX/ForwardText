# Forward Text

Free, open-source iOS app that automatically forwards your text messages to email.

## How it works
1. The app provides a **Shortcuts Action** called "Forward Message"
2. You set up an iOS Shortcuts automation triggered by incoming messages
3. With "Run Immediately" enabled, messages are forwarded silently in the background
4. Uses Gmail API to send emails — no external servers, everything stays on your device

## Setup
1. Install via TestFlight
2. Open the app, enter your email address
3. Configure Gmail API credentials (one-time setup)
4. Follow the in-app guide to set up the Shortcuts automation
5. Done — texts auto-forward to your email silently

## Building
The app builds automatically via GitHub Actions on push to `main`.
Requires Apple Developer account secrets configured in GitHub.

## Required GitHub Secrets
- `BUILD_CERTIFICATE_BASE64` — Apple distribution certificate (.p12, base64 encoded)
- `P12_PASSWORD` — Password for the .p12 certificate
- `BUILD_PROVISION_PROFILE_BASE64` — Provisioning profile (base64 encoded)
- `KEYCHAIN_PASSWORD` — Any password for the temporary keychain
- `PROVISIONING_PROFILE_NAME` — Name of the provisioning profile
- `TEAM_ID` — Apple Developer Team ID
- `APP_STORE_CONNECT_API_KEY_ID` — App Store Connect API Key ID
- `APP_STORE_CONNECT_ISSUER_ID` — App Store Connect Issuer ID
- `APP_STORE_CONNECT_API_KEY_BASE64` — API Key .p8 file (base64 encoded)
