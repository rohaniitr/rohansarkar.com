---
layout: default
title: Configuration-Driven Architecture
date: 2026-03-02
excerpt: How three related patterns—config-driven app setup, router-based navigation, and builder-style screen configuration—enable a flexible, testable, and customizable Android architecture.
---

# Configuration-Driven Architecture: App, Routing, and Screen Configuration

**How three related patterns—config-driven app setup, router-based navigation, and builder-style screen configuration—enable a flexible, testable, and customizable Android architecture.**

---

## Introduction

In a large, multi-journey fintech or investment app (e.g. portfolio management, order placement, trading), you often need to:

- **Customize** behavior per customer or environment without forking code
- **Override** navigation flows for different app variants
- **Theme** screens and components without hardcoding strings or drawables

Three patterns work together to achieve this:

1. **Configuration-driven app architecture** – App-level setup is driven by configuration objects
2. **Router pattern for navigation** – Navigation is configurable: abstract interfaces + injectable implementations
3. **Builder pattern for screen configuration** – Screens and components are configured via builders with sensible defaults

This post explains how these patterns fit together and how to implement them.

---

## 1. Configuration-Driven App Architecture

### What It Is

Instead of hardcoding app setup, you define a configuration object that describes how the app should behave. The app reads this configuration at startup and wires everything accordingly.

### Structure

```
Application
    └── createApplicationConfiguration()
            └── ApplicationConfiguration { ... }
                    ├── sdkConfiguration
                    ├── networkingConfiguration
                    ├── journeyConfigurationsDefinitions
                    ├── pushNotificationConfiguration
                    └── featureFlags
```

Each journey (feature module) has its own configuration definition. The app composes them into a single configuration tree.

### Example: DSL-Style Configuration

```kotlin
// Application
override fun createApplicationConfiguration() = ApplicationConfiguration {
    pushNotificationConfiguration = PushNotificationConfiguration { ... }
    featureFlags += listOf(EnableAdvisoryService)
}

// Journey configuration definitions
fun JourneyConfigurationsDefinitions(initializer: Builder.() -> Unit) =
    JourneyConfigurationsDefinitions.Builder().apply(initializer).build()
```

### Example: Journey-Level Configuration

```kotlin
// Each journey has a configuration
orderPlacementConfigurationDefinition = {
    OrderPlacementConfiguration { }
}

portfolioDashboardConfigurationDefinition = {
    PortfolioDashboardConfiguration { }
}

// Nested configuration
portfolioReportingConfigurationDefinition = {
    PortfolioReportingConfiguration {
        portfolioReportingScreenConfiguration = PortfolioReportingScreenConfiguration {
            overviewTabScreenConfiguration = OverviewScreenConfiguration {
                holdingsCardConfiguration = HoldingsCardConfiguration {
                    itemIsInteractive = true
                }
            }
        }
    }
}
```

### Benefits

- **Single source of truth** – All setup lives in configuration
- **Customization** – Consumers override only what they need
- **Testability** – Tests inject minimal config
- **Feature flags** – Flags drive which config branches are used

---

## 2. Router Pattern for Navigation (Config for Routing)

### What It Is

Navigation is treated as configuration: instead of screens calling `findNavController().navigate()` directly, they use a **router interface**. The router is injected and can be swapped per environment or test.

### Why Routers Are "Config for Routing"

- The **router interface** defines the navigation contract (what actions exist)
- The **implementation** is injected (like config) and can be replaced
- The **default implementation** uses `NavController`; tests override with no-ops or custom behavior

### Structure

```
Screen
    └── injected OrderSummaryRouter
            └── onOrderPlacementSuccess()  →  navigate to success
            └── onOrderPlacementFailure(code)  →  navigate to error

DefaultOrderSummaryRouter(navController)
    └── implements OrderSummaryRouter
```

### Example: Router Interface

```kotlin
interface OrderSummaryRouter {

    fun onOrderPlacementSuccess()

    fun onOrderPlacementFailure(code: String?)
}

interface OrderInputRouter {

    fun onOrderDraftSuccess()

    fun onOrderDraftFailure(code: String?)
}
```

### Example: Default Implementation

```kotlin
class DefaultOrderSummaryRouter(
    private val navController: NavController
) : OrderSummaryRouter {

    override fun onOrderPlacementSuccess() {
        navController.navigate(R.id.action_summary_to_success)
    }

    override fun onOrderPlacementFailure(code: String?) {
        navController.navigate(
            R.id.action_summary_to_setup_error,
            code?.let { bundleOf(OrderSetupErrorScreen.ARG_KEY_CODE to it) }
        )
    }
}
```

### Example: Injection (Router as Config)

```kotlin
// DI module
factory<OrderSummaryRouter> { (navController: NavController) ->
    DefaultOrderSummaryRouter(navController)
}

// Screen
private val screenRouter by scoped<OrderSummaryRouter> { 
    parametersOf(findNavController()) 
}

// Usage
viewModel.placeOrderAction.collect { placement ->
    when (placement) {
        is State.Data -> screenRouter.onOrderPlacementSuccess()
        is State.Error -> screenRouter.onOrderPlacementFailure(placement.error.code)
        else -> { }
    }
}
```

### Benefits

- **Testability** – Tests inject a fake router that does nothing or asserts calls
- **Flexibility** – Different apps can override routing (e.g. different success screen)
- **Decoupling** – Screens don't depend on `NavController` or navigation IDs

---

## 3. Builder Pattern for Screen Configuration

### What It Is

Each screen (or component) has a **configuration class** that holds all customizable aspects: titles, icons, labels, error messages, etc. A **Builder** provides defaults; consumers override only what they need.

### Deferred Resources

To support theming and late resolution, use **deferred resources** (`DeferredText`, `DeferredDrawable`) instead of raw strings:

- `DeferredText.Resource(R.string.foo)` – resolve at runtime from resources
- `DeferredText.Resolved("literal")` – fixed string
- `DeferredText.Attribute(R.attr.foo)` – theme attribute

### Structure

```
Screen
    └── injected ScreenConfiguration
            ├── title: DeferredText
            ├── description: DeferredText
            ├── applyChangesButtonText: DeferredText
            ├── errorDialogConfiguration: EdgeCaseDialogConfiguration
            └── portfolioSelectionConfiguration: PortfolioSelectionConfiguration
```

### Example: Screen Configuration with Builder

```kotlin
class CustomizePortfolioScreenConfiguration(
    val navigateUpIcon: DeferredDrawable,
    val navigateUpContentDescription: DeferredText,
    val title: DeferredText,
    val description: DeferredText,
    val applyChangesButtonText: DeferredText,
    val errorDialogConfiguration: EdgeCaseDialogConfiguration,
    val componentsConfiguration: CustomizePortfolioComponentConfiguration,
    val portfolioSelectionConfiguration: PortfolioSelectionConfiguration,
) {

    class Builder {

        var navigateUpIcon: DeferredDrawable =
            DeferredDrawable.Attribute(R.attr.iconClose)

        var title: DeferredText =
            DeferredText.Resource(R.string.dashboard_customize_title)

        var description: DeferredText =
            DeferredText.Resource(R.string.dashboard_customize_description)

        var applyChangesButtonText: DeferredText =
            DeferredText.Resource(R.string.dashboard_customize_apply_button)

        var errorDialogConfiguration: EdgeCaseDialogConfiguration =
            EdgeCaseDialogConfiguration { ... }

        fun build(): CustomizePortfolioScreenConfiguration { ... }
    }
}

// DSL
fun CustomizePortfolioScreenConfiguration(
    block: CustomizePortfolioScreenConfiguration.Builder.() -> Unit
): CustomizePortfolioScreenConfiguration =
    CustomizePortfolioScreenConfiguration.Builder().apply(block).build()
```

### Example: Function-Based Configuration

```kotlin
class OrderSummaryScreenConfiguration private constructor(
    val orderDurationItemTitle: (String) -> String,
    val orderDurationItemSubtitle: (String, LocalDate?) -> String
) {

    class Builder(...) : OrderPlacementConfigurationBuilder() {

        var orderDurationItemTitle: (String) -> String = { code ->
            when (code) {
                "DAY" -> context.getString(R.string.order_duration_title_day)
                "GTD" -> context.getString(R.string.order_duration_title_gtd)
                "GTC" -> context.getString(R.string.order_duration_title_gtc)
                else -> context.getString(R.string.order_duration_title_fallback, code)
            }
        }

        var orderDurationItemSubtitle: (String, LocalDate?) -> String = { code, date ->
            when (code) {
                "DAY" -> context.getString(R.string.order_duration_subtitle_day)
                "GTD" if date != null -> context.getString(..., formattedDate)
                else -> ...
            }
        }
    }
}
```

### Example: Menu Configuration (Config + Routing)

```kotlin
// Settings menu uses config for both content AND routing
SettingsConfiguration.Builder()
    .apply {
        sections = listOf(
            MenuSection(
                title = DeferredText.Resource(R.string.app_settings_section_security),
                items = listOf(
                    MenuItem(
                        title = DeferredText.Resource(R.string.app_settings_item_logout),
                        icon = DeferredDrawable.Resource(R.drawable.ic_logout) { ... }
                    ) {
                        OnActionComplete.NavigateTo(R.id.action_main_to_login,
                            bundleOf(LOG_OUT_ACTION to true)
                        )
                    }
                )
            )
        )
    }
    .build()
```

Here, `OnActionComplete.NavigateTo` is the routing config: the destination is defined in the menu config, not in the screen code.

### Benefits

- **Customization** – Override only what needs to change
- **Theming** – Deferred resources resolve at runtime
- **Composability** – Screen configs nest (e.g. `PortfolioSelectionConfiguration` inside `CustomizePortfolioScreenConfiguration`)

---

## 4. How They Work Together

```
+-----------------------------------------------------------------------------+
| Application Configuration                                                   |
| ApplicationConfiguration {                                                  |
|   journeyConfigurationsDefinitions = JourneyConfigurationsDefinitions {     |
|     orderPlacementConfig = { OrderPlacementConfiguration {} }               |
|   }                                                                         |
| }                                                                           |
+-----------------------------------------------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
| Journey Configuration (OrderPlacementConfiguration)                         |
|   - orderSetupScreenConfiguration                                           |
|   - orderSummaryScreenConfiguration (Builder pattern)                       |
|   - transactionDetailsScreenConfiguration                                   |
|   - genericErrorBody: (String) -> String                                    |
+-----------------------------------------------------------------------------+
                                     |
                                     v
+-----------------------------------------------------------------------------+
| Screen                                                                      |
|   - Injects journeyConfig (screen configuration)                            |
|   - Injects router (navigation config)                                       |
|   - Uses config for UI: journeyConfig.orderSummaryScreenConfiguration       |
|   - Uses router for navigation: screenRouter.onOrderPlacementSuccess()      |
+-----------------------------------------------------------------------------+
```

### Flow

1. **App startup** – `createApplicationConfiguration()` builds the app config
2. **Journey registration** – Each journey config is registered (e.g. `OrderPlacementConfiguration`)
3. **Screen creation** – Screens receive config and router via DI
4. **UI rendering** – Screens use config for titles, labels, error messages
5. **User actions** – Screens call router methods; router performs navigation

### Override Points

| Level | What to override |
|-------|------------------|
| App | `createApplicationConfiguration()`, `createUseCaseDefinitions()` |
| Journey | `journeyConfigurationsDefinitions` in app config |
| Screen | `orderSetupScreenConfiguration`, `orderSummaryScreenConfiguration`, etc. |
| Component | `HoldingsCardConfiguration`, `PortfolioSelectionConfiguration` |
| Router | `orderPlacementRouterDefinition` (replace default with custom) |

---

## 5. Implementation Checklist

### For App Configuration

- Define a configuration class with a Builder
- Provide a DSL function: `ApplicationConfig { }`
- Use `Definition<T>` (or equivalent) for lazy resolution of journey configs
- Support feature flags to conditionally select config branches

### For Router Pattern

- Define a router interface per screen or flow
- Implement `DefaultXxxRouter` that takes `NavController`
- Register as `factory<Router> { (navController) -> DefaultRouter(navController) }`
- Inject into screens; never call `findNavController()` from business logic

### For Screen Configuration

- Use `DeferredText` / `DeferredDrawable` for themeable content
- Provide a Builder with sensible defaults
- Support nested configuration (screen → component)
- Use DSL: `ScreenConfiguration { }` for Kotlin consumers

---

## 6. Benefits and Pitfalls

### Benefits

| Benefit | Description |
|---------|-------------|
| Customization | Consumers override only what they need |
| Testability | Config and routers are injectable; tests use minimal config |
| Consistency | Same pattern across app, journey, screen, and component |
| Theming | Deferred resources resolve at runtime |
| Decoupling | Screens don't depend on NavController or concrete IDs |

### Pitfalls

1. **Config sprawl** – Too many configs; keep hierarchy shallow and focused
2. **Builder boilerplate** – Use codegen or shared base builders if it grows
3. **Router proliferation** – One router per flow is enough; avoid per-screen routers when unnecessary
4. **Default fatigue** – Ensure defaults are sensible so most consumers don't need to override

---

## 7. Summary

Three patterns work together:

- **Configuration-driven app** – App and journey setup are driven by config objects
- **Router pattern** – Navigation is configurable via abstract interfaces and injectable implementations
- **Builder pattern for screens** – Screens and components are configured via builders with deferred resources

Together they enable a flexible, testable, and customizable architecture where consumers override only what they need.
