# CLAUDE.md

Use @coding-guide.md for coding.

Use @PROJECT_MANAGEMENT.md for project-wide Notion specification, task, and
decision tracking.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`MuApps` is a Tuist-managed monorepo. Release-targeted applications live under
`Apps/`, executable proofs of concept and archived experiments live under
`Experiments/`, and cross-app modules live under `Shared/`. See
`docs/REPOSITORY_STRUCTURE.md` for the classification and migration contract.

## Workspace Layout

```
Workspace.swift              # Tuist workspace (groups Apps, Experiments, Shared)
Tuist.swift                  # Tuist config
Tuist/
  Package.swift              # Shared external SPM dependencies (all apps)
  ProjectDescriptionHelpers/ # Shared Project.swift helpers (AppConstants, settings)
Apps/                        # Release-targeted applications
  Verse/                     # Main app
    Project.swift
    Sources/                 # Swift sources (incl. YouTubeSubtitle.entitlements)
    Components/              # App-local Components framework target
    Info.plist
    xcconfig/Version.xcconfig
Experiments/                 # Active PoCs, labs, scaffolds, and archives
  HelloWorld/                # Scaffold app — copy this to bootstrap a new app
    Project.swift
    Sources/
Shared/                      # Framework modules shared across apps
  Project.swift              # Declares cross-app framework targets
  MuComponents/              # Reusable SwiftUI interaction components
  MuDesignSystem/            # Shared colors and typography
Packages/                    # Local SPM packages
```

### Adding a Shared Module

When a module needs to be shared between apps:

1. Create `Shared/<ModuleName>/` and put Swift sources there
2. Add a `.target(...)` entry in `Shared/Project.swift` (see the template comment at the top)
3. Register `Shared` in `Workspace.swift`'s `projects` array (first time only)
4. In the consuming app's `Project.swift`, add `.project(target: "<ModuleName>", path: "../../Shared")` to `dependencies`
5. Run `tuist generate`

## Build Commands

Always run `tuist install` and `tuist generate` before building (the `.xcworkspace` and per-app `.xcodeproj` are gitignored).

### Generate the workspace
```bash
tuist install
tuist generate
```

### Building an app
```bash
xcodebuild -workspace MuApps.xcworkspace -scheme Verse -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -workspace MuApps.xcworkspace -scheme HelloWorld -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Running tests
```bash
xcodebuild -workspace MuApps.xcworkspace -scheme Verse -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### Opening in Xcode
```bash
open MuApps.xcworkspace
```

## Adding a New App

1. Copy `Experiments/HelloWorld/` to `Apps/<NewApp>/` and rename sources.
2. Update `bundleId` and `name` in its `Project.swift`.
3. Add the new directory to `Workspace.swift`'s `projects` array.
4. Run `tuist generate`.

For a PoC or lab, copy the same scaffold to `Experiments/<NewExperiment>/`
instead. Active experiments belong in the experiment section of
`Workspace.swift` and the experiment CI matrix, but not in release distribution
configuration. Archived experiments remain under `Experiments/` and are removed
from both the workspace and CI.

Shared external SPM dependencies: add to `Tuist/Package.swift` and reference via `.external(name: ...)` in the app's `Project.swift`. Shared manifest helpers (settings, constants): extend `Tuist/ProjectDescriptionHelpers/Project+Templates.swift`.

### External packages with global state must be declared dynamic

Tuist builds external SPM packages as **static** products by default. A static
product linked by two targets is absorbed into *each* of them. When those two
targets share a process — an app and a dynamic framework it embeds — the process
ends up with two independent copies. This produces **no linker error and no dyld
error**: a duplicate-symbol error only occurs when one binary links the same
archive twice, and under the two-level namespace each image silently binds to its
own copy.

That is harmless for a stateless leaf, and fatal for anything holding global or
thread-local state. `StateGraph` is the clearest example: it has
`NodeStore.shared`, and its `ThreadLocal` values are keyed by **string** into
`Thread.current.threadDictionary`. Two copies therefore collide on the same key
while each fails the `as? Value` cast against the other's type — so tracking
registrations silently vanish instead of failing loudly.

The escape hatch is `PackageSettings.productTypes` in `Tuist/Package.swift`,
which overrides the package's own declaration:

```swift
let packageSettings = PackageSettings(
  productTypes: [
    "StateGraph": .framework,
  ],
  ...
)
```

Verified behaviour: the generated target becomes
`com.apple.product-type.framework` (its `.macro` target correctly stays a
compiler-plugin `tool`), and `NodeStore` / `ThreadLocal` then live only in
`StateGraph.framework`. Symbols still left in the app binary are the app's *own*
generic instantiations and witness tables whose mangled names merely mention the
package — not a second copy.

**Rule:** before using an external package from more than one linked target, check
whether it holds global or thread-local state. If it does, add it to
`productTypes` as `.framework` at the same time. Leaf packages that are pure
value/function libraries can stay static.

## Development Notes

- Uses SwiftUI as the UI framework
- Target platforms: iOS (see `DeploymentTargets.app` in helpers)
- Dependencies are managed via Swift Package Manager through Tuist
- Each project owns its feature sources under `Apps/<App>/` or
  `Experiments/<Experiment>/`; reusable interaction components live in
  `Shared/MuComponents`, while shared visual tokens live in
  `Shared/MuDesignSystem`

## Documentation Policy

### When to Update SPECIFICATION.md

**IMPORTANT**: Whenever you make functional changes to the application, you MUST update `docs/SPECIFICATION.md` to reflect those changes.

Update the specification when:
- Adding new features (UI components, screens, functionality)
- Modifying existing features (behavior changes, UI changes)
- Removing features
- Changing user-facing behavior (keyboard shortcuts, gestures, navigation)
- Adding or modifying external integrations (Shortcuts, App Intents, etc.)

Do NOT update for:
- Internal refactoring with no user-visible changes
- Code style improvements
- Bug fixes that restore intended behavior (unless behavior was undocumented)
- Performance optimizations with no feature changes

### How to Update

1. Read the current specification: `docs/SPECIFICATION.md`
2. Identify the relevant section(s) that need updates
3. Make precise changes that:
   - Describe WHAT the feature does (user perspective)
   - Include UI/UX details (button names, colors, layouts)
   - Document any special behaviors or edge cases
   - Follow the existing structure and style

### Reminder System

After completing any feature implementation or modification:
1. Ask yourself: "Does this change affect what users can do or see?"
2. If YES → Update `docs/SPECIFICATION.md`
3. If NO → Document in comments/commit message why spec wasn't updated
