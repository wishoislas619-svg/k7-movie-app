# K7 Movie App — AGENTS.md

## Stack

- **Framework:** Flutter (SDK `^3.11.1`), Dart
- **State:** Riverpod (`flutter_riverpod` + `StateNotifier`)
- **Backend:** Supabase (url + anonKey hardcoded in `lib/core/services/supabase_service.dart:4-5`)
- **Backend local:** `supabase/config.toml` — edge function at `supabase/functions/secure-video-link/`
- **Ad providers:** Google Mobile Ads + Unity Ads (initialized in `lib/main.dart:61-75`)

## Architecture

Feature-first with clean architecture layers (`data/` → `domain/` → `presentation/`):

| lib/ | purpose |
|---|---|
| `core/` | theme, constants, services (Supabase, TMDB, ads, notifications, foreground, storage, updates) |
| `features/auth/` | login, register, Google Sign-In, admin dashboard, profiles |
| `features/movies/` | movie grid, details, categories, watch history, downloads |
| `features/series/` | series grid, details, episodes |
| `features/player/` | video player page, floating PiP overlay |
| `features/cast/` | Chromecast support |
| `features/tv/` | live TV channels |
| `shared/widgets/` | `EnergyFlowBorder`, `MarqueeText`, `TvFocusWrapper` |

Repositories bridge Supabase via concrete classes suffixed `SupabaseImpl` (e.g. `MovieRepositorySupabaseImpl`). All providers wired in `lib/providers.dart`.

## Key files

| file | role |
|---|---|
| `lib/main.dart` | Entrypoint — loads `.env`, inits Supabase, notifications, ads, permissions, wakelock |
| `lib/providers.dart` | Top-level Riverpod providers for repositories + UI state (`floatingPlayerProvider`, `splashDoneProvider`) |
| `lib/core/services/supabase_service.dart` | Supabase singleton |
| `supabase/functions/secure-video-link/index.ts` | Edge function for secure video URL proxy |
| `setup_cron.sql` | DB cron for VIP subscription expiration |
| `.env` | Contains `OPENSUBTITLES_API_KEY` and `OPENSUBTITLES_CONSUMER_NAME` |

## Commands

```sh
flutter pub get                    # install deps
flutter run                        # run on connected device/emulator
flutter test                       # run tests (smoke test only at test/widget_test.dart)
flutter analyze                    # lint + static analysis (no separate typecheck step)
flutter pub run flutter_launcher_icons  # regenerate app icons after changing pubspec config
flutter pub run flutter_native_splash:create  # regenerate splash screen
```

supabase CLI (for local dev):
```sh
supabase start       # start local Supabase stack
supabase functions serve secure-video-link  # serve edge function locally
supabase db push     # push migrations
```

## Gotchas

- **`.env` is required at project root** — loaded by `flutter_dotenv` in `main.dart:48`. Missing it crashes startup.
- **Supabase URL and anonKey are hardcoded** in `supabase_service.dart` — do not move them to `.env` without changing all references.
- **Test is stale**: `test/widget_test.dart` references a counter app that no longer exists. Running `flutter test` may fail; add/update tests as needed.
- **Database columns are `snake_case`** — repositories map `snake_case` Supabase rows to camelCase Dart models (see `_fromRow`/`_toRow` in any repository).
- **Ad IDs are hardcoded** (Unity: Android `6074470`, iOS `6074471`; test device IDs in `main.dart:63-64`).
- **TMDB API key is hardcoded** in `lib/core/services/tmdb_service.dart:5`.
- **Floating/PiP player** uses a global `navigatorKey` in `lib/main.dart:32` — navigation must use it, not `context`.
- **`local_` prefixed movie IDs** skip view increment (`movie_repository_supabase_impl.dart:81`) — downloaded/local movies will crash the RPC otherwise.
- **No code generation needed** — entities are plain Dart classes (no `freezed`/`json_serializable`).
- **Android-only battery opt-in dialog** shown once per session in `MovieGridPage`.

## CI

`.github/workflows/supabase-backup.yml` — daily pg_dump backup emailed via SMTP (manual trigger also supported).
