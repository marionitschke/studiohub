# StudioHub

Three native macOS apps for photos, videos and music, built from one repository and installed side by side in `/Applications/StudioHub`. Each app stays a separate program with its own window, settings and version; they share a little code and a menu to switch between them. Everything runs locally – no Xcode, no Apple developer certificate.

| App | What it does |
| --- | --- |
| [PhotoHub](photohub/README.md) | Finds duplicate photos, sorts Apple Photos exports into year/month folders, fixes file dates from the capture time, syncs photo folders |
| [VideoHub](videohub/README.md) | Trims MOV and MP4 videos: cut, reorder, shift or mute the sound, transitions, titles, logo; export without re-encoding where possible |
| [MusicHub](musichub/README.md) | Cuts long audio recordings into parts on three tracks and exports them as MP3 (320 kbit/s) with tags, chapters and cue sheets |

The apps' interface is in German and always dark: a Darcula look with neutral greys and a grey accent, each app's own color (PhotoHub violet, VideoHub green, MusicHub magenta) marking its primary actions.

## Working together

- **StudioHub** menu in every app: **PhotoHub** ⌃⌘1, **VideoHub** ⌃⌘2, **MusicHub** ⌃⌘3 bring the other app to the front and launch it if needed.
- **Originalton in MusicHub öffnen** (open the original sound in MusicHub) in VideoHub's **Ablage** (file) menu hands the video to MusicHub.

## Installation

**Requirements:** the Command Line Tools (`xcode-select --install`) and LAME from Homebrew for VideoHub and MusicHub. PhotoHub runs on macOS 13 or later, VideoHub and MusicHub on macOS 15 or later.

```bash
git clone https://github.com/marionitschke/studiohub.git
cd studiohub
brew install lame
./build.sh --install
```

The apps are then located in `/Applications/StudioHub`; dragging that folder into the Dock puts all three in one place. LAME's static library is linked into the apps, so they do not need Homebrew at runtime. Because they are built on your Mac and signed ad hoc (with Hardened Runtime, so no foreign libraries can be injected), they launch without a Gatekeeper prompt. An app that is running is not replaced – quit it and install again.

- **Update:** `git pull && ./build.sh --install`
- **One app only:** `./build.sh video --install` (`photo`, `video`, `music`)

## Building

```bash
./build.sh                # all apps, each into <app>/build/
./build.sh music          # one app
./build.sh --install      # also installs into /Applications/StudioHub
./build.sh --icon         # redraws the app icons
./build.sh --check        # runs the checks of VideoHub and MusicHub in temporary folders
```

Each app also builds on its own with `<app>/build.sh`; the steps they share are in `shared/build-common.sh`.

## Structure

| Path | Contents |
| --- | --- |
| `photohub/`, `videohub/`, `musichub/` | The apps: sources, resources, icon script, checks, README |
| `shared/MP3Encoder.swift` | LAME encoder (VideoHub, MusicHub) |
| `shared/CLame/` | Module map for LAME's header |
| `shared/StudioApps.swift` | The list of apps, opening another app, the StudioHub menu for AppKit (PhotoHub) |
| `shared/StudioCommands.swift` | The StudioHub menu for SwiftUI (VideoHub, MusicHub) |
| `shared/Darcula.swift` | The Darcula colors, each app's main color, grey accent and dark appearance (all apps) |
| `shared/DarculaSwiftUI.swift` | Darcula window background and primary buttons for SwiftUI (VideoHub, MusicHub) |
| `shared/build-common.sh` | Compiler flags, LAME, bundling, ad hoc signing with Hardened Runtime, installing |

## License note

MP3 encoding uses [LAME](https://lame.sourceforge.io) (LGPL-2.0-or-later), linked statically from Homebrew.
