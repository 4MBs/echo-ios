# Building and CI

This app is developed entirely from Linux, which is the most unusual thing about
the repository and the reason it is laid out the way it is.

There is no `.xcodeproj` checked in. [`project.yml`](../project.yml) is the real
project file, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates the
Xcode project on a GitHub-hosted macOS runner, which then builds, tests and
uploads an IPA artifact. Nothing about editing the app requires a Mac; only
compiling it does, and that is rented by the minute.

```bash
$EDITOR Sources/MossLive/...   # edit Swift in any editor
git push                       # a macOS runner builds and tests
gh run watch                   # collect the IPA artifact
```

## Linting

Style is gated on every push by SwiftLint and SwiftFormat, on Ubuntu runners
because macOS minutes bill at ten times the rate. Both run locally through
Docker, which is worth doing before pushing:

```bash
docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/realm/swiftlint:0.57.1 swiftlint
```

## On a Mac

```bash
brew install xcodegen && xcodegen generate && open MossLive.xcodeproj
```

## Codemagic

[`scripts/ci/codemagic.sh`](../scripts/ci/codemagic.sh) drives a macOS build on
Codemagic instead, for when GitHub Actions is unavailable.
