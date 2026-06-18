# MuApps OTA Install Page

This package builds the GitHub Pages OTA install page at `docs/install.html`.
It uses React, Vite 8, Tailwind CSS, and shadcn/ui source components.

## Development

```bash
npm run dev
```

Open `http://127.0.0.1:5173/install.html`.

## Build

```bash
npm run build
```

The build removes only the generated OTA page files (`docs/install.html` and
`docs/install-assets/`) before writing the fresh Vite output. Other files in
`docs/`, including `SPECIFICATION.md`, are preserved.
