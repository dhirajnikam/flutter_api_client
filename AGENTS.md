# Agent notes

## Checks (the same ones CI runs)

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
dart run lakos -o /dev/null lib      # non-zero exit on an import cycle
(cd example && dart run build_runner build --delete-conflicting-outputs \
  && git diff --exit-code -- lib && flutter test)
```

## Import direction under `lib/src`

A folder may import only folders to its left:

```
core ← http ← interceptors (and its sub-folders) ← auth ← client ← graphql, offline
spec → http only        gen → nothing        websocket → nothing
```

- `lib/flutter_api_client.dart` is the only public library. It exports from every
  folder; nothing under `lib/src` may import it.
- Shared types go in the lowest folder all their users can reach (usually `core/`).

## Things that are not obvious

- `pubspec.yaml` must keep working on old and new dependencies: `build` spans two
  majors (`>=4.0.6 <6.0.0`). After touching dependencies, run the checks under
  both `flutter pub upgrade` and `flutter pub downgrade`.
- CI runs Flutter 3.44.5 on purpose, as the older-SDK check. Do not use APIs or
  packages that need a newer Flutter (the example keeps `material.dart` for this).
- `example/lib/*.g.dart` are generated and checked in; CI fails if they drift.
- `doc/` is excluded from the published package (`.pubignore`).
