# Code signing & TestFlight from GitHub Actions

Everything here is **optional** and **dormant** until you join the Apple
Developer Program ($99/year). Without it, CI still validates every commit and
produces an unsigned IPA installable via SideStore (see README). With it,
`release.yml` produces signed IPAs and can upload to TestFlight — still with no
Mac: every Apple-specific step below that needs macOS runs on the GitHub runner,
and the certificate can be created from Linux with OpenSSL.

## Overview of the secrets

Set these in **GitHub → repo → Settings → Secrets and variables → Actions**
(or in a protected Environment):

| Secret | What it is |
|---|---|
| `APPLE_CERT_P12_BASE64` | Your distribution certificate + private key (.p12), base64-encoded |
| `APPLE_CERT_PASSWORD` | Password you set when exporting the .p12 |
| `APPLE_PROVISIONING_PROFILE_BASE64` | The .mobileprovision for the app, base64-encoded |
| `APPLE_PROFILE_NAME` | The profile's *name* as shown in the developer portal |
| `APPLE_TEAM_ID` | 10-character Team ID (Membership page) |
| `APPLE_BUNDLE_ID` | e.g. `com.fourmbs.mosslive` (must match the profile) |
| `TEMP_KEYCHAIN_PASSWORD` | Any long random string (protects the throwaway CI keychain) |
| `ASC_API_KEY_ID` | App Store Connect API key ID (TestFlight only) |
| `ASC_API_ISSUER_ID` | App Store Connect issuer ID (TestFlight only) |
| `ASC_API_PRIVATE_KEY` | Contents of the `AuthKey_XXX.p8` file (TestFlight only) |

`release.yml` checks which secrets exist: signing jobs skip when the first
group is missing; the TestFlight job additionally needs the `ASC_*` group and
must be enabled per-run (`workflow_dispatch` input) or runs on version tags.

## 1. Create the distribution certificate (from Linux)

```bash
# private key + certificate signing request
openssl genrsa -out dist.key 2048
openssl req -new -key dist.key -out dist.csr \
    -subj "/emailAddress=you@example.com/CN=Your Name/C=US"
```

Upload `dist.csr` at developer.apple.com → Certificates → **+** →
*Apple Distribution* → download `distribution.cer`, then:

```bash
openssl x509 -inform DER -in distribution.cer -out dist.pem
openssl pkcs12 -export -inkey dist.key -in dist.pem -out dist.p12
# choose a password -> APPLE_CERT_PASSWORD
base64 -w0 dist.p12       # -> APPLE_CERT_P12_BASE64
```

## 2. App ID and provisioning profile

Developer portal → Identifiers → **+** → App ID with your bundle id
(`com.fourmbs.mosslive`) — no special capabilities needed (microphone is not a
provisioned capability). Then Profiles → **+**:

- *App Store Connect* profile (for TestFlight), or *Ad Hoc* (direct device
  installs; add your device UDIDs first).
- Select the App ID and the distribution certificate, name it (that name is
  `APPLE_PROFILE_NAME`), download and:

```bash
base64 -w0 MossLive.mobileprovision   # -> APPLE_PROVISIONING_PROFILE_BASE64
```

## 3. App Store Connect (TestFlight only)

1. appstoreconnect.apple.com → *My Apps* → **+** → New App (bundle id from step 2).
2. *Users and Access → Integrations → App Store Connect API* → generate a
   **Team key** with *App Manager* role. Note the **Key ID** and **Issuer ID**,
   download the `.p8` once, and paste its contents into `ASC_API_PRIVATE_KEY`.

## 4. Run it

```bash
gh workflow run release.yml -f upload_testflight=true   # manual
git tag v1.0.0 && git push --tags                        # or tag-driven
```

What the workflow does, in order: creates a temporary keychain → imports the
.p12 → installs the profile → `xcodebuild archive` (manual signing, build number
= run number) → `-exportArchive` to an IPA → uploads the artifact → uploads to
TestFlight via `xcrun altool --apiKey` → deletes the keychain, profile and API
key in `if: always()` steps. Secret material never appears in logs (the scripts
redact identity dumps and never `set -x`).

## Failure modes

| Error | Cause / fix |
|---|---|
| `security: SecKeychainItemImport: ... invalid password` | `APPLE_CERT_PASSWORD` doesn't match the .p12 |
| `No signing certificate "Apple Distribution" found` | .p12 lacks the private key (re-export with `-inkey`), or the cert expired — renew and update the secret |
| `Provisioning profile ... doesn't match bundle identifier` | `APPLE_BUNDLE_ID` ≠ profile's App ID |
| `Provisioning profile has expired` | Regenerate the profile, re-encode, update the secret |
| altool `401`/`403` | Wrong ASC key/issuer ID, or key lacks App Manager role |
| altool `409` (bundle version already used) | Re-run the workflow (build number = run number, always increments) |
| TestFlight build never appears | Processing takes minutes–hours; check App Store Connect → TestFlight for compliance prompts (this app sets `ITSAppUsesNonExemptEncryption=false`) |

## Reality check

GitHub Actions removes the *Mac*, not Apple's rules: signed device builds and
TestFlight require the paid membership; free Apple IDs cannot use this workflow
(that's what the SideStore path is for); and TestFlight builds are reviewed by
Apple before external testers can install them.
