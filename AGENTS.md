# Project Guidance

## Product Boundaries

- `receiver_android` is a native Kotlin Android application with minSdk 24.
- `sender_flutter` is one Flutter application targeting Windows and Android with Android minSdk 26.
- The product is LAN-only and must not require an account, cloud backend, or public-network relay.
- One receiver accepts one active sender. Other senders receive a structured busy response.
- Photos use the photo-explanation flow and are not timed playlist items.
- Screen mirroring is Phase 2 and must not delay the media-playback MVP.

## Architecture Invariants

- UDP is used only for discovery. The sender broadcasts a query and the receiver replies by unicast.
- Certificate-pinned WSS carries versioned control, state, photo-transfer, and recovery messages.
- A sender-local HTTPS Range service exposes local media through opaque IDs. HTTP Range is an internal
  transport choice, not a restriction on accepted media source types.
- The receiver uses Media3 and bounded disk caching. Never load a complete video into memory.
- Playback state and connection state are independent. Cached playback continues after disconnect.
- When cache is exhausted offline, retain the last frame, enter buffering, and resume from the same
  position after recovery.
- Errors and disconnects appear in a slim translucent top banner without resizing the media surface.
- Protocol changes require synchronized fixtures/tests in both applications.

## Quality

- Add explicit timeouts and size limits to sockets, HTTP requests, subprocesses, and waits.
- Prefer bounded queues, backpressure, streaming I/O, and hardware decoding.
- Preserve aspect ratio and never stretch media.
- Treat codec/container support as a negotiated device capability.
- Keep package identifiers under `com.iflytek.lanmediacast`.
- Do not commit SDK paths, signing material, credentials, generated binaries, caches, or local build adaptations.

## Verification

- Run Dart formatting, analysis, and tests for sender changes.
- Run Kotlin unit tests, lint, and Gradle build checks for receiver changes.
- Run protocol fixture tests on both sides for every protocol change.
- Performance claims require device measurements; record device model, network, media profile, and percentile.

## Shell

- Commands run on Windows 11 through PowerShell 7. Use PowerShell syntax.
- New cross-platform text files use UTF-8 without BOM and LF. PowerShell and batch scripts may use CRLF.
- Android Gradle wrapper URLs use the Tencent mirror prefix required by the local environment guidance.
  This is an intentional repository-level build standard, not a local adaptation; pin the distribution
  SHA-256 checksum in the tracked wrapper properties.
