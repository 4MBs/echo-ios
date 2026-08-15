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

## Simulator workflows

Two manual-dispatch workflows drive a simulator on a macOS runner:

- **Exhaustive iOS Simulator UI Tests** (`ui-tests.yml`) runs the XCUITest suite
  against the app's deterministic mock backend (`-UITesting`), on an iPad Pro 13"
  by default. It uploads the test log, screen recordings and per-test
  screenshots, which is what actually explains a failure.
- **Documentation Screenshots** (`screenshots.yml`) boots one simulator, launches
  the app in each mock state, photographs it, and shuts the simulator down again.
  The images in `docs/screenshots/` come from there rather than from a phone.

Both are `workflow_dispatch` only — simulator minutes are expensive and neither
gates a push.

## Codemagic

[`scripts/ci/codemagic.sh`](../scripts/ci/codemagic.sh) drives a macOS build on
Codemagic instead, for when GitHub Actions is unavailable.
