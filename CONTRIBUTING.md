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

CI analyzes every pull request and every push to main and release/**. The
whole suite runs in CI when a maintainer runs the Suite workflow on a branch
in this repository from the Actions tab. It runs on Linux, so it leaves golden
mismatches to the Goldens workflow below and expects the failures listed in
`tool/ci/linux-baseline.tsv`, the tests that assume a macOS host. Any other
failure fails it.

The golden tests under `test/goldens/` render with macOS system fonts, so they
only pass on macOS. CI runs them on a macOS runner (the Goldens workflow) for
every pull request. When a change is meant to alter an image, a maintainer
runs that workflow on its branch in this repository from the Actions tab. It
re-renders the goldens there and returns the images that changed, or commits
them to the branch if `commit` is ticked.

The phone integration tests, `integration_test/phone_v2_test.dart` and
`phone_format_bar_test.dart`, take screenshots as they go. To see them, a
maintainer adds the `phones` label to a pull request, or runs the Phones
workflow on its branch from the Actions tab. It runs the tests on an Android
emulator and an iOS simulator and uploads the screenshots as the
`android-screenshots` and `ios-screenshots` artifacts.

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
