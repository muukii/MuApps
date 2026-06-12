import path from "node:path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// https://vite.dev/config/
export default defineConfig({
  base: "./",
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  build: {
    assetsDir: "install-assets",
    emptyOutDir: false,
    outDir: path.resolve(__dirname, "../../docs"),
    rolldownOptions: {
      input: {
        install: path.resolve(__dirname, "install.html"),
      },
    },
  },
})
