# Background Sync Guide

How to run the offline queue (and periodic pulls) when your app is **not in
the foreground** — and the one hazard that can lose data if you skip this
guide.

`flutter_api_client` is pure Dart with zero native dependencies, so it never
executes while the OS has your process suspended. Everything below is
app-level wiring on top of the package's existing pieces.

---

## 1. What you get without any of this

The built-in pipeline already covers deferred delivery:

| Moment | Mechanism |
|---|---|
| Write fails offline | `OfflineQueueInterceptor` persists it to Hive |
| Connectivity returns (app open) | `OfflineSyncManager` bound to a connectivity stream replays it |
| App relaunched | `OfflineSyncManager(replayOnStart: true)` drains writes queued in a previous session |
| App foregrounded | call `syncNow()` from your lifecycle observer |

For most apps this is enough: the user reopens the app and the queue drains.
Add OS-level background sync only when writes must land **while the app stays
closed** (field-service uploads, messaging, compliance timestamps).

```dart
// App-foregrounded trigger — no plugins needed:
class SyncOnResume extends WidgetsBindingObserver {
  SyncOnResume(this.sync);
  final OfflineSyncManager sync;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync.syncNow();
  }
}
```

---

## 2. THE HAZARD — read this before adding workmanager

**Hive boxes are not isolate-safe.** A `workmanager` / `background_fetch`
callback runs in a **separate Dart isolate** with its own memory. If that
isolate opens the same queue box while your main app is also running (the OS
absolutely will fire a background task while the app is foregrounded), two
isolates hold the same file with independent in-memory state. Writes from one
silently overwrite or corrupt the other's — this is exactly the kind of loss
the offline queue exists to prevent.

**The fix is ownership hand-off, not locking.** The background isolate first
asks "is the main app alive?" via `IsolateNameServer`. If yes, it *delegates*
(the main isolate already has the box open and a sync manager running); only
if the app is dead does it open Hive itself.

```dart
// ---- main isolate (app startup) ----
const kSyncPort = 'fac.offline.syncNow';

void registerSyncPort(OfflineSyncManager sync) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(kSyncPort); // stale from hot-restart
  IsolateNameServer.registerPortWithName(port.sendPort, kSyncPort);
  port.listen((_) => sync.syncNow());
}
// On logout/teardown: IsolateNameServer.removePortNameMapping(kSyncPort);
```

```dart
// ---- background isolate (inside the task callback) ----
Future<bool> runBackgroundSync() async {
  final mainApp = IsolateNameServer.lookupPortByName(kSyncPort);
  if (mainApp != null) {
    mainApp.send('sync'); // app is alive — IT owns the box; we just poke it
    return true;
  }
  // App is dead: this isolate is the sole owner. Safe to open Hive.
  final dir = await getApplicationDocumentsDirectory();
  Hive.init(dir.path);
  final box = await Hive.openBox<String>('offline_queue');
  final client = buildApiClient(); // your usual factory: baseUrl, auth, retries
  try {
    final store = HiveOfflineQueueStore(box);
    if (await store.length == 0) return true; // nothing to do — cheap exit

    final report =
        await OfflineQueueReplayer(store: store, client: client).replay();
    // Ask the OS to retry later only if transient failures remain queued.
    return report.reEnqueued == 0;
  } finally {
    client.close();
    await box.close(); // release the file for the next owner
  }
}
```

Notes:
- `IsolateNameServer` is in `dart:ui`, available in plugin-spawned background
  isolates.
- Your auth `TokenStorage` must work from a background isolate.
  `flutter_secure_storage` and `shared_preferences` do (the plugin engine is
  up); anything cached purely in main-isolate memory does not — construct the
  client fresh from persistent storage.
- Queued records deliberately persist **no** `Authorization` header; the
  replayer attaches a fresh token via your auth interceptor, so token refresh
  works normally in the background isolate.

---

## 3. Android — workmanager

```yaml
dependencies:
  workmanager: ^0.5.2
  path_provider: ^2.1.0
```

```dart
@pragma('vm:entry-point') // required: tree-shaking must keep this entry point
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return runBackgroundSync(); // section 2
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(callbackDispatcher);
  Workmanager().registerPeriodicTask(
    'fac-offline-sync',            // unique name — re-registering replaces it
    'offlineSync',
    frequency: const Duration(minutes: 15), // Android's floor; shorter is ignored
    constraints: Constraints(
      networkType: NetworkType.connected,  // don't wake up to fail offline
    ),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );
  runApp(const MyApp());
}
```

**Permissions:** none to add by hand. `workmanager` merges what it needs;
`INTERNET` you already have for any API call (check it's in the **main**
`AndroidManifest.xml`, not just debug — a classic release-build surprise).
WorkManager survives reboots without `RECEIVE_BOOT_COMPLETED` on your part.

**Timing reality:** 15-minute frequency is a *minimum interval*, not a
schedule. Doze mode batches and defers; the `connected` constraint means the
task tends to fire soon after connectivity returns, which is exactly what a
replay wants.

---

## 4. iOS — BGTaskScheduler (via workmanager)

iOS is opportunistic: **you cannot make it run at a set time.** The system
decides based on user habits, charging state, and Low Power Mode. Treat iOS
background sync as "sometimes sooner than next launch," never as a guarantee.

1. Xcode → target → *Signing & Capabilities* → add **Background Modes** →
   check *Background fetch* and *Background processing*.
2. `Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>dev.yourapp.offlineSync</string>
</array>
```

3. `AppDelegate.swift`, inside `didFinishLaunchingWithOptions`:

```swift
WorkmanagerPlugin.registerTask(withIdentifier: "dev.yourapp.offlineSync")
```

4. Register from Dart with the same identifier
   (`Workmanager().registerPeriodicTask("dev.yourapp.offlineSync", ...)`).

No user-facing permission prompt on either platform — background execution is
a capability/entitlement, not a runtime permission.

Pin these steps against the `workmanager` README for your installed version;
the iOS registration API has shifted between releases.

---

## 5. Background pull (periodic GET refresh)

The same skeleton refreshes reads. In the background callback, after the
delegation check:

```dart
final client = buildApiClient(); // with CacheInterceptor + HiveCacheStore
await client.get<dynamic>(
  'todos',
  options: RequestOptions(
    // networkFirst: hit the origin, update the persistent cache on 2xx.
    cachePolicy: CachePolicy.networkFirst(ttl: Duration(minutes: 30)),
  ),
);
```

The response lands in `HiveCacheStore`, so the next app launch serves fresh
data instantly from `cacheFirst` — that's the entire "background pull"
feature. The same isolate rule applies to the **cache** box: delegate when the
app is alive.

For *in-app* periodic refresh, skip the plugins entirely:

```dart
// ponytail: a Timer is the whole feature. Add a manager class only if you
// need per-endpoint intervals or circuit-breaker-aware pausing.
final refresh = Timer.periodic(const Duration(minutes: 5), (_) {
  client.get<dynamic>('todos',
      options: RequestOptions(cachePolicy: CachePolicy.networkFirst()));
});
// Pause in didChangeAppLifecycleState(paused), resume on resumed.
```

---

## 6. Checklist

- [ ] `replayOnStart: true` on your `OfflineSyncManager` (covers 90% of needs)
- [ ] `syncNow()` on app resume
- [ ] Only add `workmanager` if writes must land while the app stays closed
- [ ] Background callback **delegates via `IsolateNameServer`** when the app
      is alive — never two isolates on one Hive box
- [ ] Background isolate closes the box in a `finally`
- [ ] Return `report.reEnqueued == 0` so the OS retries only when useful
- [ ] `INTERNET` permission in the main Android manifest (release builds)
- [ ] iOS: Background Modes capability + permitted identifier; expect
      opportunistic timing
- [ ] Test the real thing on a device: queue a write in airplane mode, kill
      the app, restore connectivity, wait for the OS task (or trigger it via
      `adb shell am broadcast` / Xcode's *Simulate Background Fetch*)
