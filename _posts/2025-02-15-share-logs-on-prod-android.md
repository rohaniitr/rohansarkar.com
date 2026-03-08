---
layout: default
title: Share Logs on Production Environment (Android)
date: 2025-02-15
excerpt: How to implement health log export on Android—persistent DB storage, WorkManager for retention and upload, chunked upload with progress, and memory-leak prevention.
---

# Share Logs on Production Environment (Android)

**How to implement health log export on Android—persistent DB storage, WorkManager for retention and upload, chunked upload with progress, and memory-leak prevention.**

---

## Introduction

Production apps need a way for users to share diagnostic logs with support. When a user taps "Share health logs" in Settings, the app should upload logs from the last N seconds to a server—without blocking the UI or leaking memory.

This post covers:

1. **Custom logging** – Log to console and persist to DB in one call
2. **Retention** – WorkManager deletes logs older than N seconds (config-driven)
3. **Export flow** – User consent → worker uploads logs in chunks of size M (config-driven)
4. **Progress UI** – Show upload status on screen
5. **Architecture** – Screen → ViewModel → Repo → Use case (MVVM)
6. **Memory-leak prevention** – Proper lifecycle and scope handling

---

## 1. Configuration

Define N (retention seconds) and M (chunk size) in config so they can be tuned per environment.

```kotlin
// LogConfig.kt
data class LogConfig(
    /** Logs older than this (seconds) are deleted by retention worker */
    val retentionSeconds: Long,
    /** Upload logs in chunks of this size */
    val uploadChunkSize: Int
)

// In your config module or BuildConfig
object AppLogConfig {
    val logConfig: LogConfig = LogConfig(
        retentionSeconds = 7 * 24 * 60 * 60,  // 7 days
        uploadChunkSize = 500
    )
}
```

---

## 2. Data Layer: Log Entity and DAO

Use Room to store logs. Each entry has a timestamp for retention and ordering.

```kotlin
// LogEntity.kt
@Entity(tableName = "app_logs")
data class LogEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val level: String,           // DEBUG, INFO, WARN, ERROR
    val tag: String,
    val message: String,
    val timestamp: Long,
    val throwable: String? = null
)

// LogDao.kt
@Dao
interface LogDao {

    @Insert
    suspend fun insert(log: LogEntity): Long

    @Query("DELETE FROM app_logs WHERE timestamp < :beforeTimestamp")
    suspend fun deleteOlderThan(beforeTimestamp: Long)

    @Query("SELECT * FROM app_logs WHERE timestamp >= :sinceTimestamp ORDER BY timestamp ASC")
    fun getLogsSince(sinceTimestamp: Long): Flow<List<LogEntity>>

    @Query("SELECT * FROM app_logs WHERE timestamp >= :sinceTimestamp ORDER BY timestamp ASC")
    suspend fun getLogsSinceSync(sinceTimestamp: Long): List<LogEntity>

    @Query("SELECT COUNT(*) FROM app_logs WHERE timestamp >= :sinceTimestamp")
    suspend fun countLogsSince(sinceTimestamp: Long): Int
}
```

---

## 3. Custom Logger: Console + DB

A single method logs to both Logcat and the database. All app logging goes through this.

```kotlin
// AppLogger.kt
class AppLogger(
    private val logDao: LogDao,
    private val config: LogConfig,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) {

    fun log(level: LogLevel, tag: String, message: String, throwable: Throwable? = null) {
        // Console
        when (level) {
            LogLevel.DEBUG -> Log.d(tag, message, throwable)
            LogLevel.INFO -> Log.i(tag, message, throwable)
            LogLevel.WARN -> Log.w(tag, message, throwable)
            LogLevel.ERROR -> Log.e(tag, message, throwable)
        }

        // DB (fire-and-forget on IO)
        CoroutineScope(ioDispatcher).launch {
            logDao.insert(
                LogEntity(
                    level = level.name,
                    tag = tag,
                    message = message,
                    timestamp = System.currentTimeMillis(),
                    throwable = throwable?.stackTraceToString()
                )
            )
        }
    }

    fun d(tag: String, message: String) = log(LogLevel.DEBUG, tag, message)
    fun i(tag: String, message: String) = log(LogLevel.INFO, tag, message)
    fun w(tag: String, message: String) = log(LogLevel.WARN, tag, message)
    fun e(tag: String, message: String, throwable: Throwable? = null) = log(LogLevel.ERROR, tag, message, throwable)
}

enum class LogLevel { DEBUG, INFO, WARN, ERROR }
```

**Note:** The logger uses its own `CoroutineScope` with `Dispatchers.IO`. It does not depend on ViewModel or Activity scope, so it can be used from anywhere (repositories, use cases, workers).

---

## 4. Use Case: Upload Logs

The use case defines the contract: upload logs since a given timestamp, in chunks, and report progress.

```kotlin
// UploadLogsUseCase.kt
interface UploadLogsUseCase {

    /**
     * Uploads logs since [sinceTimestamp] in chunks.
     * Emits [UploadProgress] for each chunk or completion.
     */
    fun uploadLogs(sinceTimestamp: Long): Flow<UploadProgress>
}

sealed class UploadProgress {
    data class InProgress(val uploadedChunks: Int, val totalChunks: Int, val totalLogs: Int) : UploadProgress()
    data object Completed : UploadProgress()
    data class Error(val throwable: Throwable) : UploadProgress()
}
```

---

## 5. Repository Implementation

The repository fetches logs from the DB, chunks them, and uploads via an API. It emits progress for each chunk.

```kotlin
// LogUploadRepository.kt
class LogUploadRepository(
    private val logDao: LogDao,
    private val logUploadApi: LogUploadApi,
    private val config: LogConfig,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) : UploadLogsUseCase {

    override fun uploadLogs(sinceTimestamp: Long): Flow<UploadProgress> = flow {
        withContext(ioDispatcher) {
            val allLogs = logDao.getLogsSinceSync(sinceTimestamp)
            if (allLogs.isEmpty()) {
                emit(UploadProgress.Completed)
                return@withContext
            }

            val chunks = allLogs.chunked(config.uploadChunkSize)
            val totalChunks = chunks.size

            chunks.forEachIndexed { index, chunk ->
                val request = LogUploadRequest(
                    logs = chunk.map { it.toDto() },
                    chunkIndex = index,
                    totalChunks = totalChunks
                )
                logUploadApi.uploadLogs(request)
                emit(
                    UploadProgress.InProgress(
                        uploadedChunks = index + 1,
                        totalChunks = totalChunks,
                        totalLogs = allLogs.size
                    )
                )
            }
            emit(UploadProgress.Completed)
        }
    }.catch { e ->
        emit(UploadProgress.Error(e))
    }

    private fun LogEntity.toDto() = LogDto(level, tag, message, timestamp, throwable)
}

// API
interface LogUploadApi {
    suspend fun uploadLogs(request: LogUploadRequest)
}

data class LogUploadRequest(
    val logs: List<LogDto>,
    val chunkIndex: Int,
    val totalChunks: Int
)

data class LogDto(val level: String, val tag: String, val message: String, val timestamp: Long, val throwable: String?)
```

---

## 6. Retention Worker: Delete Old Logs

WorkManager runs periodically to delete logs older than N seconds.

```kotlin
// LogRetentionWorker.kt
class LogRetentionWorker(
    context: Context,
    params: WorkerParameters,
    private val logDao: LogDao,
    private val config: LogConfig
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        try {
            val cutoff = System.currentTimeMillis() - (config.retentionSeconds * 1000)
            logDao.deleteOlderThan(cutoff)
            Result.success()
        } catch (e: Exception) {
            Result.failure()
        }
    }

    class Factory(
        private val logDao: LogDao,
        private val config: LogConfig
    ) : WorkerFactory() {
        override fun createWorker(context: Context, workerClassName: String, workerParameters: WorkerParameters): ListenableWorker {
            return LogRetentionWorker(context, workerParameters, logDao, config)
        }
    }
}

// WorkManager configuration (Application)
// With Hilt: use @HiltWorker and @WorkerInject; no manual factory needed.
// With Koin: use DelegatingWorkerFactory to route LogRetentionWorker to your Factory:
val workManagerConfig = Configuration.Builder()
    .setWorkerFactory(
        DelegatingWorkerFactory().apply {
            addFactory(LogRetentionWorker.Factory(logDao, config))
        }
    )
    .build()
WorkManager.initialize(context, workManagerConfig)

// Schedule in Application or a setup module
fun scheduleLogRetention(context: Context) {
    val request = PeriodicWorkRequestBuilder<LogRetentionWorker>(1, TimeUnit.DAYS)
        .setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build())
        .build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        "log_retention",
        ExistingPeriodicWorkPolicy.KEEP,
        request
    )
}
```

---

## 7. Upload Worker: Export on User Consent

When the user taps "Share health logs", enqueue a one-time worker that uploads logs. The worker runs in the background; the UI observes progress via a shared mechanism (e.g. `WorkManager.getWorkInfosByIdLiveData` or a custom progress channel).

For **progress on screen**, we need the UI to observe upload state. Two approaches:

**Option A: Worker + Progress via Shared State**

The worker writes progress to a repository that exposes `Flow`. The ViewModel collects this flow. The worker and ViewModel share a `UploadProgressRepository` that holds the current progress.

**Option B: Direct ViewModel → Use Case (Recommended)**

Skip the worker for the *progress observation*: the ViewModel calls the use case directly and collects the flow. The actual upload runs on `Dispatchers.IO`. When the screen is closed, the ViewModel is cleared and the coroutine is cancelled—no upload in background. If you need **upload to continue in background** when the user leaves the screen, use Option A with a worker that reports progress to a shared store.

Here we show **Option B** (simpler, progress in foreground) and then **Option A** (background upload with progress).

### Option B: Foreground Upload (ViewModel → Use Case)

User stays on screen; upload runs in ViewModel scope; progress is observed directly.

```kotlin
// SettingsViewModel.kt
class SettingsViewModel(
    private val uploadLogsUseCase: UploadLogsUseCase,
    private val config: LogConfig
) : ViewModel() {

    private val _uploadState = MutableStateFlow<UploadState>(UploadState.Idle)
    val uploadState: StateFlow<UploadState> = _uploadState.asStateFlow()

    fun shareHealthLogs() {
        viewModelScope.launch {
            val sinceTimestamp = System.currentTimeMillis() - (config.retentionSeconds * 1000)
            _uploadState.value = UploadState.InProgress(0, 0, 0)

            uploadLogsUseCase.uploadLogs(sinceTimestamp)
                .collect { progress ->
                    when (progress) {
                        is UploadProgress.InProgress -> {
                            _uploadState.value = UploadState.InProgress(
                                progress.uploadedChunks,
                                progress.totalChunks,
                                progress.totalLogs
                            )
                        }
                        is UploadProgress.Completed -> _uploadState.value = UploadState.Completed
                        is UploadProgress.Error -> _uploadState.value = UploadState.Error(progress.throwable.message ?: "Unknown error")
                    }
                }
        }
    }

    fun resetUploadState() {
        _uploadState.value = UploadState.Idle
    }
}

sealed class UploadState {
    data object Idle : UploadState()
    data class InProgress(val uploadedChunks: Int, val totalChunks: Int, val totalLogs: Int) : UploadState()
    data object Completed : UploadState()
    data class Error(val message: String) : UploadState()
}
```

### Option A: Background Upload with Progress

If upload must continue when the user navigates away, use a worker and a shared progress store.

```kotlin
// UploadProgressStore.kt - Shared between Worker and ViewModel
class UploadProgressStore {
    private val _progress = MutableSharedFlow<UploadProgress>(replay = 1)
    val progress: SharedFlow<UploadProgress> = _progress.asSharedFlow()

    suspend fun emit(progress: UploadProgress) {
        _progress.emit(progress)
    }
}

// LogUploadWorker.kt
class LogUploadWorker(
    context: Context,
    params: WorkerParameters,
    private val uploadLogsUseCase: UploadLogsUseCase,
    private val progressStore: UploadProgressStore,
    private val config: LogConfig
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val sinceTimestamp = System.currentTimeMillis() - (config.retentionSeconds * 1000)
        try {
            uploadLogsUseCase.uploadLogs(sinceTimestamp).collect { progress ->
                progressStore.emit(progress)
                if (progress is UploadProgress.Completed || progress is UploadProgress.Error) {
                    return@withContext if (progress is UploadProgress.Completed) Result.success() else Result.failure()
                }
            }
            Result.success()
        } catch (e: Exception) {
            progressStore.emit(UploadProgress.Error(e))
            Result.failure()
        }
    }
}
```

The ViewModel observes `progressStore.progress` and updates `_uploadState`. The worker is enqueued when the user taps "Share health logs".

---

## 8. Screen: Progress UI

Compose example showing progress during upload.

```kotlin
// SettingsScreen.kt
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val uploadState by viewModel.uploadState.collectAsStateWithLifecycle()

    Column(modifier = Modifier.padding(16.dp)) {
        // ... other settings ...

        Button(
            onClick = { viewModel.shareHealthLogs() },
            enabled = uploadState is UploadState.Idle || uploadState is UploadState.Completed || uploadState is UploadState.Error
        ) {
            Text("Share health logs")
        }

        when (val state = uploadState) {
            is UploadState.InProgress -> {
                LinearProgressIndicator(
                    progress = { state.uploadedChunks.toFloat() / state.totalChunks },
                    modifier = Modifier.fillMaxWidth()
                )
                Text("Uploading ${state.uploadedChunks}/${state.totalChunks} chunks (${state.totalLogs} logs)")
            }
            is UploadState.Completed -> {
                Text("Upload complete", color = Color.Green)
                LaunchedEffect(Unit) {
                    delay(2000)
                    viewModel.resetUploadState()
                }
            }
            is UploadState.Error -> {
                Text("Error: ${state.message}", color = Color.Red)
            }
            UploadState.Idle -> { }
        }
    }
}
```

---

## 9. Layering: Screen → ViewModel → Repo → Use Case

```
Screen (Compose / XML)
    │ observes uploadState
    │ calls shareHealthLogs()
    ▼
ViewModel (SettingsViewModel)
    │ shareHealthLogs() → uploadLogsUseCase.uploadLogs()
    │ collect Flow → update _uploadState
    ▼
Repository (LogUploadRepository implements UploadLogsUseCase)
    │ getLogsSinceSync(), chunked upload via API
    ▼
Data sources (LogDao, LogUploadApi)
```

The **use case interface** lives in a core/domain module. The **repository** implements it in the data module. ViewModels depend on `UploadLogsUseCase`, not the concrete repository. Tests inject a fake use case.

---

## 10. Avoiding Memory Leaks

### 10.1 Use viewModelScope for Upload Collection

All coroutines that collect the upload flow must run in `viewModelScope`. When the ViewModel is cleared, the scope is cancelled and the collection stops. No orphaned coroutines.

```kotlin
viewModelScope.launch {
    uploadLogsUseCase.uploadLogs(sinceTimestamp).collect { ... }
}
```

### 10.2 Avoid Capturing Activity or Fragment

Never pass `Activity`, `Fragment`, or a non-application `Context` into the ViewModel. Use `Application` context or inject application-scoped dependencies.

```kotlin
// BAD
class MyViewModel(private val activity: Activity) : BaseStockStreamViewModel(...)

// GOOD
class SettingsViewModel(
    private val uploadLogsUseCase: UploadLogsUseCase,
    private val config: LogConfig
) : ViewModel()
```

### 10.3 AppLogger Scope

`AppLogger` uses `CoroutineScope(ioDispatcher).launch`. That scope is not tied to any lifecycle. Each log is a fire-and-forget job. To avoid unbounded growth, ensure the scope is either:

- **Application-scoped** – A single `CoroutineScope` for the whole app, cancelled only on process death, or
- **Supervised** – Use `SupervisorJob` so one failing insert does not cancel others

```kotlin
// Application-scoped logger
class AppLogger(
    private val logDao: LogDao,
    private val applicationScope: CoroutineScope  // Injected; e.g. ProcessLifecycleOwner scope
) {
    fun log(...) {
        Log.d(tag, message, throwable)
        applicationScope.launch(Dispatchers.IO) {
            logDao.insert(...)
        }
    }
}
```

### 10.4 Worker and Progress Store

If using `UploadProgressStore` with a worker: the store should be a singleton (e.g. in DI). The ViewModel collects from it. When the ViewModel is cleared, the collection is cancelled. The store itself does not hold references to the ViewModel or screen. Workers hold no references to UI.

### 10.5 Reset State on Idle

When upload completes or errors, reset state after a delay or on user action. Avoid holding large `UploadState` objects longer than needed.

```kotlin
fun resetUploadState() {
    _uploadState.value = UploadState.Idle
}
```

---

## 11. Summary

| Topic | Approach |
|-------|----------|
| **Logging** | `AppLogger` logs to console and DB; single entry point |
| **Retention** | WorkManager `LogRetentionWorker` deletes logs older than N seconds (config) |
| **Export** | User taps "Share health logs" → ViewModel calls `UploadLogsUseCase` or enqueues `LogUploadWorker` |
| **Chunking** | Upload in chunks of size M (config); repository chunks and uploads sequentially |
| **Progress** | `Flow<UploadProgress>` emitted per chunk; ViewModel collects and exposes `StateFlow<UploadState>` |
| **Architecture** | Screen → ViewModel → Repo → Use case |
| **Memory leaks** | Use `viewModelScope`; avoid Activity/Fragment in ViewModel; application-scoped logger scope; workers hold no UI refs |

With this setup, users can share health logs from Settings, see upload progress, and the app retains logs only for the configured period while avoiding common memory-leak pitfalls.
