# Contributing to SixFingers

Thanks for contributing.

## Development Setup

```bash
swift build
swift build -c release
```

Optional local app bundle build:

```bash
bash packaging/build-app-bundle.sh
```

## Pull Requests

- Keep changes scoped and reviewable
- Include a clear description of behavior changes
- Include manual test steps in the PR description
- Update docs when workflows or commands change

## Coding Expectations

- Target macOS 13+
- Keep menu bar behavior stable and responsive
- Avoid introducing secrets in code, docs, or scripts

## Reporting Issues

When reporting issues, include:

- macOS version
- App path used to launch (`dist` or `/Applications`)
- Permission state for Accessibility and Screen Recording
- Steps to reproduce and expected behavior
