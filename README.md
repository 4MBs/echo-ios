# Echo

Echo is an iPad app for school: it transcribes lessons live, keeps a searchable
archive of them, and holds your schoolbooks. All of it runs against a backend on
a machine you own — there is no cloud and no account.

The iPad records, displays and asks. Your machine transcribes, stores and
answers. The interface is in German.

<p align="center">
  <img src="docs/screenshots/recording.png" width="880" alt="Recording in progress: the sidebar on the left, the waveform and stop button in a bar at the bottom, and the AI answer note in the top right corner">
</p>

## "Wait, what are you selling me?"

Nothing. Echo is not on the App Store, has no hosted mode, and does nothing on
its own. Without the companion backend and a working
[Tailscale](https://tailscale.com) connection to it, the app is an empty shell.

It was built for one student on one iPad, and the code is here so you can read
it, fork it, or point it at your own server.

## Installation

> [!WARNING]
> Echo needs three things before it can do anything. Set them up first:
>
> - **A GPU machine** — Linux or Windows with an NVIDIA or AMD card, running the
>   companion backend. Transcription happens there; it decides how fast text
>   appears. On CPU, text arrives too late to be worth reading.
> - **Tailscale** — an account with the iPad and that machine in the same
>   tailnet. Install the [iPad app](https://apps.apple.com/app/tailscale/id1470499037)
>   and keep it connected while using Echo.
> - **An iPad on iPadOS 26+** and a way to sideload an IPA (SideStore, AltStore,
>   or your own developer account).
>
> A WebUntis account is optional and enables the timetable features. Those
> credentials live on your server, never on the iPad.

Build the IPA (see [Building](#building), or grab the artifact from a CI run) and
sideload it. On first launch Echo opens its settings: server address, port
(`8787` by default) and auth token, all documented in
[`Config.example.plist`](Config.example.plist).

Point the backend's `[library] dir` at the folder holding your schoolbook PDFs if
you want the Bibliothek tab to have anything in it.

## Building

There is no `.xcodeproj` checked in. [`project.yml`](project.yml) is the real
project file, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates the
Xcode project on a GitHub-hosted macOS runner, which builds, tests and uploads an
IPA artifact. Editing the app requires no Mac; only compiling it does.

```bash
$EDITOR Sources/MossLive/...   # edit Swift in any editor
git push                       # a macOS runner builds and tests
gh run watch                   # collect the IPA artifact
```

With a Mac, `brew install xcodegen && xcodegen generate && open
MossLive.xcodeproj` behaves exactly as you would expect.

Details, including linting locally through Docker and the Codemagic fallback, are
in [docs/building.md](./docs/building.md).

## Some notes

- **It is not usable without a server.** If the machine at home is off, the app
  has nothing to talk to.
- **It is not multi-user.** One person, one tailnet, one set of lessons.
- **It is not localised.** The interface is German throughout.
- **It is not distributed.** No App Store, no TestFlight, no signed builds.
  Re-signing is on you.

## Documentation

There's no docs site. The written-out version of everything above lives in
[docs/](./docs).

- [What Echo does](./docs/features.md) — live transcription, the lesson archive,
  chat, the schoolbook reader
- [Building and CI](./docs/building.md) — developing an iOS app from Linux
- [Architecture and repository layout](./docs/architecture.md)

## Credits

Audio goes through [libopus](https://opus-codec.org) and
[swift-opus](https://github.com/alta/swift-opus), BSD-3-Clause.

## License

See [LICENSE](LICENSE).
