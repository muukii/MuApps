import { rm } from "node:fs/promises"
import { resolve } from "node:path"

const outputRoot = resolve(import.meta.dirname, "../../../docs")

await Promise.all([
  rm(resolve(outputRoot, "install.html"), { force: true }),
  rm(resolve(outputRoot, "install-assets"), { force: true, recursive: true }),
])
