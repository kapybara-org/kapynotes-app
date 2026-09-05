# Contributing

## Getting it running

```
flutter pub get
flutter run          # or: flutter run -d macos
```

Flutter version is pinned in `.github/workflows/desktop-ci.yml`; matching it
locally avoids analyzer differences.

## Before opening a pull request

```
flutter analyze
flutter test
```

Both run in CI on every push and pull request. Windows builds on every branch;
macOS builds too.

The golden tests under `test/goldens/` render with macOS system fonts, so they
only pass on macOS. If you are on Linux or Windows, run
`flutter test --exclude-tags golden` and let CI cover the rest.

## What tends to get merged

Small, self-contained changes with a clear reason. If you are planning
something large, open an issue first — the app has opinions about how it
behaves, and it is easier to talk about a sketch than a finished branch.

## What lives elsewhere

This repository is the client only. The sync backend, the marketing site and
the changelog are in a separate private repository, so:

- Release notes come from the website, not from this repo's releases.
- Anything about server behaviour is best raised as an issue here; we will
  route it.

## Licence

Contributions are accepted under the Apache License 2.0 (see `LICENSE`). By
opening a pull request you agree your work may be released under it.
