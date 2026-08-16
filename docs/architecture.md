# Architecture and repository layout

```mermaid
flowchart LR
    A["Echo on the iPad<br/>SwiftUI · AVAudioEngine · Opus"]
    B["Your machine<br/>FastAPI · Qwen3-ASR"]
    C["ChatGPT (Codex CLI)<br/>Claude (Claude Code CLI)<br/>or Gemini (Antigravity CLI)"]
    D["WebUntis"]
    A -- "WebSocket over Tailscale<br/>audio up · transcript down" --> B
    A -- "REST: lessons and books" --> B
    B -- "summaries · chat" --> C
    B -- "timetable" --> D
```

## Repository layout

```
project.yml                  XcodeGen project definition (the real project file)
Sources/MossLive/
  Audio/                     AVAudioEngine capture, Opus encoder, local safety recording
  Network/                   wire protocol, WebSocket client with resume + disk backlog
  Model/                     app state machine, settings, stores
  Notes/                     Goodnotes/Notability/PDF import, parsed on the iPad
  Views/                     SwiftUI: transcript, lessons, learn, library, chat
  Testing/                   deterministic fixtures for -UITesting launches
Sources/Shared/              settings and share-inbox types used by every target
Sources/MossLiveWidget/      Home and Lock Screen answer widget
Sources/EchoShareExtension/  share sheet target that queues documents for a lesson
LocalPackages/OpusShim/      C shim over libopus (SPM)
Tests/MossLiveTests/         unit tests
Tests/MossLiveUITests/       XCUITest suite driven against the mock backend
.github/workflows/           lint (ubuntu) · ci (macOS) · ui-tests · screenshots · release
```
