#!/bin/bash
# Import Apple signing material from GitHub Secrets into a temporary keychain.
# Runs only on macOS CI. Never echoes secret material. Pair with
# cleanup_keychain.sh in an `if: always()` step.
#
# Required environment (from GitHub Secrets):
#   APPLE_CERT_P12_BASE64        base64 of the .p12 (distribution or development cert)
#   APPLE_CERT_PASSWORD          password protecting the .p12
#   APPLE_PROVISIONING_PROFILE_BASE64  base64 of the .mobileprovision
#   TEMP_KEYCHAIN_PASSWORD       any random string for the throwaway keychain
set -euo pipefail

: "${APPLE_CERT_P12_BASE64:?missing}"
: "${APPLE_CERT_PASSWORD:?missing}"
: "${APPLE_PROVISIONING_PROFILE_BASE64:?missing}"
: "${TEMP_KEYCHAIN_PASSWORD:?missing}"

KEYCHAIN_PATH="$RUNNER_TEMP/mosslive-signing.keychain-db"
CERT_PATH="$RUNNER_TEMP/cert.p12"
PROFILE_PATH="$RUNNER_TEMP/profile.mobileprovision"

echo "::group::Create temporary keychain"
security create-keychain -p "$TEMP_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 1800 "$KEYCHAIN_PATH"
security unlock-keychain -p "$TEMP_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
echo "::endgroup::"

echo "::group::Import certificate"
echo -n "$APPLE_CERT_P12_BASE64" | base64 --decode > "$CERT_PATH"
security import "$CERT_PATH" -P "$APPLE_CERT_PASSWORD" -A \
    -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple: -k "$TEMP_KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" > /dev/null
rm -f "$CERT_PATH"
echo "::endgroup::"

echo "::group::Install provisioning profile"
PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
echo -n "$APPLE_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"
UUID=$(security cms -D -i "$PROFILE_PATH" | plutil -extract UUID raw -o - -)
cp "$PROFILE_PATH" "$PROFILES_DIR/$UUID.mobileprovision"
rm -f "$PROFILE_PATH"
echo "installed provisioning profile $UUID"
echo "profile_uuid=$UUID" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "::endgroup::"

echo "signing identities available:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed 's/) .*"/) [redacted] "/'
