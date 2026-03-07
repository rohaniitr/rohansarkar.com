---
layout: default
title: State Modeling with Sealed Classes
date: 2024-09-03
excerpt: How to model async UI state, centralize network-to-domain conversion, and handle errors consistently using sealed classes, interceptors, and extension functions.
---

# State Modeling with Sealed Classes

**How to model async UI state, centralize network-to-domain conversion, and handle errors consistently using sealed classes, interceptors, and extension functions.**

---

## Introduction

In apps that load data from the network, screens show progress, handle errors, and display content. Modeling this as a **sealed interface** gives you:

- Exhaustive `when` handling
- Type-safe state transitions
- Clear separation of loading, success, error, and empty states

This post covers:

1. State sealed interface design
2. Response from Retrofit vs State in app layer
3. Extension functions for handling (`launchIO`, `collectWhenStarted`, `onProgress`, `onData`, `onEmpty`, `onServerError`, `onNetworkError`, `onTimeout`)
4. NetworkHandler converting Response to State

---

## 1. State Sealed Interface

### Error Model

Use this error model when APIs return standard error JSON. Custom APIs can define their own.

```kotlin
data class Error(
    val errorCode: String?,
    val errorDescription: String?,
    val httpStatus: Int?
)
```

### Basic Structure

```kotlin
sealed interface State<out SuccessModel, out ErrorModel> {

    data object Progress : State<Nothing, Nothing>

    data class Data<T>(val data: T) : State<T, Nothing>

    data object Empty : State<Nothing, Nothing>

    sealed interface Error<out S, out E> : State<S, E> {

        data class Server<E>(val error: E?) : Error<Nothing, E>

        data object Network : Error<Nothing, Nothing>

        data object Timeout : Error<Nothing, Nothing>
    }
}
```

### Usage in ViewModel

```kotlin
private val _screenState = MutableStateFlow<State<PortfolioSummary, Error>>(State.Progress)
val screenState: StateFlow<State<PortfolioSummary, Error>> = _screenState.asStateFlow()

launchIO {  // ViewModel extension; runs on Dispatchers.IO
    _screenState.value = State.Progress
    _screenState.value = repository.loadPortfolio(id)  // Repository returns State (converted in NetworkHandler)
}
```

### Usage in Screen

Each extension runs only when the state matches; at most one handler executes. For Compose, use a `when` block if handlers are `@Composable`.

```kotlin
val state by viewModel.screenState.collectWhenStarted()
state
    .onProgress { showLoading() }
    .onData { showContent(it) }
    .onEmpty { showEmpty() }
    .onServerError { err -> showError(err?.errorCode, err?.errorDescription) }
    .onNetworkError { showNetworkError() }
    .onTimeout { showTimeoutError() }
```

---

## 2. Response vs State

**Response** comes from Retrofit (or any HTTP client). It represents the raw outcome of an API call.

**State** is used in the app layer for UI. **NetworkHandler.makeApiCall** converts `Response` to `State` before the data reaches the Repository.

Flow: `Retrofit (Response)` -> `NetworkHandler.makeApiCall (Response -> State)` -> `Repository (State)` -> `ViewModel (StateFlow<State>)` -> `Screen`

---

## 3. Extension Functions for Handling

### ViewModel.launchIO

Launch coroutines on `Dispatchers.IO` for repository or API calls:

```kotlin
fun ViewModel.launchIO(block: suspend CoroutineScope.() -> Unit): Job =
    viewModelScope.launch(Dispatchers.IO, block = block)
```

### StateFlow.collectWhenStarted (Compose)

Collect `StateFlow` only when the composable's lifecycle is at least `STARTED`. Uses `collectAsStateWithLifecycle` from `androidx.lifecycle:lifecycle-runtime-compose` under the hood. Uses the current `StateFlow` value as initial so the caller does not need to pass it. Stops collecting when the screen is stopped (e.g. navigated away), reducing unnecessary work. Add dependency: `androidx.lifecycle:lifecycle-runtime-compose`.

```kotlin
@Composable
fun <T> StateFlow<T>.collectWhenStarted(
    lifecycle: Lifecycle = LocalLifecycleOwner.current.lifecycle,
    minActiveState: Lifecycle.State = Lifecycle.State.STARTED
): State<T> = collectAsStateWithLifecycle(
    initialValue = value,
    lifecycle = lifecycle,
    minActiveState = minActiveState
)
```

**Result extensions (onSuccess, onFailure)** are optional. Conversion from Response to State happens once in `NetworkHandler.makeApiCall`, so the app layer typically only uses State extensions. Use Result extensions only when you need to inspect or handle raw Response/Result before converting—e.g. when logging.

### State Extensions

```kotlin
inline fun <S, E> State<S, E>.onProgress(action: () -> Unit): State<S, E> {
    if (this is State.Progress) action()
    return this
}

inline fun <S, E> State<S, E>.onData(action: (S) -> Unit): State<S, E> {
    if (this is State.Data) action(data)
    return this
}

inline fun <S, E> State<S, E>.onEmpty(action: () -> Unit): State<S, E> {
    if (this is State.Empty) action()
    return this
}

inline fun <S, E> State<S, E>.onServerError(action: (E?) -> Unit): State<S, E> {
    if (this is State.Error.Server) action(error)
    return this
}

inline fun <S, E> State<S, E>.onNetworkError(action: () -> Unit): State<S, E> {
    if (this is State.Error.Network) action()
    return this
}

inline fun <S, E> State<S, E>.onTimeout(action: () -> Unit): State<S, E> {
    if (this is State.Error.Timeout) action()
    return this
}
```

---

## 4. Response to State Conversion

The conversion of Response to State happens in `NetworkHandler.makeApiCall`. Add an `OkHttpClient` interceptor to Retrofit for logging or request modification; the conversion to State is done when the repository calls `makeApiCall`.

### Retrofit Setup with Interceptor

```kotlin
val okHttpClient = OkHttpClient.Builder()
    .addInterceptor { chain ->
        val request = chain.request()
        Log.d("Api", "Request: ${request.url}")
        val response = chain.proceed(request)
        Log.d("Api", "Response: ${response.code}")
        response
    }
    .build()

val retrofit = Retrofit.Builder()
    .baseUrl(BASE_URL)
    .client(okHttpClient)
    .addConverterFactory(MoshiConverterFactory.create(moshi))
    .build()

val portfolioApi = retrofit.create(PortfolioApi::class.java)
```

### Default Error JSON

APIs often return error JSON like:

```json
{ "errorCode": "INSUFFICIENT_FUNDS", "errorDescription": "Balance below minimum." }
```

`Error` maps this. Use `makeApiCall(apiCall, successMapper)` when your API follows this format.

---

## 5. API Call Examples (Retrofit + NetworkHandler)

Use `NetworkHandler` to make API calls. `makeApiCall` converts `Response` to `State`; the repository never sees `Result`. Use `makeApiCall` with success mapper only when default error mapping applies, or with both mappers for custom APIs.

### NetworkHandler

```kotlin
class NetworkHandler(private val moshi: Moshi) {
    private val defaultErrorAdapter = moshi.adapter<Error>()

    suspend fun <T, R> makeApiCall(
        apiCall: suspend () -> Response<T>,
        successMapper: (T) -> R,
        errorAdapter: JsonAdapter<Error>? = null  // uses defaultErrorAdapter when null
    ): State<R, Error> = makeApiCall(apiCall, successMapper) { response ->
        val adapter = errorAdapter ?: defaultErrorAdapter
        response.errorBody()?.string()?.let { adapter.fromJson(it) }
            ?: Error(null, response.message(), response.code())
    }

    suspend fun <T, R, E> makeApiCall(
        apiCall: suspend () -> Response<T>,
        successMapper: (T) -> R,
        errorMapper: (Response<T>) -> E?
    ): State<R, E> {
        return try {
            val response = apiCall()
            when {
                response.isSuccessful -> State.Data(successMapper(response.body()!!))
                response.code() == -1 -> State.Error.Network  // -1 when no connection
                else -> State.Error.Server(errorMapper(response))
            }
        } catch (e: IOException) {
            State.Error.Network
        } catch (e: Exception) {
            State.Error.Server(null)
        }
    }
}
```

### Example 1: Default Error Mapping

Uses `defaultErrorAdapter` when `errorAdapter` is omitted. Pass a custom adapter when your API's error JSON differs.

```kotlin
// Repository
suspend fun loadPortfolio(id: String): State<PortfolioSummary, Error> =
    networkHandler.makeApiCall(
        apiCall = { portfolioApi.getPortfolio(id) },
        successMapper = { it.toPortfolioSummary() }
    )

// ViewModel
launchIO {
    _screenState.value = State.Progress
    _screenState.value = repository.loadPortfolio(id)
}
```

### Example 2: Custom Error Mapping

Order placement: custom 201 success, map `OrderStatusError` to `Error`.

```kotlin
data class OrderStatusError(val orderId: String?, val status: String?, val rejectionReason: String?)

// Repository
suspend fun placeOrder(request: OrderPlaceRequest): State<OrderPlaceResponse, Error> =
    networkHandler.makeApiCall(
        apiCall = { investmentApi.placeOrder(request) },
        successMapper = { it },
        errorMapper = { response ->
            response.errorBody()?.string()?.let { json ->
                moshi.adapter<OrderStatusError>().fromJson(json)
            }?.let { err -> Error(err.status, err.rejectionReason, response.code()) }
        }
    )
```

---

## 6. Architecture: Where Conversion Happens

```
+-----------------------------------------------------------------------------+
| Retrofit API                                                                |
| - Returns Response<T>                                                       |
+-----------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------+
| NetworkHandler.makeApiCall                                                  |
| - Converts Response -> State                                                |
| - Default: successMapper only; errors -> State.Error.Server/Network        |
| - Custom: errorMapper for APIs with custom error models                     |
+-----------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------+
| Repository / Use Case                                                       |
| - Receives State from NetworkHandler.makeApiCall                            |
| - Returns State to ViewModel                                                |
+-----------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------+
| ViewModel                                                                   |
| - Receives State<T>, emits StateFlow<State<T>>                              |
+-----------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------+
| Screen                                                                      |
| - Collects StateFlow, uses .onProgress{}, .onData{}, .onEmpty{}, .onServerError{}, etc. |
+-----------------------------------------------------------------------------+
```

**Note:** Retrofit returns `Response`; `NetworkHandler.makeApiCall` converts it to `State`. The repository never sees raw `Response` or `Result`.

---

## 7. Summary

| Concept | Description |
|---------|-------------|
| **State sealed interface** | `State<SuccessModel, ErrorModel>`: `Progress`, `Data`, `Empty`, `Error` |
| **Error** | Default error model: `errorCode`, `errorDescription`, `httpStatus` |
| **State.Error** | `Server(error)`, `Network`, `Timeout`; use `Error` or custom |
| **Conversion** | `NetworkHandler.makeApiCall` converts `Response` → `State` at network boundary |
| **NetworkHandler** | `makeApiCall(apiCall, successMapper, errorAdapter?)`; default adapter when null |
| **ViewModel.launchIO** | Runs repository/API calls on `Dispatchers.IO` |
| **StateFlow.collectWhenStarted** | Lifecycle-aware collection; uses current value as initial |
| **State extensions** | `onProgress`, `onData`, `onEmpty`, `onServerError`, `onNetworkError`, `onTimeout` |

Together, these patterns give you consistent state handling, centralized error conversion, and flexibility for APIs that need custom models or success codes.
