#!/bin/bash
# Remove the temporary signing keychain and installed profiles.
# Runs in `if: always()` so secrets never outlive the job, even on failure.
set -uo pipefail

KEYCHAIN_PATH="$RUNNER_TEMP/mosslive-signing.keychain-db"
if [ -f "$KEYCHAIN_PATH" ]; then
    security delete-keychain "$KEYCHAIN_PATH" && echo "temporary keychain deleted"
fi
rm -f "$RUNNER_TEMP/cert.p12" "$RUNNER_TEMP/profile.mobileprovision"
rm -rf "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision 2>/dev/null
rm -rf "$HOME/private_keys" 2>/dev/null
exit 0
