# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`MuApps` is a Tuist-managed monorepo that hosts multiple iOS apps under `Apps/`. `Verse` is the primary app (SwiftUI-based YouTube subtitle viewer / learning tool). `HelloWorld` is a minimal scaffold that serves as the template for new apps.

## Workspace Layout

```
Workspace.swift              # Tuist workspace (lists projects under Apps/)
Tuist.swift                  # Tuist config
Tuist/
  Package.swift              # Shared external SPM dependencies (all apps)
  ProjectDescriptionHelpers/ # Shared Project.swift helpers (AppConstants, settings)
Apps/
  Verse/                     # Main app
    Project.swift
    Sources/                 # Swift sources (incl. YouTubeSubtitle.entitlements)
    Components/              # App-local Components framework target
    Info.plist
    xcconfig/Version.xcconfig
  HelloWorld/                # Scaffold app — copy this to bootstrap a new app
    Project.swift
    Sources/
Shared/                      # Shared modules shared across apps (currently empty)
  Project.swift              # Add cross-app framework targets here
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

1. Copy `Apps/HelloWorld/` to `Apps/<NewApp>/` and rename sources.
2. Update `bundleId` and `name` in its `Project.swift`.
3. Add the new directory to `Workspace.swift`'s `projects` array.
4. Run `tuist generate`.

Shared external SPM dependencies: add to `Tuist/Package.swift` and reference via `.external(name: ...)` in the app's `Project.swift`. Shared manifest helpers (settings, constants): extend `Tuist/ProjectDescriptionHelpers/Project+Templates.swift`.

## Development Notes

- Uses SwiftUI as the UI framework
- Target platforms: iOS (see `DeploymentTargets.app` in helpers)
- Dependencies are managed via Swift Package Manager through Tuist
- Each app owns its own sources under `Apps/<App>/`; frameworks shared across apps are a future refactor (currently `Components` is Verse-local)

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
