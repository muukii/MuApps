# Tinycurve App Store Metadata

This directory contains App Store copy for **Tinycurve**, whose internal target
and module name is `Journal`.

```text
metadata/
├── en/app-store.md
└── ja/app-store.md
```

Each locale file contains the App Store Connect name, subtitle, keywords,
promotional text, and description, followed by copy for five screenshots.
Screenshot copy is kept in the same file for product-voice consistency, but it
is not an App Store Connect text metadata field.

The product language is grounded in:

- `Apps/Journal/Note.md` for the original small-card concept.
- `Apps/Journal/docs/SPECIFICATION.md` for current product behavior.
- `Apps/Journal/docs/PRIVACY_POLICY.md` for privacy claims.

The repository-root `metadata/` directory currently contains Verse metadata;
Tinycurve metadata remains app-local so the two products cannot be confused.
