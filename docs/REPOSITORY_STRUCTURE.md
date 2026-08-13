# MuApps Repository Structure

MuApps separates projects by release intent. Directory placement is part of
the repository contract; it is not only a visual grouping.

```text
Apps/         Release-targeted applications
Experiments/  Active PoCs, labs, scaffolds, and archived experiments
Shared/       Cross-app framework modules
```

## Apps

`Apps/` contains applications intended to participate in release workflows.
An app is not automatically deployed merely because it lives here: Ad Hoc and
App Store Connect membership remain explicit in `.github/` configuration.

Current release-targeted projects:

- `AmbientLight`
- `Farg`
- `Journal` (product and scheme name: Tinycurve)
- `PhotosOrganizer`
- `PolyReader`
- `Tone`
- `Verse`
- `VoiceRecorder`

## Experiments

`Experiments/` contains executable projects used for proofs of concept, API or
interaction labs, product prototypes, and scaffolding. Active experiments stay
in the root Tuist workspace and the experiment CI matrix so they remain
buildable, but they do not belong in release distribution configuration.

Current active experiments:

- `CodexPet`
- `ColorPlayground`
- `HearAugment`
- `HelloWorld`
- `SafariReactor`
- `TabLab`

Archived experiments remain directly under `Experiments/`. Mark their Notion
Project lifecycle as `Archived`, and remove them from `Workspace.swift` and CI.
Keeping the directory flat preserves the same `../../Shared` dependency depth
for active and archived projects.

## Shared

`Shared/` contains modules with a stable cross-app contract. Code does not move
here merely because two projects look similar; the concepts must be expected to
evolve together. App-specific and experiment-specific modules stay with their
owning project.

## Lifecycle changes

Promoting an experiment to a release-targeted app requires one atomic change:

1. Confirm the lifecycle decision in Notion.
2. Move `Experiments/<Project>` to `Apps/<Project>` with Git history preserved.
3. Move the project from the experiment workspace and CI sections to the
   release sections.
4. Add only the distribution configuration that has actually been approved.
5. Update path-bearing documentation and the Project's Notion repository path.
6. Generate the Tuist workspace and verify the project in its release lane.

Archiving reverses only the active-registration parts: keep the source under
`Experiments/`, mark the Notion lifecycle `Archived`, and remove the project
from the workspace and CI. Do not delete or restore archived source solely to
make the directory inventory look complete.
