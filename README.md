# SixFingers

SixFingers is a macOS menu bar app that turns image prompts into mouse-driven drawings in your active drawing app.

## Features

- Menu bar workflow with quick draw actions
- Prompt input by text, image selection, or microphone
- Area picker so we can draw inside a selected region
- Configurable AI provider and model settings

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- Swift 5.9 toolchain

## Quick Start

```bash
swift build -c release
bash packaging/build-app-bundle.sh
open dist/SixFingers.app
```

## Runtime Permissions

SixFingers needs these macOS permissions:

- Accessibility, so we can control mouse events for drawing
- Screen Recording, when capture or picker flows need screen content

If drawing does not start, confirm both permissions are enabled for the same app path you launched.

## Build Artifacts

- App bundle: `dist/SixFingers.app`
- Installer DMG: `dist/SixFingers.dmg`

Build DMG:

```bash
bash packaging/build-dmg.sh
```

## Code Structure

- App source: `Sources/SixFingers/`
- Assets: `Resources/`
- Packaging scripts: `packaging/`

## Contributing

See `CONTRIBUTING.md` for development and pull request guidelines.

## License

This project is licensed under the MIT License. See `LICENSE`.
