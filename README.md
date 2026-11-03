# ChatGPT Navigator

A native macOS sidebar for navigating prompts in the ChatGPT desktop app and exporting selected replies to Markdown, Word, or PDF.

This source snapshot is version **0.10.1, build 24**, for **Apple silicon Macs running macOS 14 or later**. It is an independent project and is not affiliated with OpenAI.

## Features

- Read prompts through macOS Accessibility and navigate to selected entries.
- Index older prompts and keep their order while moving through long conversations.
- Select replies for export, with editable equations in Word documents.
- Cancel active work and reconnect when the target conversation changes or Accessibility becomes unavailable.

Build 24 includes a fallback for missing renderer Accessibility content. Recovery and navigation depend on what the installed ChatGPT app exposes; compatibility with every ChatGPT version is not guaranteed.

## Requirements

- macOS 14+ on Apple silicon.
- Xcode or Command Line Tools providing Swift 6.1 or later.
- The ChatGPT desktop app for live navigation.
- Pandoc **3.13** for arm64 macOS, supplied locally before building the app or running converter tests.

No API key is required by this source snapshot. It communicates with the running app through macOS Accessibility.

## Build from source

1. Download or clone this repository.
2. Obtain the arm64 macOS build of [Pandoc 3.13 from its official release](https://github.com/jgm/pandoc/releases/tag/3.13). Install the package, or extract its ZIP and locate the `pandoc` executable.
3. In Terminal, open this project directory and run:

```sh
# If pandoc is installed and available in your PATH:
./Scripts/setup_pandoc.sh

# Alternatively, provide the downloaded executable explicitly:
./Scripts/setup_pandoc.sh /path/to/pandoc

./build_app.sh
```

The setup command checks the converter version and architecture, then copies it to `AppResources/Tools/pandoc`. This local file is intentionally ignored by Git: the original converter is about 195 MB. It is not included in this source folder.

`build_app.sh` creates and ad-hoc signs `ChatGPT Navigator.app` in this directory. It bundles the converter and its notices. It does not install or launch the app. The script replaces a previous generated app at that same path. Ad-hoc signing is for local development; this script does not perform notarization.

The package is defined by `Package.swift`; there is no separate `.xcodeproj` to upload. The original icon asset and icon packaging helper are retained, although the current build script does not install a custom icon.

## Run

Open the generated app and grant access in **System Settings → Privacy & Security → Accessibility** when requested. Open a conversation in ChatGPT and allow the sidebar to connect. Use **Stop navigation** to cancel active work or **Reconnect** to rediscover the conversation.

The app reads on-screen conversation content, uses clipboard/input operations for capture and navigation, and can write exports and diagnostics locally. Review exported files and diagnostics before sharing them; they can contain conversation text.

## Tests

Prepare Pandoc first, then run:

```sh
swift test --skip rendersPaginatedPDF
```

This runs the automated suite while skipping the WebKit PDF rendering test that needs a working graphical session. To include that test on a suitable Mac, run `swift test`.

The public test fixtures are synthetic. Live ChatGPT navigation, renderer recovery, Accessibility permissions, and GUI PDF rendering require manual verification on the target system.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/ChatGPTNavigator/` | Swift application source |
| `Tests/ChatGPTNavigatorTests/` | Regression tests and synthetic fixtures |
| `Package.swift` | Swift package and test target configuration |
| `AppResources/Info.plist` | Bundle identity, version, system requirements, permission description |
| `AppResources/AppIcon.png` | Existing icon asset |
| `AppResources/Tools/` | Pandoc attribution and license; locally prepared converter is ignored |
| `ThirdPartySource/` | Original corresponding Pandoc 3.13 source distribution |
| `Scripts/` | Converter setup and existing icon packaging helper |
| `build_app.sh` | Local app build and signing script |

## Third-party components and licensing

Pandoc is by John MacFarlane and contributors. Its GPL-2.0-or-later license and attribution are retained in `AppResources/Tools/`, and its source distribution is retained at `ThirdPartySource/pandoc-3.13.tar.gz`. See [Pandoc's upstream project](https://github.com/jgm/pandoc/tree/3.13) and the bundled license for its terms.

No license has been selected for the Navigator project's own code. No project-wide reuse permission is granted by this README. A project license should be selected by the owner before presenting this as an open-source release.
