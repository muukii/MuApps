import * as React from "react"

/**
 * User-selectable theme preference.
 *
 * `system` follows the active browser color scheme until the user chooses an
 * explicit light or dark value.
 */
export type Theme = "dark" | "light" | "system"

/**
 * Concrete theme currently applied to the document.
 */
export type ResolvedTheme = "dark" | "light"

/**
 * Runtime theme state shared by the OTA install page.
 */
export type ThemeProviderState = {
  /** Stored theme preference. */
  theme: Theme
  /** Light or dark theme currently applied to the root element. */
  resolvedTheme: ResolvedTheme
  /** Persist and apply a new theme preference. */
  setTheme: (theme: Theme) => void
}

export const ThemeProviderContext = React.createContext<
  ThemeProviderState | undefined
>(undefined)

export function useTheme() {
  const context = React.useContext(ThemeProviderContext)

  if (context === undefined) {
    throw new Error("useTheme must be used within a ThemeProvider")
  }

  return context
}
