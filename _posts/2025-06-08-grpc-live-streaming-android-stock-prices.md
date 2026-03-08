---
layout: default
title: Live Streaming Data with gRPC and Heartbeat on Android
date: 2025-06-08
excerpt: How to implement a one-way gRPC stream for real-time stock prices in an investment app, with a base ViewModel pattern, clear layering, and memory-leak prevention.
---

# Live Streaming Data with gRPC and Heartbeat on Android

**How to implement a one-way gRPC stream for real-time stock prices in an investment app, with a base ViewModel pattern, clear layering, and memory-leak prevention.**

---

## Introduction

Investment apps need real-time stock prices. Polling every few seconds is wasteful and introduces latency. A better approach is **server streaming over gRPC**: the client opens a stream with a list of symbols, and the backend pushes price updates as they occur.

This post covers:

1. **One-way gRPC streaming** – Client sends a request (list of stocks); server streams price updates
2. **Heartbeat** – Keeping the stream alive across idle periods and flaky networks
3. **Base ViewModel pattern** – Centralize streaming in a base class; extend for any screen that needs live prices
4. **Layering** – Screen → ViewModel → Repo → Use case
5. **Memory-leak prevention** – Proper cancellation and lifecycle handling

---

## 1. gRPC Service Definition

Define a **server streaming** RPC: the client sends a request once; the server responds with a stream of messages.

```protobuf
// stock_stream.proto
syntax = "proto3";

package investments.stockstream;

service StockStreamService {
  // Client sends list of symbols; server streams price updates (and heartbeats)
  rpc StreamPrices(StreamPricesRequest) returns (stream StreamMessage);
}

message StreamPricesRequest {
  repeated string symbols = 1;  // e.g. ["AAPL", "GOOGL", "MSFT"]
}

message StreamMessage {
  oneof payload {
    StockPriceUpdate price_update = 1;
    Heartbeat heartbeat = 2;
  }
}

message StockPriceUpdate {
  string symbol = 1;
  double price = 2;
  double change_percent = 3;
  int64 timestamp_ms = 4;
}

message Heartbeat {
  int64 timestamp_ms = 1;
}
```

The server sends `StreamMessage` with either `price_update` or `heartbeat` set. Heartbeats keep the connection alive when there are no price changes.

---

## 2. Use Case Layer

The use case defines the contract: start a stream, receive updates, and stop when done.

```kotlin
// StockStreamUseCase.kt
interface StockStreamUseCase {

    /**
     * Opens a stream for the given symbols.
     * Emits [StockPriceUpdate] or [Heartbeat] until [close] is called.
     */
    fun streamPrices(symbols: List<String>): Flow<StreamEvent>

    suspend fun close()
}

sealed class StreamEvent {
    data class PriceUpdate(val symbol: String, val price: Double, val changePercent: Double, val timestampMs: Long) : StreamEvent()
    data class Heartbeat(val timestampMs: Long) : StreamEvent()
    data class Error(val throwable: Throwable) : StreamEvent()
}
```

---

## 3. Repository Implementation

The repository wraps the gRPC stub and exposes a `Flow`. It maps protobuf messages to domain types and uses `Context.withCancellation()` for clean stream teardown.

```kotlin
// StockStreamRepository.kt
class StockStreamRepository(
    private val stockStreamStub: StockStreamServiceGrpc.StockStreamServiceStub
) : StockStreamUseCase {

    @Volatile
    private var cancellableContext: CancellableContext? = null

    override fun streamPrices(symbols: List<String>): Flow<StreamEvent> = callbackFlow {
        val request = StreamPricesRequest.newBuilder().addAllSymbols(symbols).build()
        val ctx = Context.current().withCancellation()
        cancellableContext = ctx

        val observer = object : StreamObserver<StreamMessage> {
            override fun onNext(value: StreamMessage) {
                value.toStreamEvent()?.let { trySend(it) }
            }
            override fun onError(t: Throwable) {
                trySend(StreamEvent.Error(t))
                close(t)
            }
            override fun onCompleted() = close()
        }

        ctx.attach().let { prev ->
            try { stockStreamStub.streamPrices(request, observer) }
            finally { ctx.detach(prev) }
        }

        awaitClose { cancellableContext?.cancel(null); cancellableContext = null }
    }

    override suspend fun close() {
        cancellableContext?.cancel(null)
        cancellableContext = null
    }
}

private fun StreamMessage.toStreamEvent(): StreamEvent? = when (payloadCase) {
    StreamMessage.PayloadCase.PRICE_UPDATE -> {
        val p = priceUpdate
        StreamEvent.PriceUpdate(p.symbol, p.price, p.changePercent, p.timestampMs)
    }
    StreamMessage.PayloadCase.HEARTBEAT -> StreamEvent.Heartbeat(heartbeat.timestampMs)
    else -> null
}
```

**Heartbeat handling:** The server sends `Heartbeat` periodically (e.g. every 30 seconds) when there are no price changes. The client receives it in `onNext` and can ignore it or use it for a "last seen" indicator. The key is that the stream stays open—no timeout, no idle disconnect.

*Dependencies: `io.grpc:grpc-stub`, `io.grpc:grpc-protobuf`, `kotlinx.coroutines:kotlinx-coroutines-core`*

---

## 4. Base ViewModel: Centralize Streaming

Put the streaming logic in a **base ViewModel** so any screen that needs live prices can extend it. The base class owns the stream lifecycle and exposes a shared `StateFlow` of price updates.

```kotlin
// BaseStockStreamViewModel.kt
abstract class BaseStockStreamViewModel(
    private val stockStreamUseCase: StockStreamUseCase
) : BaseViewModel() {

    private val _stockPrices = MutableStateFlow<Map<String, StockPriceUi>>(emptyMap())
    val stockPrices: StateFlow<Map<String, StockPriceUi>> = _stockPrices.asStateFlow()

    private val _streamState = MutableStateFlow<StreamState>(StreamState.Idle)
    val streamState: StateFlow<StreamState> = _streamState.asStateFlow()

    private var streamJob: Job? = null

    protected abstract fun getSymbols(): List<String>

    protected fun startStreaming() {
        if (streamJob?.isActive == true) return

        streamJob = viewModelScope.launch {
            _streamState.value = StreamState.Connecting
            stockStreamUseCase.streamPrices(getSymbols())
                .catch { _streamState.value = StreamState.Error(it.message ?: "Unknown error") }
                .collect { handleStreamEvent(it) }
        }
    }

    protected fun stopStreaming() {
        streamJob?.cancel()
        streamJob = null
        _streamState.value = StreamState.Idle
    }

    override fun onCleared() {
        stopStreaming()
        super.onCleared()
    }

    private fun handleStreamEvent(event: StreamEvent) {
        when (event) {
            is StreamEvent.PriceUpdate -> {
                _streamState.value = StreamState.Active
                _stockPrices.update { it + (event.symbol to event.toUi()) }
            }
            is StreamEvent.Heartbeat -> _streamState.value = StreamState.Active
            is StreamEvent.Error -> _streamState.value = StreamState.Error(event.throwable.message ?: "Error")
        }
    }
}

private fun StreamEvent.PriceUpdate.toUi() = StockPriceUi(symbol, price, changePercent, timestampMs)

sealed class StreamState {
    object Idle : StreamState()
    object Connecting : StreamState()
    object Active : StreamState()
    data class Error(val message: String) : StreamState()
}

data class StockPriceUi(
    val symbol: String,
    val price: Double,
    val changePercent: Double,
    val lastUpdateMs: Long
)
```

---

## 5. Extending the Base ViewModel

Screens that need live prices extend `BaseStockStreamViewModel` and implement `getSymbols()`. Start streaming once you have symbols; the base handles cleanup in `onCleared`.

```kotlin
// PortfolioHoldingsViewModel.kt
class PortfolioHoldingsViewModel(
    stockStreamUseCase: StockStreamUseCase,
    private val getHoldingsUseCase: GetHoldingsUseCase,
    private val portfolioId: String
) : BaseStockStreamViewModel(stockStreamUseCase) {

    private val _holdings = MutableStateFlow<List<HoldingUi>>(emptyList())
    val holdings: StateFlow<List<HoldingUi>> = _holdings.asStateFlow()

    override fun getSymbols(): List<String> =
        _holdings.value.map { it.symbol }.distinct()

    init {
        viewModelScope.launch {
            getHoldingsUseCase(portfolioId).onSuccess { holdings ->
                _holdings.value = holdings.map { it.toUi() }
                startStreaming()
            }
        }
    }
}
```

---

## 6. Screen → ViewModel → Repo → Use Case

The layering stays clean:

```
Screen (Compose / XML)
    │ observes stockPrices, streamState
    ▼
ViewModel (PortfolioHoldingsViewModel extends BaseStockStreamViewModel)
    │ calls startStreaming(), stopStreaming()
    │ implements getSymbols()
    ▼
Repository (StockStreamRepository implements StockStreamUseCase)
    │ streamPrices(symbols): Flow<StreamEvent>
    │ close()
    ▼
gRPC Stub (StockStreamServiceStub)
```

The **use case interface** lives in a core module; the **repository implementation** lives in a data or network module. ViewModels depend on the interface, not the concrete repository. This keeps testing simple: inject a fake `StockStreamUseCase` that emits test data.

---

## 7. Avoiding Memory Leaks

Streaming holds resources: network connections, coroutines, and observers. If not cleaned up, they can leak and keep references to Activities or Fragments.

### 7.1 Cancel on ViewModel Clear

Always stop the stream and cancel the scope when the ViewModel is cleared:

```kotlin
override fun onCleared() {
    stopStreaming()
    scope.cancel()
    super.onCleared()
}
```

### 7.2 Use viewModelScope for All Coroutines

The base ViewModel uses `viewModelScope` for the stream job. When the ViewModel is cleared, `viewModelScope` is cancelled automatically, which stops the stream collection. Child ViewModels should also use `viewModelScope` for one-off jobs:

```kotlin
// In child ViewModel
viewModelScope.launch {
    getHoldingsUseCase(portfolioId).onSuccess { ... }
}
```

### 7.3 Avoid Capturing Screen References

Never pass `Activity`, `Fragment`, or `Context` into the ViewModel. If you need context for resources, use `Application` or inject a `Context` that is application-scoped.

```kotlin
// BAD
class MyViewModel(private val activity: Activity) : BaseStockStreamViewModel(...)

// GOOD
class MyViewModel(
    private val context: Context,  // Application context from DI
    ...
) : BaseStockStreamViewModel(...)
```

### 7.4 Use WeakReference for Callbacks (If Needed)

If you must pass a callback from the screen to the ViewModel (e.g. for one-off navigation), use a `WeakReference` or prefer one-shot events (e.g. `SharedFlow` with `replay = 0`) so the screen can collect and the reference is not held.

### 7.5 Repository Scope Ownership

When the ViewModel cancels the stream job, the flow collection is cancelled and the repository's `awaitClose` runs, which cancels the gRPC context. The repository does not hold references to ViewModels or long-lived scopes.

---

## 8. Heartbeat: Why and How

**Why:** Long-lived streams can be closed by proxies, load balancers, or the OS when there is no traffic. A **heartbeat** (periodic message from server to client) keeps the connection active.

**How:** The server sends a `Heartbeat` message every N seconds (e.g. 30) when there are no price updates. The client receives it in `onNext`. You can:

- **Ignore it** – The act of receiving it keeps the stream alive
- **Use it for UI** – Show "Last updated X seconds ago" or a connection health indicator
- **Detect stalls** – If no `Heartbeat` or `PriceUpdate` for 2× the heartbeat interval, consider the stream dead and reconnect

```kotobuf
// If using oneof in proto
message StreamMessage {
  oneof payload {
    StockPriceUpdate price_update = 1;
    Heartbeat heartbeat = 2;
  }
}
```

---

## 9. Summary

| Topic | Approach |
|-------|----------|
| **Stream type** | One-way server stream: client sends symbols, server streams price updates |
| **Heartbeat** | Server sends periodically; keeps connection alive; client can use for liveness |
| **Architecture** | Screen → ViewModel → Repo → Use case |
| **Base ViewModel** | `BaseStockStreamViewModel` owns stream lifecycle; child ViewModels implement `getSymbols()` and call `startStreaming()` / `stopStreaming()` |
| **Memory leaks** | Cancel scope and stream in `onCleared`; avoid capturing Activity/Fragment; use application-scoped context |

With this setup, any screen that needs real-time stock prices can extend the base ViewModel, provide its symbols, and receive live updates without duplicating streaming logic.
