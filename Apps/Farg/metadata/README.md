# Färg App Store Metadata

This directory contains localized App Store copy for **Färg**.

```text
metadata/
├── en/app-store.md
└── ja/app-store.md
```

Each locale file contains the App Store Connect name, subtitle, keywords,
promotional text, and description, followed by copy for five screenshots.
Screenshot copy is kept beside the metadata so the product-page sequence and
voice can be reviewed together, but it is not an App Store Connect text field.

The copy is grounded in:

- `Apps/Farg/docs/SPECIFICATION.md` for current product behavior and privacy.
- The Färg source for platform-dependent limitations around Optical Flow,
  background export, external storage, and Shortcuts.

The repository-root `metadata/` directory contains Verse metadata, while
Tinycurve metadata remains under `Apps/Journal/metadata/`. Färg metadata stays
app-local so the products cannot be confused.
