# Flutter API Client Example

A comprehensive demo app showcasing all features of `flutter_api_client` using real public APIs.

## What's Demonstrated

### 🎯 Core Features
- **Multiple API clients** with different interceptor configurations
- **Type-safe requests** with generic methods and custom decoders
- **ApiResult pattern** with exhaustive `Success`/`Failure` matching
- **CustomApiResponse** for simpler error handling

### 🔄 Interceptors in Action
- **RetryInterceptor**: Exponential backoff with jitter (DummyJSON tab)
- **CacheInterceptor**: Three cache strategies across tabs
  - `cacheFirst` — JSONPlaceholder (tap twice to see cache hit)
  - `staleWhileRevalidate` — DummyJSON
  - `networkFirst` — Dog CEO
- **DedupInterceptor**: Request deduplication (JSONPlaceholder & Dog CEO)
- **PrettyLogger**: Structured request/response logs in console

### 🔐 Authentication
- **DummyJSON tab**: Full auth flow with `POST /auth/login`
- Token injection and Bearer scheme demonstration
- Auth-less endpoints with `includeToken: false`

### 🚫 Advanced Request Control
- **CancelToken**: Abort in-flight requests (Dog CEO tab)
- **Query parameters**: URL building with `RequestOptions.queryParameters`
- **Progress tracking**: Upload/download callbacks ready to use

### 📋 Real APIs Used

| Tab | Base URL | Features |
|-----|----------|----------|
| **DummyJSON** | dummyjson.com | Auth flow, products, `ApiResult` sealed type |
| **JSONPlaceholder** | jsonplaceholder.typicode.com | Full CRUD, cacheFirst, dedup demo |
| **Dog CEO** | dog.ceo | Image display, cache, cancel token |
| **Trivia** | opentdb.com | Query params, ApiResult pattern |

### 🧪 Spec-Driven Development
The example includes a sample `ApiSpec` (`lib/my_spec.dart`) showing:
- Spec definition with `@ApiSpecEntry` annotation
- Generated test scaffolds (`lib/my_spec.test.g.dart`)
- Runnable test suite (`test/api_spec_test.dart`)

## Running the Example

### 1. Install Dependencies

```bash
cd example
flutter pub get
```

### 2. Run the App

```bash
# Desktop (macOS, Linux, Windows)
flutter run -d macos    # or linux, windows

# Mobile
flutter run -d ios      # iOS Simulator
flutter run -d android  # Android Emulator

# Web
flutter run -d chrome
```

### 3. Explore Features

Open each tab and tap the buttons to see:
- Console logs showing PrettyLogger output
- Cache hits/misses (JSONPlaceholder & Dog CEO)
- Request deduplication (JSONPlaceholder "dedup" button)
- Cancel token behavior (Dog CEO "cancel" button)
- Different response types (JSON, images)

### 4. Check Console Output

Watch the console for structured logs:
```
┌─── POST auth/login ───
│ Content-Type: application/json
│ body: {"username":"emilys","password":"..."}
└───────────────
┌─── 200 POST auth/login ───
│ content-type: application/json
│ body: {"token":"eyJhbGci...","user":{...}}
└───────────────
```

## Code Structure

```
example/
├── lib/
│   ├── main.dart              # 4 tabs, 4 clients, all features demo
│   ├── my_spec.dart           # Sample ApiSpec definition
│   ├── my_spec.g.dart         # Generated (build_runner)
│   └── my_spec.test.g.dart    # Generated test scaffold
├── test/
│   └── api_spec_test.dart     # Runnable tests from spec
├── docs/                      # Generated from spec
│   ├── api/
│   │   ├── openapi.json       # OpenAPI 3.1
│   │   ├── openapi.yaml       # OpenAPI 3.1
│   │   ├── api-reference.md   # Markdown docs
│   │   └── backend-guide.md   # Implementation guide
└── README.md
```

## Generating Docs from Spec

The example spec can generate documentation:

```bash
# Generate all docs
dart run flutter_api_client:gen

# Generate only tests
dart run flutter_api_client:gen --only tests

# Run generated tests
flutter test
```

## Learn More

Each tab in the app demonstrates different patterns:

1. **DummyJSON**: Auth flow, retry logic, sealed `ApiResult<T>`
2. **JSONPlaceholder**: CRUD operations, `cacheFirst`, request deduplication
3. **Dog CEO**: Image loading, `networkFirst`, cancel tokens
4. **Trivia**: Query parameters, `ApiResult` pattern

Study the code in `lib/main.dart` to see how each client is configured and how different interceptors affect behavior.

## Key Takeaways

- **One client per base URL** for proper interceptor scoping
- **Cache strategies** improve performance dramatically
- **DedupInterceptor** prevents redundant network calls
- **PrettyLogger** makes debugging effortless
- **Spec-driven development** generates tests + docs automatically

For full documentation, see the [main README](../README.md).
