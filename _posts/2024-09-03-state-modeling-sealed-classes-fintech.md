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

In investment and trading apps, screens often load data from the network, show progress, handle errors, and display content. Modeling this as a **sealed interface** gives you:

- Exhaustive `when` handling
- Type-safe state transitions
- Clear separation of loading, success, error, and empty states

This post covers:

1. State sealed interface design
2. Result type from generated client vs State in app layer
3. Extension functions for handling (`launchIO`, `collectAsStateWhenStarted`, `onProgress`, `onData`, `onSuccess`, `onError`)
4. Interceptor layer converting Result to State

---

## 1. State Sealed Interface

### Basic Structure

```kotlin
sealed interface State<out T> {

    data object Progress : State<Nothing>

    data class Data<T>(val data: T) : State<T>

    data object Empty : State<Nothing>

    sealed interface Error<out T> : State<T> {

        data class Server(
            val errorCode: String?,
            val errorDescription: String?,
            val httpStatus: Int?
        ) : Error<Nothing>

        data object Network : Error<Nothing>

        data object Timeout : Error<Nothing>
    }
}
```

### Usage in ViewModel

```kotlin
private val _screenState = MutableStateFlow<State<PortfolioSummary>>(State.Progress())
val screenState: StateFlow<State<PortfolioSummary>> = _screenState.asStateFlow()

launchIO {  // ViewModel extension; runs on Dispatchers.IO
    _screenState.value = State.Progress()
    _screenState.value = repository.loadPortfolio(id)  // Repository returns State (converted in interceptor)
}
```

### Usage in Screen

```kotlin
val state by viewModel.screenState.collectAsStateWhenStarted(initialValue = State.Progress)
state
    .onProgress { showLoading() }
    .onData { showContent(it) }
    .onEmpty { showEmpty() }
    .onError { error ->
        when (error) {
            is State.Error.Server -> showError(error.errorCode, error.errorDescription)
            is State.Error.Network -> showNetworkError()
            is State.Error.Timeout -> showTimeoutError()
        }
    }
```

---

## 2. Result vs State

**Result** comes from the generated API client (e.g. OpenAPI codegen). It represents the raw outcome of an API call.

**State** is used in the app layer for UI. The **interceptor layer** converts `Result` to `State` before the data reaches the ViewModel.

```kotlin
// From generated client
sealed class Result<out S, out E> {
    data class Success<S>(val value: S) : Result<S, Nothing>()
    data class Failure<E>(val error: E) : Result<Nothing, E>()
}
```

Flow: `Generated Client (Result)` -> `Interceptor (Result -> State)` -> `ViewModel (StateFlow<State>)` -> `Screen`

---

## 3. Extension Functions for Handling

### ViewModel.launchIO

Launch coroutines on `Dispatchers.IO` for repository or API calls:

```kotlin
fun ViewModel.launchIO(block: suspend CoroutineScope.() -> Unit): Job =
    viewModelScope.launch(Dispatchers.IO, block = block)
```

### StateFlow.collectAsStateWhenStarted (Compose)

Collect `StateFlow` only when the composable's lifecycle is at least `STARTED`. Uses `collectAsStateWithLifecycle` from `androidx.lifecycle:lifecycle-runtime-compose` under the hood. Stops collecting when the screen is stopped (e.g. navigated away), reducing unnecessary work. Add dependency: `androidx.lifecycle:lifecycle-runtime-compose`.

```kotlin
@Composable
fun <T> StateFlow<T>.collectAsStateWhenStarted(
    initialValue: T,
    lifecycle: Lifecycle = LocalLifecycleOwner.current.lifecycle,
    minActiveState: Lifecycle.State = Lifecycle.State.STARTED
): State<T> = collectAsStateWithLifecycle(
    initialValue = initialValue,
    lifecycle = lifecycle,
    minActiveState = minActiveState
)
```

### Result Extensions

```kotlin
inline fun <S, E> Result<S, E>.onSuccess(action: (S) -> Unit): Result<S, E> {
    if (this is Result.Success) action(value)
    return this
}

inline fun <S, E> Result<S, E>.onFailure(action: (E) -> Unit): Result<S, E> {
    if (this is Result.Failure) action(error)
    return this
}
```

### State Extensions

```kotlin
inline fun <T> State<T>.onProgress(action: () -> Unit): State<T> {
    if (this is State.Progress) action()
    return this
}

inline fun <T> State<T>.onData(action: (T) -> Unit): State<T> {
    if (this is State.Data) action(data)
    return this
}

inline fun <T> State<T>.onEmpty(action: () -> Unit): State<T> {
    if (this is State.Empty) action()
    return this
}

inline fun <T> State<T>.onError(action: (State.Error<*>) -> Unit): State<T> {
    if (this is State.Error) action(this)
    return this
}
```

---

## 4. Interceptor Layer: Result to State Conversion

The interceptor receives `Result` from the generated client and converts it to `State`. Error mapping (e.g. JSON body to `State.Error.Server`) happens here.

### Converter: Result -> State

When the client returns `Result<T, State.Error>`:

```kotlin
fun <T> Result<T, State.Error<*>>.toState(): State<T> = when (this) {
    is Result.Success -> State.Data(value)
    is Result.Failure -> error  // State.Error is already the failure type
}
```

When the client returns `Result<S, E>` with a different error type, map both:

```kotlin
inline fun <S, E, T> Result<S, E>.toState(
    successMapper: (S) -> T,
    errorMapper: (E) -> State.Error<*>
): State<T> = when (this) {
    is Result.Success -> State.Data(successMapper(value))
    is Result.Failure -> errorMapper(error)
}
```

### Default Mapping Interceptor

Parses error JSON (errorCode, errorDescription, httpStatus) into `State.Error.Server`:

```json
{ "errorCode": "INSUFFICIENT_FUNDS", "errorDescription": "Balance below minimum." }
```

```kotlin
val DefaultErrorAdapter: JsonAdapter<State.Error.Server> =
    Moshi.Builder().build().adapter(State.Error.Server::class.java)

class DefaultStateInterceptor<T>(
    private val successAdapter: JsonAdapter<T>,
    private val errorAdapter: JsonAdapter<State.Error.Server> = DefaultErrorAdapter
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        // Convert Response -> Result (from client) -> State
        val result = response.toResult(successAdapter, errorAdapter)
        val state = result.toState()
        // Emit state to callbacks/coroutine
        return response
    }
}

fun <T> Response.toResult(
    successAdapter: JsonAdapter<T>,
    errorAdapter: JsonAdapter<State.Error.Server>
): Result<T, State.Error<*>> = when {
    isSuccessful -> Result.Success(successAdapter.fromJson(body!!.string()!!)!!)
    code() == NO_INTERNET -> Result.Failure(State.Error.Network)
    code() in 400..599 -> Result.Failure(
        errorBody()?.string()?.let { errorAdapter.fromJson(it) }
            ?: State.Error.Server(null, null, code())
    )
    else -> Result.Failure(State.Error.Server(null, null, code()))
}
```

### Custom Mapping Interceptor

For order placement: custom success (201), custom error model `OrderStatusError`:

```kotlin
fun Response.toOrderPlaceState(): State<OrderPlaceResponse> = when {
    code() in listOf(200, 201) -> State.Data(parseOrderPlaceSuccess(this))
    code() == NO_INTERNET -> State.Error.Network
    else -> State.Error.Server(
        errorCode = parseOrderError(this)?.errorCode,
        errorDescription = parseOrderError(this)?.rejectionReason,
        httpStatus = code()
    )
    // Or use OrderStatusError -> State.Error variant if needed
}
```

---

## 5. API Call Examples

### Example 1: API Call with Default Mapping

Generated client returns `Result<PortfolioResponse, ClientError>`. Interceptor converts to `State` using default error mapping (ClientError/JSON → `State.Error`).

```kotlin
// Repository: receives State from interceptor-wrapped client
suspend fun loadPortfolio(id: String): State<PortfolioSummary> {
    return portfolioClient.getPortfolio(id)  // Returns State (interceptor did Result->State)
}

// Or, if repository calls raw client and converts:
suspend fun loadPortfolio(id: String): State<PortfolioSummary> {
    return portfolioApi.getPortfolio(id)  // Result<PortfolioResponse, ClientError>
        .toState(
            successMapper = { it.toPortfolioSummary() },
            errorMapper = { clientError ->
                clientError.body?.string()?.let { json ->
                    moshi.adapter<State.Error.Server>().fromJson(json)
                } ?: State.Error.Server(null, clientError.message, clientError.code)
            }
        )
}

// ViewModel
launchIO {
    _screenState.value = State.Progress()
    _screenState.value = repository.loadPortfolio(id)
}
```

### Example 2: API Call with Custom Mapping

Order placement: custom 201 success, `OrderStatusError` mapped to `State.Error`.

```kotlin
data class OrderStatusError(val orderId: String?, val status: String?, val rejectionReason: String?)

suspend fun placeOrder(request: OrderPlaceRequest): State<OrderPlaceResponse> {
    return investmentApi.placeOrder(request)  // Result<OrderPlaceResponse, OrderStatusError>
        .toState(
            successMapper = { it },
            errorMapper = { orderError ->
                State.Error.Server(
                    errorCode = orderError.status,
                    errorDescription = orderError.rejectionReason,
                    httpStatus = null
                )
            }
        )
}

// Custom 201 handling happens in client/interceptor layer
// successCodes = listOf(200, 201); 201 response parsed as OrderPlaceResponse
```

---

## 6. Architecture: Where Conversion Happens

```
+-----------------------------------------------------------------------------+
| Generated API Client                                                        |
| - Returns Result<Success, Error> (Success and Error types from API spec)    |
+-----------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------+
| Interceptor Layer                                                           |
| - Converts Result -> State                                                  |
| - Default: maps success to State.Data, errors to State.Error.Server/Network |
| - Custom: per-request mapping (e.g. 201, OrderStatusError -> State.Error)  |
+-----------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------+
| Repository / Use Case                                                       |
| - Receives State<T> from interceptor-wrapped client                         |
| - Returns State<T> to ViewModel                                             |
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
| - Collects StateFlow, uses .onProgress{}, .onData{}, .onError{}             |
+-----------------------------------------------------------------------------+
```

**Note:** Result and State are independent. Result comes from the generated client; State is the app-layer model. The interceptor converts Result → State so the rest of the app never sees raw Result.

---

## 7. Summary

| Concept | Description |
|---------|-------------|
| **State sealed interface** | `Progress`, `Data`, `Empty`, `Error` for UI state |
| **State.Error** | Sealed interface with `Server`, `Network`, `Timeout`; error mapping shown in interceptor examples |
| **Result** | From generated client: `Success(value)`, `Failure(error)`; independent of State |
| **Interceptor** | Converts `Result` → `State`; error JSON parsed to `State.Error.Server` here |
| **ViewModel.launchIO** | Runs repository/API calls on `Dispatchers.IO` |
| **StateFlow.collectAsStateWhenStarted** | Lifecycle-aware collection; stops when screen is stopped |
| **State extensions** | `onProgress`, `onData`, `onEmpty`, `onError` for screen handling |
| **Result extensions** | `onSuccess`, `onFailure` for client/Repository when needed |
| **Default mapping** | `Result<Success, State.Error>` → `State.Data` / `State.Error` |
| **Custom mapping** | Per-request override (e.g. 201, `OrderStatusError` → `State.Error`) |

Together, these patterns give you consistent state handling, centralized error conversion, and flexibility for APIs that need custom models or success codes.
