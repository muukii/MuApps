import { Button } from "@/components/ui/button"
import {
  Alert,
  AlertDescription,
  AlertTitle,
} from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardAction,
  CardContent,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Separator } from "@/components/ui/separator"
import { useTheme } from "@/lib/theme"
import type { LucideIcon } from "lucide-react"
import {
  BookOpenText,
  Camera,
  Code2,
  Download,
  Ear,
  ExternalLink,
  Headphones,
  Languages,
  Lightbulb,
  Mic,
  Moon,
  ShieldCheck,
  Sun,
} from "lucide-react"

const releaseURL = "https://github.com/muukii/MuApps/releases/tag/adhoc-latest"
const manifestBaseURL =
  "https://github.com/muukii/MuApps/releases/download/adhoc-latest"

/**
 * Visual accent assigned to an app symbol tile.
 *
 * The value is consumed by CSS so each app can stay visually distinct without
 * spreading color literals through the React tree.
 */
type AppTone =
  | "blue"
  | "cyan"
  | "green"
  | "amber"
  | "rose"
  | "violet"
  | "slate"
  | "teal"

/**
 * Describes one published app and the release manifest used for OTA install.
 */
type InstallableApp = {
  /** User-facing app name shown in the install card. */
  name: string
  /** Short product description copied from the existing OTA page. */
  description: string
  /** Release asset filename in the `adhoc-latest` GitHub release. */
  manifestFile: string
  /** Icon rendered inside the app symbol tile. */
  icon: LucideIcon
  /** Accent color token for the app symbol tile. */
  tone: AppTone
}

const apps: InstallableApp[] = [
  {
    name: "Verse",
    description: "YouTube subtitle viewer and language learning tool.",
    manifestFile: "Verse-manifest.plist",
    icon: Languages,
    tone: "blue",
  },
  {
    name: "Tone",
    description: "Shadowing practice app with audio, subtitles, and recording.",
    manifestFile: "Tone-manifest.plist",
    icon: Headphones,
    tone: "cyan",
  },
  {
    name: "PhotosOrganizer",
    description: "Photo library size browser and image conversion utility.",
    manifestFile: "PhotosOrganizer-manifest.plist",
    icon: Camera,
    tone: "green",
  },
  {
    name: "Calm Light",
    description: "HDR ambient light with organic animated color patterns.",
    manifestFile: "AmbientLight-manifest.plist",
    icon: Lightbulb,
    tone: "amber",
  },
  {
    name: "Hear Augment",
    description: "Real-time microphone listening with creative audio filters.",
    manifestFile: "HearAugment-manifest.plist",
    icon: Ear,
    tone: "rose",
  },
  {
    name: "PolyReader",
    description: "Sentence-by-sentence reading player for pasted text.",
    manifestFile: "PolyReader-manifest.plist",
    icon: BookOpenText,
    tone: "violet",
  },
  {
    name: "Voice Recorder",
    description: "One-clip voice recording with delayed headphone monitoring.",
    manifestFile: "VoiceRecorder-manifest.plist",
    icon: Mic,
    tone: "teal",
  },
  {
    name: "HelloWorld",
    description: "Minimal scaffold app used to bootstrap new MuApps apps.",
    manifestFile: "HelloWorld-manifest.plist",
    icon: Code2,
    tone: "slate",
  },
]

function buildInstallURL(manifestFile: string) {
  const manifestURL = `${manifestBaseURL}/${manifestFile}`

  return `itms-services://?action=download-manifest&url=${encodeURIComponent(
    manifestURL
  )}`
}

function AppSymbol({ app }: { app: InstallableApp }) {
  const Icon = app.icon

  return (
    <div className="app-symbol" data-tone={app.tone} aria-hidden="true">
      <Icon />
    </div>
  )
}

function InstallCard({ app }: { app: InstallableApp }) {
  return (
    <Card className="install-card rounded-lg" size="sm">
      <CardHeader className="gap-3">
        <div className="flex min-w-0 items-start gap-3">
          <AppSymbol app={app} />
          <div className="min-w-0">
            <CardTitle className="text-base">{app.name}</CardTitle>
            <p className="mt-1 text-sm leading-6 text-muted-foreground">
              {app.description}
            </p>
          </div>
        </div>
        <CardAction>
          <Badge variant="secondary">Ad Hoc</Badge>
        </CardAction>
      </CardHeader>
      <CardContent>
        <div className="manifest-line">
          <span>Manifest</span>
          <code>{app.manifestFile}</code>
        </div>
      </CardContent>
      <CardFooter className="justify-end bg-transparent pt-0">
        <Button asChild size="lg" className="install-button">
          <a href={buildInstallURL(app.manifestFile)}>
            <Download data-icon="inline-start" />
            Install
          </a>
        </Button>
      </CardFooter>
    </Card>
  )
}

function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme()
  const isDark = resolvedTheme === "dark"
  const label = isDark ? "Switch to light mode" : "Switch to dark mode"
  const Icon = isDark ? Sun : Moon

  return (
    <Button
      aria-label={label}
      aria-pressed={isDark}
      title={label}
      type="button"
      variant="outline"
      size="icon-sm"
      onClick={() => setTheme(isDark ? "light" : "dark")}
    >
      <Icon />
    </Button>
  )
}

export function App() {
  return (
    <div className="page-shell min-h-svh">
      <header className="site-header">
        <a className="brand-link" href="#top" aria-label="MuApps install page">
          <span className="brand-mark">M</span>
          <span>MuApps</span>
        </a>
        <div className="header-actions">
          <ThemeToggle />
          <Button asChild variant="outline" size="sm">
            <a href={releaseURL} target="_blank" rel="noreferrer">
              GitHub Release
              <ExternalLink data-icon="inline-end" />
            </a>
          </Button>
        </div>
      </header>

      <main id="top" className="mx-auto flex w-full max-w-6xl flex-col gap-10 px-4 pb-12 pt-8 sm:px-6 lg:px-8">
        <section className="hero-grid">
          <div className="hero-copy">
            <h1>Install MuApps</h1>
            <p>
              Latest main branch Ad Hoc builds for registered iPhone devices.
            </p>
            <div className="hero-actions">
              <Button asChild size="lg">
                <a href="#apps">
                  <Download data-icon="inline-start" />
                  Choose an app
                </a>
              </Button>
              <Button asChild variant="outline" size="lg">
                <a href={releaseURL} target="_blank" rel="noreferrer">
                  Open release
                  <ExternalLink data-icon="inline-end" />
                </a>
              </Button>
            </div>
          </div>

          <aside className="release-panel" aria-label="Release details">
            <div>
              <span>Release channel</span>
              <strong>adhoc-latest</strong>
            </div>
            <Separator />
            <div>
              <span>Source branch</span>
              <strong>main</strong>
            </div>
            <Separator />
            <div>
              <span>Published apps</span>
              <strong>{apps.length} builds</strong>
            </div>
          </aside>
        </section>

        <section id="apps" className="flex flex-col gap-4">
          <div className="section-heading">
            <div>
              <h2>Available builds</h2>
              <p>Select an app from the latest Ad Hoc release.</p>
            </div>
            <Badge variant="outline">iPhone only</Badge>
          </div>

          <div className="install-grid">
            {apps.map((app) => (
              <InstallCard app={app} key={app.manifestFile} />
            ))}
          </div>
        </section>

        <Alert className="rounded-lg bg-card/90">
          <ShieldCheck />
          <AlertTitle>Registered device required</AlertTitle>
          <AlertDescription>
            Install links use Apple&apos;s OTA manifest flow. The target iPhone
            must be included in the Ad Hoc provisioning profile for the build.
          </AlertDescription>
        </Alert>
      </main>
    </div>
  )
}

export default App
