# Architecture and repository layout

```mermaid
flowchart LR
    A["Echo on the iPad<br/>SwiftUI · AVAudioEngine · Opus"]
    B["Your machine<br/>FastAPI · Qwen3-ASR"]
    C["ChatGPT (Codex CLI)<br/>or Gemini (Antigravity CLI)"]
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
  Audio/                     AVAudioEngine capture, Opus streaming encoder
  Network/                   wire protocol, WebSocket client with resume + backlog
  Model/                     app state machine, settings, stores
  Views/                     SwiftUI: transcript, lessons, chat, library
Sources/MossLiveWidget/      Home and Lock Screen answer widget
LocalPackages/OpusShim/      C shim over libopus (SPM)
Tests/MossLiveTests/         unit tests
.github/workflows/           lint (ubuntu) · ci (macOS) · release
```
