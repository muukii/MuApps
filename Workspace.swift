import ProjectDescription

let workspace = Workspace(
  name: "MuApps",
  projects: [
    // Release-targeted apps.
    "Apps/AmbientLight",
    "Apps/Farg",
    "Apps/Journal",
    "Apps/PhotosOrganizer",
    "Apps/PolyReader",
    "Apps/Tone",
    "Apps/Verse",
    "Apps/VoiceRecorder",

    // Active experiments. Archived experiments stay under Experiments but are
    // intentionally omitted from the generated workspace.
    "Experiments/CodexPet",
    "Experiments/ColorPlayground",
    "Experiments/HearAugment",
    "Experiments/HelloWorld",
    "Experiments/SafariReactor",
    "Experiments/TabLab",

    // Cross-app modules.
    "Shared",
  ]
)
