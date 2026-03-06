---
layout: default
title: Use Case Interfaces as API
date: 2025-10-02
excerpt: How a single interface lets you run demos, develop against a local server, or hit production APIs—without touching feature code.
---

# Use Case Interfaces as API: Switching Between Stub, Local, and Backend

**How a single interface lets you run demos, develop against a local server, or hit production APIs—without touching feature code.**

---

## The Problem

You're building a mobile app that depends on a backend. You need:

1. **Demos / sales** – No backend or VPN; app must work reliably
2. **Local development** – Backend on your machine; fast iteration
3. **Integration / production** – Real staging or production APIs

If screens and ViewModels depend directly on HTTP clients or base URLs, you end up with `if (BuildConfig.DEMO)` branches, scattered base URLs, and duplicated logic.

**Better approach:** use a single contract and swap implementations at the boundary.

---

## The Pattern: Interface as Contract

Define behavior in an interface. Screens, ViewModels, and repositories depend on that interface, not on concrete implementations.

```kotlin
// In your core module - the contract
interface DiExecutionUseCase {
    suspend fun draftOrder(
        assetId: UUID,
        portfolio: UUID,
        accountId: String,
        orderType: OrderOptionTypeEnum,
        method: OrderOptionMethodEnum,
        currency: String,
        durationCode: String,
        requestMethod: RequestMethod,
        limitPrice: Double? = null,
        stopPrice: Double? = null,
        expirationDate: LocalDate? = null,
        amount: Double? = null,
        shares: Double? = null,
        extendedHours: Boolean? = false
    ): Result<OrderInitResponse, ExecutionError>

    suspend fun placeOrder(
        orderId: UUID,
        durationCode: String?,
        expirationDate: LocalDate?,
        extendedHours: Boolean?,
    ): Result<OrderPlaceResponse, ExecutionError>

    // ... other operations
}
```

Feature code only talks to `DiExecutionUseCase`. It doesn't know whether the implementation is stub, local, or backend.

---

## Three Implementations, One Contract

### 1. Stub (Fake) – For Demos and UI Tests

No network. Responses come from bundled assets (JSON). Optional delay simulates latency.

**Use when:** demos, UI tests, CI, or when the backend is unavailable.

```kotlin
// In usecase-stub module
class FakeDiExecutionUseCase(
    private val context: Context,
    private val delayDuration: Long = 0,
    private val moshi: Moshi = Moshi.Builder().add(/* adapters */).build(),
    private val portfolioListPath: String = "portfolio_tradables.json",
    // ...
) : DiExecutionUseCase {

    override suspend fun draftOrder(...): Result<OrderInitResponse, ExecutionError> {
        delay(delayDuration)
        val json = context.assets.open("draft_order.json").bufferedReader().readText()
        val response = moshi.decodeFromString<OrderInitResponse>(json)
        return Result.success(response)
    }
    // ...
}
```

You can override file paths and delay per test or demo scenario.

---

### 2. Gen (Backend) – For Staging/Production

Uses the real HTTP APIs via your generated client.

**Use when:** integration tests, QA, or production.

```kotlin
// In core or usecase-gen module
class GenDiExecutionUseCase(
    private val portfolioApi: PortfolioApi,
    private val investmentApi: InvestmentApi,
    private val assetApi: AssetUniverseApi,
    private val activitiesApi: ActivitiesApi,
    private val platformSettingsApi: PlatformApi,
    private val moshi: Moshi
) : DiExecutionUseCase {

    override suspend fun draftOrder(...): Result<OrderInitResponse, ExecutionError> {
        return runCatching {
            investmentApi.postOrderInit(
                assetId = assetId,
                portfolioId = portfolio,
                // ...
            )
        }.fold(
            onSuccess = { Result.success(it) },
            onFailure = { Result.failure(mapToExecutionError(it)) }
        )
    }
    // ...
}
```

---

### 3. Local – For Running the Server on Your Machine

Same as Gen, but configured for a local server. On Android emulator that usually means `http://10.0.2.2:PORT` (emulator alias for host). On physical device use your machine's LAN IP or port forwarding.

**Use when:** backend development, debugging API changes, offline work.

```kotlin
// Local configuration
object LocalConfigurationProvider : ConfigurationProvider {
    override val configuration = BBConfiguration(
        serverUrl = "http://10.0.2.2:8080"  // Emulator → host
        // Or "http://192.168.1.42:8080" for physical device
    ) {
        version = "6.2"
        // Same identity, headers as dev
    }
    override val headers: Map<String, String> = emptyMap()
}
```

---

## Wiring the Switch

You choose the implementation in dependency injection:

```kotlin
// In your Application or Koin module
val useCaseModule = module {
    scope<DiExecutionJourneyScope> {
        scoped<DiExecutionUseCase> {
            when (BuildConfig.USE_CASE_MODE) {
                "stub" -> FakeDiExecutionUseCase(get(), delayDuration = 500)
                "local" -> GenDiExecutionUseCase(/* wired with LocalConfigurationProvider */)
                else -> GenDiExecutionUseCase(/* wired with AppDevConfigurationProvider */)
            }
        }
    }
}
```

---

## Runtime Switching via Profile (Debug Builds)

For debug builds, add a Developer section in the profile (More) screen that lets you switch between backend, local, and stub at runtime without rebuilding.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Profile (More) Screen                                           │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Developer (only when BuildConfig.DEBUG)                      ││
│  │   ○ Backend   ○ Local server   ● Stub                       ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ on select → save preference + restart
┌─────────────────────────────────────────────────────────────────┐
│  SharedPreferences: KEY_DATA_SOURCE_MODE = "STUB"                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ read at app startup
┌─────────────────────────────────────────────────────────────────┐
│  diExecutionUseCaseDefinition = {                               │
│    when (dataSourceModeRepo.getMode()) {                         │
│      STUB   -> FakeDiExecutionUseCase(...)                      │
│      LOCAL  -> GenDiExecutionUseCase(config = LocalConfig)       │
│      BACKEND-> GenDiExecutionUseCase(config = DevConfig)         │
│    }                                                             │
│  }                                                               │
└─────────────────────────────────────────────────────────────────┘
```

### 1. Data Source Mode and Storage

```kotlin
// DataSourceMode.kt
enum class DataSourceMode(val displayName: String) {
    BACKEND("Backend (dev)"),
    LOCAL("Local server"),
    STUB("Stub (offline)")
}

// DataSourceModeRepository.kt
class DataSourceModeRepository(
    private val preferences: SharedPreferences
) {
    companion object {
        private const val KEY_DATA_SOURCE_MODE = "data_source_mode"
    }

    fun getMode(): DataSourceMode {
        val saved = preferences.getString(KEY_DATA_SOURCE_MODE, null)
        return try {
            DataSourceMode.valueOf(saved ?: DataSourceMode.BACKEND.name)
        } catch (e: IllegalArgumentException) {
            DataSourceMode.BACKEND
        }
    }

    fun setMode(mode: DataSourceMode) {
        preferences.edit()
            .putString(KEY_DATA_SOURCE_MODE, mode.name)
            .apply()
    }
}
```

### 2. Koin Module for the Repository

```kotlin
// In your debug or app module
val debugModule = module {
    single<DataSourceModeRepository> {
        DataSourceModeRepository(
            get<Context>().getSharedPreferences("debug_prefs", Context.MODE_PRIVATE)
        )
    }
}

// Load only when DEBUG
if (BuildConfig.DEBUG) {
    loadKoinModules(debugModule)
}
```

### 3. Use Case Definition That Reads the Mode

```kotlin
// In createUseCaseDefinitions() or equivalent
diExecutionUseCaseDefinition = {
    val modeRepo: DataSourceModeRepository = get()
    val context: Context = get()

    when (modeRepo.getMode()) {
        DataSourceMode.STUB -> FakeDiExecutionUseCase(
            context = context,
            delayDuration = 500,
            moshi = get()
        )
        DataSourceMode.LOCAL -> GenDiExecutionUseCase(
            portfolioApi = get(),  // API clients built with LocalConfigurationProvider
            investmentApi = get(),
            assetApi = get(),
            activitiesApi = get(),
            platformSettingsApi = get(),
            moshi = get()
        )
        DataSourceMode.BACKEND -> GenDiExecutionUseCase(
            portfolioApi = get(),  // API clients built with AppDevConfigurationProvider
            investmentApi = get(),
            assetApi = get(),
            activitiesApi = get(),
            platformSettingsApi = get(),
            moshi = get()
        )
    }
}
```

### 4. Configuration Provider Based on Mode

```kotlin
// Application
override fun provideConfigurationProvider(): ConfigurationProvider {
    if (!BuildConfig.DEBUG) {
        return resolveConfigurationProvider(BuildConfig.FLAVOR)
    }
    return when (get<DataSourceModeRepository>().getMode()) {
        DataSourceMode.LOCAL -> LocalConfigurationProvider
        else -> resolveConfigurationProvider(BuildConfig.FLAVOR)
    }
}
```

### 5. Profile UI – Developer Section (Debug Only)

```kotlin
// MoreConfig.kt - add developer section when isDebug
fun buildMoreConfiguration(
    isDebug: Boolean,
    dataSourceModeRepo: DataSourceModeRepository?,
    context: Context
): MoreConfiguration {
    val sections = mutableListOf<MenuSection>()

    // ... existing sections (Contact Us, Security, etc.) ...

    if (isDebug && dataSourceModeRepo != null) {
        sections.add(
            MenuSection(
                title = DeferredText.Resolved("Developer"),
                items = listOf(
                    createDataSourceModeItem(
                        mode = DataSourceMode.BACKEND,
                        currentMode = dataSourceModeRepo.getMode(),
                        onSelected = { saveAndRestart(dataSourceModeRepo, DataSourceMode.BACKEND, context) }
                    ),
                    createDataSourceModeItem(
                        mode = DataSourceMode.LOCAL,
                        currentMode = dataSourceModeRepo.getMode(),
                        onSelected = { saveAndRestart(dataSourceModeRepo, DataSourceMode.LOCAL, context) }
                    ),
                    createDataSourceModeItem(
                        mode = DataSourceMode.STUB,
                        currentMode = dataSourceModeRepo.getMode(),
                        onSelected = { saveAndRestart(dataSourceModeRepo, DataSourceMode.STUB, context) }
                    )
                )
            )
        )
    }

    return MoreConfiguration.Builder()
        .apply { this.sections = sections }
        .build()
}

private fun createDataSourceModeItem(
    mode: DataSourceMode,
    currentMode: DataSourceMode,
    onSelected: () -> Unit
) = MenuItem(
    title = DeferredText.Resolved(
        if (mode == currentMode) "${mode.displayName} ✓" else mode.displayName
    ),
    icon = DeferredDrawable.Resource(R.drawable.ic_developer)
) {
    OnActionComplete.Custom { onSelected() }
}

private fun saveAndRestart(
    repo: DataSourceModeRepository,
    mode: DataSourceMode,
    context: Context
) {
    repo.setMode(mode)
    AlertDialog.Builder(context)
        .setTitle("Data source changed")
        .setMessage("Restart the app to use ${mode.displayName}.")
        .setPositiveButton("Restart") { _, _ ->
            (context as? Activity)?.recreate()
        }
        .setNegativeButton("Later", null)
        .show()
}
```

### 6. Local Configuration Provider

```kotlin
// LocalConfigurationProvider.kt
object LocalConfigurationProvider : ConfigurationProvider {
    private const val LOCAL_SERVER_URL = "http://10.0.2.2:8080"  // Emulator

    override val configuration = BBConfiguration(serverUrl = LOCAL_SERVER_URL) {
        version = "6.2"
        persistentHeaders = mapOf(
            "X-User-Context" to listOf("local")
        )
        identityConfiguration = IdentityConfiguration(
            baseUrl = "https://identity.dev.rndwlt.azure.backbaseservices.com",
            realm = "retail",
            clientId = "mobile-client"
        ) {
            applicationKey = "wealth"
            allowedDomains = listOf("*")
        }
    }
    override val headers: Map<String, String> = emptyMap()
}
```

### 7. Safety for Release Builds

```kotlin
// Ensure Developer section and DataSourceModeRepository are debug-only
moreConfigurationDefinition = {
    if (get<Boolean>(isDebugQualifier)) {
        DefaultUniversalMoreConfiguration(
            isNotificationSettingsEnabled = true,
            userRepository = getOrNull()
        ) {
            sections = sections + createDeveloperSection(get())
        }
    } else {
        DefaultUniversalMoreConfiguration(
            isNotificationSettingsEnabled = true,
            userRepository = getOrNull()
        )
    }
}
```

---

## Build Variants vs Runtime Switching

**Build-time:** Set implementation via `BuildConfig.USE_CASE_MODE` or product flavors. Smaller APK, no risk in release.

**Runtime:** Switch from Profile in debug. Requires app restart so networking is reinitialized. Useful for QA and local dev.

---

## Project Structure

```
journey-module/
├── core/                    # Interface + UI logic
│   └── DiExecutionUseCase.kt
├── usecase-stub/            # Fake implementation
│   └── FakeDiExecutionUseCase.kt
├── usecase-gen/             # Backend implementation
│   └── GenDiExecutionUseCase.kt
└── demo/                    # App + debug Profile UI
```

---

## Benefits

| Benefit | Description |
|---------|-------------|
| Feature code stays clean | ViewModels never branch on environment or base URLs |
| Demos without backend | Stub with bundled JSON and optional delay |
| Local development | Point at `10.0.2.2:port` and iterate fast |
| Testability | Inject stubs or fakes in unit/UI tests |
| Debug switching | QA and devs can switch data source in Profile without rebuild |

---

## Pitfalls

1. **Contract drift** – Interface, stub, and gen must stay in sync. Tests help.
2. **Stub realism** – Stub data should match real shapes and edge cases.
3. **Local server setup** – Document how to run the server locally and which URL to use.
4. **Release safety** – Ensure release builds never show Developer options or use stub/local.
5. **Restart UX** – User must restart after changing mode; make this clear in the UI.

---

## Summary

One interface, three implementation modes:

- **Stub** – Bundled data, no network; demos and tests
- **Local** – Same implementation as backend; point at `http://10.0.2.2:PORT`
- **Backend** – Real APIs; integration and production

In debug builds, a Profile "Developer" section lets you switch between them at runtime. You only change the implementation and configuration at the edge; feature code stays unchanged.
