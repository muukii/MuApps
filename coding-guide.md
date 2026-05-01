# Coding Aesthetics Guide

A guide to the coding philosophy and practices.

---

## Sitemap

### Part 1: The Engineer We Aspire to Be
- [The Craftsman's Mindset](#the-craftsmans-mindset) — Master tools, cultivate aesthetics, align with team
- [Confronting the Blackbox](#confronting-the-blackbox) — Deep investigation, workarounds, expanding scope
- [Guiding Principles](#guiding-principles) — Type safety, clarity, explicitness, composition, data flow
- [Sustainable Code Design](#sustainable-code-design) — Preventing entropy, asset vs liability, trade-offs

### Part 2: Practical Patterns
- [View Composition](#view-composition) — Data-centric views, stateful/stateless separation, fileprivate isolation
- [State Management](#state-management) — StateGraph, reactive patterns
- [Architecture & Dependencies](#architecture--dependencies) — Module layers, context injection
- [Naming & Style Conventions](#naming--style-conventions) — Self-documenting names, enum branching, structured switch, enum vs struct
- [Properties vs Functions](#properties-vs-functions) — When to use each
- [Error Handling & Async](#error-handling--async) — Task lifecycle, defer
- [Documentation](#documentation) — Document why, not what
- [Code Hygiene & Maintainability](#code-hygiene--maintainability) — YAGNI, delete aggressively
- [Animation & Motion](#animation--motion) — Spring-first curves, cross-fade transitions, behavior over animation
- [Quick Reference](#quick-reference) — DO / DON'T

---

# Part 1: The Engineer We Aspire to Be

---

## The Craftsman's Mindset

### Master Your Tools
Deep knowledge of your tools—language features, frameworks, compiler—expands your vocabulary for expression. The richer your vocabulary, the more precisely you can express intent with minimal trade-offs.

### Cultivate Your Aesthetic Sense
Develop your own definition of what makes code beautiful. Hold it as a thesis, not a dogma—refine it daily through practice, reading, and reflection.

### Personal Standards Above the Baseline, Team Alignment at the Baseline
Your personal craft can exceed the team's guidelines. But where the team sets a baseline, align with it. Individual excellence and collective consistency are not opposites.

---

## Confronting the Blackbox

### Philosophy

Core frameworks (UIKit, SwiftUI, Foundation) are ultimately blackboxes. We cannot see their source code, yet we must build on top of them. This reality shapes how we grow as engineers.

### The Workaround Trap

Workarounds are inevitable when working with blackboxes. The question is not whether to use them, but how you arrive at them.

| Approach | What You Gain |
|----------|---------------|
| "It works, move on" | Immediate progress, but isolated knowledge |
| "Why does this work?" | Understanding that connects to other knowledge |
| "What causes this?" | Insight that may eliminate the need for workarounds |

**Skill is not the accumulation of workarounds.** That's just knowledge. Skill is the connected graph of understanding that lets you navigate new problems.

### Levels of Resolution

The same "workaround" looks different at different skill levels:

| Level | Behavior | Growth Opportunity |
|-------|----------|-------------------|
| Beginner | Find workaround, move on | Natural and acceptable at this stage |
| Intermediate | Ask "why does this work?" | Start building the knowledge graph |
| Advanced | Understand the cause, choose to workaround or fix structurally | Can take larger actions when appropriate |

The key is **self-awareness**: knowing which level you're operating at, and occasionally pushing beyond it.

### Expand Your Scope

Often, the root cause of a problem lies outside your immediate area of responsibility.

- A SwiftUI View bug may originate in the UIKit integration layer
- A Feature module issue may stem from AppService design
- A performance problem may be caused by framework internals

**If you only look within your scope, you miss the real cause.**

Expanding your investigation scope is not "going out of your lane" — it's how you grow. The boundaries you cross during debugging become the expanded territory of your expertise.

### The Power of Larger Actions

Deep investigation reveals options that shallow investigation cannot see:

```
Surface-level: Add workaround → Problem "solved"

Deep investigation:
    ↓ Why is this workaround needed?
    ↓ What is the actual cause?
    ↓ Can we restructure to eliminate the need?

Result: Architectural change that removes entire classes of workarounds
```

Sometimes the right answer is not a clever fix, but a structural change. You can only see this option if you dig deep enough.

### When to Stop Digging

Blackboxes are, by definition, unknowable at some level. The goal is not to understand everything, but to:

1. **Recognize when you're stopping** — "I don't know why" vs "I know why, and choose not to fix it now"
2. **Document the unknown** — Leave breadcrumbs for future investigation
3. **Build intuition** — Each investigation, even incomplete, strengthens your mental model

The decision to stop is itself a skill. Make it consciously.

---

## Guiding Principles

1. **Type Safety as Documentation** — Let the compiler enforce correctness. Well-designed types communicate intent better than comments.

2. **Clarity over Cleverness** — Code should be immediately understandable. Prefer explicit, readable patterns over clever shortcuts.

3. **Explicitness over Magic** — Make dependencies, state changes, and side effects visible. Avoid hidden behaviors.

4. **Composition over Inheritance** — Build complex behavior by combining simple, focused components.

5. **Data Flows Down, Actions Flow Up** — Views receive data; they communicate back through callbacks.

---

## Sustainable Code Design

### Philosophy: Preventing Entropy

Software naturally tends toward complexity over time (entropy increases).
Preventing this isn't about "writing less code" — it's about "thinking through design."

- **Code as Asset**: Well-designed code is reusable and accelerates future development
- **Code as Liability**: Short-sighted code incurs costs with every change
- **Designing Repayable Debt**: When time constraints force compromises, structure code for easy future refactoring
- **Trade-offs Are Everywhere**: Less code is not inherently better; excellent engineers evaluate from multiple perspectives

### Mindset: Asset vs Liability

Before writing new code, ask:
1. Will this code make future changes **easier** or **harder**?
2. When similar patterns appear elsewhere, will this code serve as a **reference** or a **cautionary tale**?
3. Will you (or your teammates) **understand** this code in 6 months, or will it require **deciphering**?

### Practice

#### Intentional Design

Short-sighted code only satisfies immediate requirements without considering structure. Thoughtful design separates concerns and creates clear boundaries.

Key indicators of intentional design:
- Clear separation of responsibilities (formatting logic vs display logic)
- Boundaries that limit the scope of future changes
- Names that communicate intent

#### Designing Repayable Debt

When you can't achieve the ideal design due to time constraints, at least make it easy to pay back:
- Create clear boundaries between concerns (even if implementation is imperfect)
- Use TODO comments to mark known debt and intended improvements
- Keep related logic grouped so future extraction is straightforward

Hard-to-repay debt: Logic scattered across the codebase, implicit dependencies, mixed concerns in single functions.

Easy-to-repay debt: Clear boundaries, explicit grouping, isolated imperfection that can be replaced without affecting surroundings.

#### Component-Oriented Judgment

When creating new code, ask: Could this pattern be used elsewhere?

**Case A: Used only in one place**
→ Keep it local (fileprivate), don't abstract

**Case B: Generic pattern likely to appear in multiple places**
→ Create a component.

Abstraction judgment criteria:
- The "three-strike rule" is a guideline, not absolute
- Obviously generic patterns can be abstracted on first occurrence
- Conversely, even patterns appearing 3+ times may not warrant abstraction if contexts differ significantly

#### The Trap of Code Sharing

Code sharing is not inherently good. Reducing code quantity is **not** the goal.

**When sharing becomes a liability:**

| Situation | Problem |
|-----------|---------|
| "Looks similar" but different domains | Coupling unrelated features that will diverge |
| Shared code requires many parameters/flags | Complexity exceeds savings |
| Changes require checking all callers | Fear of modification slows development |
| Abstraction requires "escape hatches" | The abstraction doesn't actually fit |

**The real question isn't "Can I share this code?" but:**
- Will these use cases **evolve together** or **diverge**?
- Does sharing make the code **easier** or **harder** to understand?
- Does the abstraction **clarify** intent or **obscure** it?

#### Evaluating Trade-offs

Excellent engineers evaluate trade-offs from multiple perspectives, not just "less code = better."

| Dimension | Sharing Wins | Separation Wins |
|-----------|--------------|-----------------|
| **Bug fixes** | Fix once, applied everywhere | Fix doesn't break unrelated code |
| **Understanding** | Single source of truth | Each context is self-contained |
| **Flexibility** | Consistent behavior guaranteed | Each can evolve independently |
| **Testing** | Test once | Test in isolation, simpler setup |
| **Onboarding** | Learn one pattern | Understand one feature at a time |

**Decision framework:**

1. Are these truly the same concept, or just coincidentally similar?
   - Same concept → Consider sharing
   - Coincidentally similar → Keep separate

2. If requirements change for one use case, should the other change too?
   - Yes, always → Share
   - Sometimes/No → Keep separate

3. Does the shared abstraction have a clear, stable contract?
   - Yes → Share
   - No, it keeps changing → Split it

4. Can you name the abstraction clearly?
   - Good: "PaginatedList", "UserProfileCard" → Good abstraction candidate
   - Bad: "SharedHelper", "CommonUtils", "BaseViewController" → Probably forced sharing

#### Recognizing Short-Sighted Code

Signs that code was written without thought:

| Symptom | Problem |
|---------|---------|
| Magic numbers/strings scattered throughout | Hard to change, easy to miss occurrences |
| Copy-pasted code with slight variations | Bug fixes must be applied N times |
| God objects that "know everything" | Changes ripple unpredictably |
| Deep nesting (if inside if inside if...) | Hard to trace logic flow |
| Implicit dependencies between components | Order-dependent initialization |

---

# Part 2: Practical Patterns

---

## View Composition

### Philosophy

- **Data-centric views**: Views should receive extracted data values, not complex dependencies
- **Fileprivate isolation**: Internal helper views stay private to their file
- **Single responsibility**: Each view does one thing well

### Practice

#### Data Extraction Pattern

Views receive primitive values, not dependencies:

```swift
// ❌ View depends on entity directly
struct VisitorCell: View {
  let visitor: Entities.Visitor

  var body: some View {
    Text(visitor.createdAt.localized(format: .elapsed(.serverTime())))
  }
}

// ✅ View receives extracted values
struct VisitorCell: View {
  let formattedVisitedAt: String
  let formattedAge: String
  let residenceText: String

  var body: some View {
    Text(formattedVisitedAt)
  }
}

// Formatting helpers at file bottom
extension Entities.Visitor {
  fileprivate var formattedVisitedAt: String {
    createdAt.localized(format: .elapsed(.serverTime()))
  }
}
```

#### Reducing Dependency Construction Cost

A view's testability is determined not by how many dependencies it has, but by **how hard each dependency is to construct**. Even a single property can destroy testability if it requires runtime infrastructure to create.

```swift
// ❌ Hard to make previews or tests because of expensive dependency
struct MyView: View {
  let dependency: MyDependency // Requires complex setup to create

  var body: some View {
    ...
  }
}
```

The fix is not "remove dependencies" but **replace hard-to-construct dependencies with easy-to-construct ones**. Split into a binding layer that owns the expensive dependency and a content layer that receives only cheap values:

```swift
// Binding view — owns the dependency
struct MyView: View {
  let dependency: MyDependency

  var body: some View {
    MyViewContent(
      value: dependency.myValue
    )
  }
}

// Content view — only simple values, easy to construct
fileprivate struct MyViewContent: View {
  let value: String

  var body: some View {
    ...
  }
}

// Now MyViewContent is easily testable with literals
#Preview {
  MyViewContent(value: "Test Value")
}
```

The judgment axis: **can you construct this view's dependencies with literals?** If yes, the view is already testable. If not, consider splitting.

#### Callback Signatures with Concurrency Annotations

```swift
fileprivate struct ContentView: View {
  let onSelectItem: @MainActor @Sendable (Item) -> Void
  let onApproach: @MainActor @Sendable (ApproachMode, Item) -> Void
  let onDismiss: @MainActor @Sendable () -> Void
}
```

Always annotate callbacks with `@MainActor @Sendable` for:
- Thread safety guarantees
- Clear execution context
- Swift 6 concurrency compatibility

#### SwiftUI Previews

```swift
#Preview("ItemCell") {
  @Previewable @State var isSelected = false

  ItemCell(
    title: "Sample Item",
    isSelected: isSelected,
    onTap: { isSelected.toggle() }
  )
}
```

---

## State Management

### Philosophy

- **Reactive state is explicit**: Only `@GraphStored` properties trigger updates
- **Computed properties are free**: They track dependencies automatically
- **State flows one direction**: ViewModels own state; Views observe and send actions

### Practice

#### ViewModel Structure with StateGraph

```swift
@MainActor
final class ViewModel: Sendable {
  // Dependencies
  let context: ServiceContexts.LoggedIn.Base

  // Reactive state
  @GraphStored nonisolated private var dataStore: AsyncDataStore<...>
  @GraphStored nonisolated var shouldDisplayButton: Bool = false
  @GraphStored nonisolated var scrolledAndIsAtEnd: Bool = false

  // Task management
  private let taskManager: TaskManager = .init()
  private let cancellables = Cancellables()

  // Computed properties (automatically tracked)
  var displayItems: [DisplayItem] {
    dataStore.value
  }

  var canNextLoad: Bool {
    dataStore.header.hasReachedEnd == false
  }
}
```

Key patterns:
- `@GraphStored` only for mutable reactive properties
- Computed properties derive from `@GraphStored` properties
- `nonisolated` for Sendable-safe access
- `TaskManager` for async task lifecycle

#### UIKit-SwiftUI Bridge

```swift
public init(context: ServiceContexts.LoggedIn.Base) {
  self.viewModel = ViewModel(context: context)

  weak var indirectSelf: MyViewController?

  super.init(
    content: .init(
      bodyViewController: SwiftUIHostingViewController(
        content: { [viewModel = self.viewModel] _ in
          // Pass ViewModel to View - properties accessed in View's body are tracked
          ContentView(
            viewModel: viewModel,
            onAction: { indirectSelf?.handleAction() }
          )
        }
      )
    )
  )

  indirectSelf = self
}
```

**Tracking context rules:**
- ✅ Pass ViewModel to View, access `@GraphStored` properties in View's `body` → automatic tracking
- ⚠️ Access properties directly in the closure (outside View body) → wrap with `ObservationWrapper`

```swift
// ⚠️ If accessing properties in closure, ObservationWrapper is needed
SwiftUIHostingViewController(
  content: { [viewModel] _ in
    ObservationWrapper {
      Text(viewModel.title)  // Property access in closure, not in View body
    }
  }
)
```

#### UIKit Observation with withGraphTracking

```swift
init(context: ServiceContexts.LoggedIn.Base) {
  // ... initialization ...

  do {
    // Reactive state updates
    withGraphTracking {
      withGraphTrackingGroup { [weak self] in
        guard let self else { return }
        if self.isUnlocked {
          self.shouldDisplayButton = false
        } else if self.scrolledAndIsAtEnd && !self.canNextLoad {
          self.shouldDisplayButton = true
        }
      }
    }
    .store(in: cancellables)
  }
}
```

Use `do` blocks for single-use setup code to:
- Signal "this runs exactly once"
- Keep related code together
- Avoid extracting unnecessary helper methods

#### withGraphTrackingMap for Single Properties

```swift
// Direct migration from Verge's ifChanged
withGraphTracking {
  withGraphTrackingMap(from: viewModel, map: { $0.scrolledAndIsAtEnd }) { [weak self] isAtEnd in
    guard let self, isAtEnd else { return }
    self.presentFeature()
  }
}
.store(in: cancellables)
```

#### Choosing Between withGraphTrackingMap and withGraphTrackingGroup

| Use Case | Function | Why |
|----------|----------|-----|
| Observe single property | `withGraphTrackingMap` | Filters duplicates automatically |
| Compute derived value | `withGraphTrackingMap` | Only fires when result changes |
| Multiple properties → one UI update | `withGraphTrackingGroup` | Combines related updates |
| Need every change (no filtering) | `withGraphTrackingGroup` | No Equatable comparison |

```swift
// ✅ withGraphTrackingMap: Fires only when bannerState VALUE changes
withGraphTrackingMap(from: viewModel, map: { $0.bannerState }) { [weak self] banner in
  self?.updateBanner(banner)
}

// ✅ withGraphTrackingGroup: Fires when ANY accessed property changes
withGraphTrackingGroup { [weak self] in
  let me = viewModel.me
  let count = viewModel.unreadCount
  self?.updateHeader(me: me, count: count)
}

// ❌ Anti-pattern: Unrelated properties in same group
withGraphTrackingGroup { [weak self] in
  self?.updateA(viewModel.propertyA)  // B changes → A updates unnecessarily
  self?.updateB(viewModel.propertyB)
}
```

See `Docs/verge-to-stategraph-migration-guide.md` for detailed patterns.

#### TaskManager for Async Operations

```swift
private func fetchBanner() {
  enum TaskKey: TaskKeyType {}

  taskManager.task(key: .init(TaskKey.self), mode: .dropCurrent) { [self] in
    do {
      bannerState.markAsResolving()
      let banners = try await context.stack.mainService.fetchBanners()
      bannerState.resolve(banners)
    } catch {
      bannerState.resolveAsFailed()
    }
  }
}
```

Task modes:
- `.dropCurrent`: Cancel existing task, start new one
- `.discard`: Ignore if task already running

---

## Architecture & Dependencies

### Philosophy

- **Layered modules**: Features depend on UI, UI depends on Foundation
- **Type-safe injection**: Dependencies are explicit via `Context`
- **Namespace isolation**: Use `extension` to scope related types

### Practice

#### Context Injection Pattern

```swift
@MainActor
final class ViewModel: Sendable {
  let context: ServiceContexts.LoggedIn.Base

  init(context: ServiceContexts.LoggedIn.Base) {
    self.context = context
  }

  func fetchData() async throws {
    // Access services via context
    let result = try await context.stack.mainService.fetchVisitors()

    // Access navigation via context
    context.ui.link.editProfile()
  }
}
```

The `context` provides:
- `context.stack` — Service layer access
- `context.ui.link` — Navigation helpers
- `context.serviceTarget` — Regional configuration

#### Extension Namespacing

```swift
// FeatureName.swift
public enum PJPVisitor {}

// FeatureName.ViewModel.swift
extension PJPVisitor {
  @MainActor
  public final class ViewModel: Sendable {
    // ...
  }
}

// FeatureName.SwiftUIViewController.swift
extension PJPVisitor {
  public final class SwiftUIViewController: AppFluidViewController {
    // ...
  }
}
```

Benefits:
- Clear feature ownership
- Prevents namespace pollution
- Enables easy file organization

#### Weak Reference in Closures

```swift
weak var indirectSelf: ViewModel?

self.dataStore = .init(
  fetchResult: { pagination in
    let result = try await context.stack.mainService.fetch(pagination)
    indirectSelf?.updateState(from: result)
    return result
  }
)

indirectSelf = self
```

Use `indirectSelf` pattern when:
- Setting up closures in `init` before `self` is fully initialized
- Closures need weak reference to avoid retain cycles

#### Capture Lists in SwiftUI Closures

```swift
SwiftUIHostingViewController(
  content: { [viewModel = self.viewModel, focusingItem = $focusingItem] _ in
    ContentView(
      viewModel: viewModel,
      focusingItem: focusingItem
    )
  }
)
```

Capture specific properties to:
- Avoid retain cycles
- Make dependencies explicit
- Ensure consistent object identity

---

## Naming & Style Conventions

### Philosophy

- **Self-documenting names**: Code reads like prose
- **Domain language**: Use product terminology in type names
- **Consistent patterns**: Same concepts, same names

### Practice

#### Boolean Naming: Third-Person Present Tense

```swift
// ✅ Good - reads naturally: "if should display button"
var shouldDisplayButton: Bool
var hasEnteredHierarchy: Bool
var isAllVisitorsUnlocked: Bool
var canNextLoad: Bool

// ❌ Avoid - imperative form
var displayButton: Bool
var enteredHierarchy: Bool
```

This makes code read like English:
```swift
if shouldDisplayButton { ... }
if hasEnteredHierarchy && !isAllVisitorsUnlocked { ... }
```

#### Enum Case Naming

```swift
// ✅ Use descriptive cases with payloads
enum DisplayItem: Hashable {
  case visitor(ItemEdge)
  case secretVisitor(Entities.SecretVisitor)
  case ad(AnyFeedSmallBannerAdItem)

  var isPartner: Bool {
    switch self {
    case .visitor, .secretVisitor:
      return true
    case .ad:
      return false
    }
  }
}

// ❌ Avoid 'none' (conflicts with Optional.none)
enum Status {
  case none  // Bad
  case empty // Better
}
```

#### Enum Branching: Use `switch`, Not `==`

Enums exist so the compiler can enforce exhaustiveness. Using `==` bypasses this — when a new case is added, `==` silently falls through instead of producing a compile error.

```swift
// ❌ Loses exhaustiveness checking
let text = gender == .female ? femaleText : maleText

// ✅ Compiler enforces all cases
let text: String = {
  switch gender {
  case .female: return femaleText
  case .male: return maleText
  }
}()
```

#### Structured `switch` over Flat Tuple Matching

When switching on multiple values, nest switches by logical grouping rather than flattening into tuple patterns. Flat tuples are hard to scan and make it easy to miss combinations.

```swift
// ❌ Flat — hard to see grouping
switch (step, gender) {
case (.step1, .male):   return image1Male
case (.step1, .female): return image1Female
case (.step2, .male):   return image2Male
case (.step2, .female): return image2Female
}

// ✅ Structured — each group is clear
switch step {
case .step1:
  switch gender {
  case .male:   return image1Male
  case .female: return image1Female
  }
case .step2:
  switch gender {
  case .male:   return image2Male
  case .female: return image2Female
  }
}
```

#### Enum as Data Bag: Prefer Struct

When every enum case carries the same set of properties and no call site `switch`es on the enum itself, the enum is just a lookup table — use a struct with static constants instead. Struct properties are direct field access, while enum computed properties evaluate a `switch` on every call.

```swift
// ❌ N properties × M cases = N×M switch branches
enum Style {
  case primary, secondary

  var color: Color {
    switch self {
    case .primary: .blue
    case .secondary: .gray
    }
  }
  var padding: CGFloat {
    switch self {
    case .primary: 16
    case .secondary: 12
    }
  }
  // ... repeats for every property
}

// ✅ Each variant is a single flat declaration
struct Style {
  let color: Color
  let padding: CGFloat

  static let primary = Style(color: .blue, padding: 16)
  static let secondary = Style(color: .gray, padding: 12)
}
```

| Use enum when | Use struct when |
|---------------|-----------------|
| Call sites need exhaustive `switch` | Every case has the same property shape |
| Cases have different associated data shapes | It's purely a configuration/data bag |
| Adding a case should force callers to handle it | New variants shouldn't require touching existing code |

#### Access Control Strategy

| Modifier | Use Case |
|----------|----------|
| `public` | API surface for other modules |
| `public nonisolated` | Observable state properties |
| `internal` (default) | Module-internal implementation |
| `fileprivate` | File-scoped helper views/functions |
| `private` | Class/struct-internal only |

#### File Organization with MARK

```swift
extension PJPVisitor {
  public final class SwiftUIViewController: AppFluidViewController {
    // MARK: - Properties

    // MARK: - Initialization

    // MARK: - Lifecycle

    // MARK: - Actions
  }
}

// MARK: - Fileprivate Views

fileprivate struct ContentView: View { ... }

// MARK: - Formatting Helpers

extension Entities.Visitor {
  fileprivate var formattedAge: String { ... }
}
```

---

## Properties vs Functions

### Philosophy

- **Properties represent state**: Values that describe "what something is"
- **Functions represent actions**: Operations that "do something"
- **No side effects in getters**: Property access should never mutate state

### Practice

#### When to Use Properties

Use a **property** when:
- The value describes an attribute or characteristic
- It can be computed without side effects
- It's O(1) or cheap to compute
- The caller expects simple data access

```swift
// ✅ Properties - describe state
var displayItems: [DisplayItem] {
  dataStore.value
}

var canNextLoad: Bool {
  dataStore.header.hasReachedEnd == false
}

var isAllVisitorsUnlocked: Bool {
  me.meStatus.has(benefit: .visitorsShowAllPartners)
}

var formattedAge: String {
  LocalizedText.visitor_list_secret_age(age: age.description)
}
```

#### When to Use Functions

Use a **function** when:
- The operation has side effects (network, state mutation, logging)
- It performs an action the caller explicitly requests
- It takes parameters that change behavior
- It's async or can fail

```swift
// ✅ Functions - perform actions
func reload(isInteractive: Bool = false) {
  inAppMessage_fetchTopBanner()
  dataStore.send(action: .fetchFirst(resets: true), mode: .dropCurrent)
}

func loadNext() {
  dataStore.send(action: .fetchNext, mode: .discard)
}

func sendNice(partnerID: Entities.Partner.EntityID) async throws {
  try await context.stack.mainService.nice_sendNice(...)
}

func markAsSeenVisitorTutorial() {
  Task {
    try await context.stack.mainService.updateUserBrowseState(...)
  }
}
```

#### Never Use Mutating Getters

**Mutating getters** (properties that change state when accessed) are dangerous:

```swift
// ❌ NEVER - mutating getter
var nextItem: Item? {
  defer { currentIndex += 1 }  // Side effect!
  return items[safe: currentIndex]
}

// ❌ NEVER - lazy loading with side effects in getter
var cachedData: Data {
  if _cachedData == nil {
    _cachedData = fetchFromDisk()  // Side effect!
  }
  return _cachedData!
}
```

Why mutating getters are harmful:
- **Unpredictable**: Reading a property shouldn't change behavior
- **Debug nightmare**: Values change just by inspecting them
- **SwiftUI incompatible**: View body may be called multiple times
- **Breaks equality**: Same object, different results each access

```swift
// ✅ Use explicit functions instead
func consumeNextItem() -> Item? {
  defer { currentIndex += 1 }
  return items[safe: currentIndex]
}

// ✅ Or use Swift's lazy keyword for initialization
lazy var cachedData: Data = {
  fetchFromDisk()
}()
```

#### Decision Matrix

| Scenario | Use |
|----------|-----|
| Current count of items | Property: `var itemCount: Int` |
| Remove an item | Function: `func removeItem(at:)` |
| Check if loading | Property: `var isLoading: Bool` |
| Start loading | Function: `func startLoading()` |
| Formatted display string | Property: `var formattedDate: String` |
| Send network request | Function: `func fetchData() async` |
| Derived/computed value | Property: `var total: Int { a + b }` |
| Operation that can fail | Function: `func validate() throws` |

#### Property Naming for Computed State

```swift
// ✅ Boolean properties - use "is", "has", "can", "should"
var isReloading: Bool { dataStore.isReloading }
var hasEnteredHierarchy: Bool
var canNextLoad: Bool { !dataStore.header.hasReachedEnd }
var shouldDisplayButton: Bool

// ✅ Collection properties - use plural nouns
var displayItems: [DisplayItem]
var topBanners: [Banner]

// ✅ Optional state - describe what it represents
var selectedItem: Item?
var errorMessage: String?
```

---

## Error Handling & Async

### Philosophy

- **Errors as values**: Use typed error enums
- **Explicit task lifecycle**: Manage cancellation properly
- **Cleanup with defer**: Ensure state consistency

### Practice

#### Error Enums with Context

Use typed error enums to translate low-level failures into domain-meaningful cases.

```swift
enum Error: Swift.Error {
  case notAllowed
  case unrecoverable(Swift.Error)
}
```

#### Async Actions with defer

```swift
@MainActor
private func onApproach(item: ViewModel.ItemEdge) {
  item.lazySummaryViewModel.isProcessing = true

  Task {
    defer {
      item.lazySummaryViewModel.isProcessing = false  // Always executes
    }

    let result = await self.approach(item: item)

    switch result {
    case .success:
      AppReviewPresenter.presentIfNeeded(context: context, on: self)
    case .failure:
      break
    }
  }
}
```

#### Task Cancellation on deinit

```swift
private var fetchTask: Task<Void, Error>? {
  didSet {
    oldValue?.cancel()  // Cancel previous task
  }
}

deinit {
  fetchTask?.cancel()
  Log.deinit(self)
}
```

---

## Documentation

### Philosophy

- **Document "why", not "what"**: Code shows what; comments explain why
- **Business logic deserves explanation**: Complex rules need context
- **Link to specifications**: Reference tickets and wiki pages

### Practice

#### Doc Comments for Business Logic

When business logic is non-obvious, write doc comments that explain **why** and **when** — not what. Good doc comments help readers understand the rules without reading the implementation.

#### Formatting Helpers at File Bottom

```swift
// Main view code above...

// MARK: - Formatting Helpers

extension Entities.SecretVisitor {
  fileprivate var formattedAge: String {
    LocalizedText.visitor_list_secret_age(age: age.description)
  }

  fileprivate var formattedVisitedAt: String {
    createdAt.localized(format: .elapsed(.serverTime()))
  }
}
```

---

## Code Hygiene & Maintainability

### Philosophy

- **Less code is better code**: Every line is a liability to maintain
- **YAGNI**: Don't build for hypothetical future requirements
- **Three-strike rule**: Duplicate twice before abstracting
- **Delete aggressively**: Unused code is negative value

### Practice

#### Avoid Premature Abstraction

```swift
// ❌ Over-engineered for a single use case
protocol DataLoadable {
  associatedtype DataType
  func loadData() async throws -> DataType
}

class VisitorDataLoader: DataLoadable {
  func loadData() async throws -> [Visitor] { ... }
}

// ✅ Simple and direct
func loadVisitors() async throws -> [Visitor] {
  try await context.stack.mainService.fetchVisitors()
}
```

Wait until you have **three similar implementations** before extracting a shared abstraction.

#### Keep Code Close to Usage

```swift
// ❌ Separate file for one-time-use helper
// File: VisitorFormatter.swift
struct VisitorFormatter {
  static func formatAge(_ age: Int) -> String { ... }
}

// ✅ Extension at the bottom of the file that uses it
extension Entities.Visitor {
  fileprivate var formattedAge: String {
    LocalizedText.visitor_list_secret_age(age: age.description)
  }
}
```

#### Inline Single-Use Closures

Extracting a function is good for separation of concerns. However, the extracted function becomes callable from other sites — even when it was only designed to run once, in one place. This creates an unintended surface area: someone may call it again, breaking assumptions about initialization order or idempotency. When logic is truly single-use, scope it lexically so the "runs exactly once, here" intent is explicit and unintended reuse is impossible.

Tools for scoping single-use logic:
- **`do` block** — groups statements into a scope with no callable entry point
- **Nested function** — named, readable, but still invisible outside the enclosing function
- **Local closure / variable** — captures context and stays local

```swift
// ❌ Extracted function called only once — but nothing prevents a second call
private func configureDataStore() {
  // setup code
}

init() {
  configureDataStore()  // Only called here
}

// ✅ do block — simplest scope, no entry point
init() {
  do {
    // setup code directly here
  }
}

// ✅ Nested function — named for readability, still invisible outside init
init() {
  func configureDataStore() {
    // setup code
  }
  configureDataStore()
}

// ✅ Local closure — useful when you need to capture or pass it
init() {
  let configure = {
    // setup code
  }
  configure()
}
```

#### Don't Add Unnecessary Safety

```swift
// ❌ Defensive coding for impossible cases
func process(items: [Item]) {
  guard !items.isEmpty else {
    Log.error("Items should never be empty here")
    return
  }
  // The caller guarantees non-empty
}

// ✅ Trust your contracts
func process(items: [Item]) {
  // Caller guarantees non-empty; no check needed
  let first = items[0]
}
```

Only validate at **system boundaries** (user input, network responses, external APIs).

#### Code Size Checklist

Before adding code, ask:
1. **Is this actually needed now?** (not "might be useful")
2. **Does similar code exist?** (search before writing)
3. **Can I use a standard library feature?**
4. **Will this be used more than once?** (if not, keep inline)
5. **Am I adding error handling for impossible cases?**

---

## Animation & Motion

### Philosophy

Motion is **behavior**, not prescribed animation. Three principles:

1. **Spring-first**: Springs as the default curve for all UI state transitions
2. **Interruptible and additive**: Assume the user will interact mid-animation — springs handle this naturally (velocity continuity on interruption, additive retargeting)
3. **Don't over-invest in morphing**: Cross-fade + geometry matching is usually sufficient — even Apple's transitions (context menus, navigation zoom) use this, not true morphing

> "There's no animation curve prescribed by real life." — [WWDC 2018/803](https://developer.apple.com/videos/play/wwdc2018/803/)

### Practice

```swift
// ✅ Spring for state changes (interruptible, additive)
withAnimation(.smoothSpring) { isExpanded.toggle() }

// ✅ Cross-fade for view transitions
.transition(.opacity)

// ✅ Geometry matching for positional continuity
.matchedGeometryEffect(id: item.id, in: namespace)

// ❌ Easing — abrupt velocity on interruption, not additive
withAnimation(.easeInOut(duration: 0.3)) { isExpanded.toggle() }
```

**Acceptable easing:** infinite loops (`.linear.repeatForever()`), keyboard-synced, sequenced choreography with fixed timing.

**Tuning** ([WWDC 2023/10158](https://developer.apple.com/videos/play/wwdc2023/10158/)): Start with bounce 0 (critically damped). Add bounce only for playful/physical feel. Stay below 0.4.

**References:** [WWDC 2024 — Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/) · [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

---

## Quick Reference

### DO

- Use `Control` for all tap interactions
- Use `[weak self]` in escaping closures
- Use `switch` (not `==`) when branching on enums to preserve exhaustiveness
- Structure nested `switch` by logical grouping instead of flat tuple matching
- Name booleans with third-person present tense
- Group formatting helpers at file bottom
- Use `do` blocks for single-use setup code
- Use properties for state, functions for actions
- Use `lazy var` for one-time expensive initialization
- Delete unused code immediately (git has history)
- Search for existing code before writing new
- Separate stateful binding views from stateless content views
- Compose small, focused views
- Consider if new code will be an asset or liability
- Design technical debt with clear boundaries for easy repayment
- Evaluate trade-offs from multiple perspectives before deciding to share or separate code
- Ask "will these evolve together?" before sharing code
- Use struct with static constants when all enum cases share the same data shape
- Use spring animations (`.smoothSpring`, `.spring()`) as default for UI state transitions
- Design animations to be interruptible and additive — assume the user will interact mid-animation
- Use cross-fade (`.transition(.opacity)`) with matched geometry for view transitions

### DON'T

- Use `.onTapGesture` for interactive elements
- Create fallback instances in closure captures
- Compare enums with `==` — use `switch` to keep exhaustiveness checking
- Flatten multi-value `switch` into tuple patterns — nest by logical grouping
- Name enum cases `none` (conflicts with `Optional.none`)
- Add comments that restate what code does
- Extract single-use code into separate methods
- Use mutating getters (side effects in property access)
- Abstract before having 3+ similar implementations
- Add validation for impossible internal cases
- Leave commented-out code or unused imports
- Write code that only solves the immediate problem without considering structure
- Let stateful infrastructure types leak into display views
- Create implicit dependencies between components
- Share code just because it "looks similar" (coincidental similarity ≠ shared concept)
- Assume less code is always better
- Use enum as a data bag when all cases share the same property shape — use struct instead
- Use easing curves (`.easeIn`, `.easeOut`, `.easeInOut`) for interactive or state-driven animations — use springs
- Over-invest in perfect morphing — cross-fade with geometry matching is usually sufficient
