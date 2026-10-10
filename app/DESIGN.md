# Audiobook Studio — design system

Target: macOS 26+ (Liquid Glass). The app should feel like a current first-party Mac app: calm, spacious,
content-first, with glass reserved for the controls that float above content.

## Principles

1. **Two layers.** Content (book info, chapters, voices, stats) sits on clean, solid, rounded surfaces.
   Controls that float above content (the bottom action bar, filter bars, floating buttons, toolbars) use
   Liquid Glass (`glassEffect`, `.buttonStyle(.glass)` / `.glassProminent`). Never put glass on glass and
   never make long text sit on glass.
2. **Hierarchy through type and space, not borders.** Large bold titles, clear section headers, generous
   spacing (8-pt grid), almost no hard strokes. Separate with space and surface tone instead of lines.
3. **Show, don't list.** Key numbers become stat tiles (icon, big rounded number, small label); progress is a
   ring and a bar; states are colored capsules with SF Symbols.
4. **Quiet color.** Indigo accent (from the app icon) for primary actions and selection, warm amber for
   "attention" and highlights, semantic green/red for done/failed. Backgrounds stay neutral; a very soft
   ambient gradient behind content gives the glass something to refract.
5. **Alive but subtle.** `.contentTransition(.numericText())` for changing numbers, `.symbolEffect` for
   working/finished states, `.animation(.smooth)` for layout changes. No gratuitous motion; respect Reduce
   Motion (`@Environment(\.accessibilityReduceMotion)`).
6. **Accessible.** Every control keeps an accessibility label; Dynamic Type friendly (no fixed heights for
   text containers); contrast holds in light and dark mode; hover states never carry meaning alone.

## Tokens (`Design/Theme.swift`)

- Spacing: `xs 4, s 8, m 12, l 16, xl 24, xxl 32`.
- Radii (continuous): `card 20`, `tile 16`, `control 12`, `chip` = capsule; window-concentric shapes via
  `ConcentricRectangle` where a view hugs the window edge.
- Colors: `Theme.accent` (the system accent; the app declares indigo for Multicolor), `Theme.highlight` (amber), `Theme.success`, `Theme.danger`,
  `Theme.surface` (solid content surface, adapts to light/dark), `Theme.surfaceRaised`, `Theme.ambient`
  (the soft background gradient).
- Type: titles `.largeTitle.bold()`, section headers `.title2.weight(.semibold)`, numbers
  `.system(.title, design: .rounded).weight(.semibold).monospacedDigit()`, captions `.callout` / `.caption`
  in `.secondary`.
- Shadows: content cards use a very soft shadow (`radius 12, y 4, opacity 0.06` light / none dark).

## Components (`Design/Components.swift`)

- `SurfaceCard { }` — solid rounded content card with optional header (icon + title + accessory).
- `GlassBar { }` — floating glass bar (bottom action bar, filter bar) with horizontal padding and
  `GlassEffectContainer` for its buttons.
- `StatTile(label:value:systemImage:tint:caption:)` and `StatGrid` — adaptive grid of tiles; tiles in a row
  share its height (`TileGrid` layout).
- `Chip(text:icon:tint:)` — capsule tag (licence, kind, state).
- `ProgressRing(progress:lineWidth:)` — circular progress with an angular gradient stroke and a numeric
  label that animates.
- `SectionHeader(title:subtitle:accessory:)`.
- `HoverHighlight` view modifier — rounded highlight on hover for list rows.
- `AmbientBackground` — soft gradient background for screens.
- `HeroBackdrop(image:)` — blurred, desaturated cover image fading into the background (book screen).
- `ScreenHeader(title:subtitle:accessory:)` — large title at the top of a scrolling screen whose name is not
  already the window title; `ScreenIntro(text:accessory:)` for screens whose name is (Models, Benchmark).
- `IconBadge(systemImage:tint:size:)` — symbol in a soft tinted rounded square (row icons).
- `InlineBanner { }` — soft tinted banner for notes and warnings inside content.
- `EmptyStateView(systemImage:title:message:actions:)` — centred empty state.
- Modifiers: `.surface()`, `.insetSurface()`, `.hoverHighlight()`, `.screenWidth()`.
- Buttons: in floating glass bars, the one primary action uses `.buttonStyle(.glassProminent)` and the others
  `.buttonStyle(.glass)`. Inside content cards, use `.borderedProminent` (primary) and `.bordered`
  (secondary), both with `.buttonBorderShape(.capsule)`. Destructive keeps `role: .destructive`; inline
  links use `.buttonStyle(.borderless)` or `.link`.

## Screen scaffold

```swift
ScrollView {
    VStack(alignment: .leading, spacing: Theme.Space.xl) { … }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.xl)
        .screenWidth()
}
.background(AmbientBackground())
.safeAreaInset(edge: .bottom, spacing: 0) { GlassBar { … } }   // only screens with a bottom action bar
```

## Screens

- **New audiobook (empty)**: centred drop target — large rounded area with a dashed border that animates on
  drag-over, a big gradient SF Symbol (`books.vertical`), one sentence, an "Open a Book…" glass prominent
  button, and the recent conversions below as small cards.
- **Book**: hero header — blurred cover backdrop, cover with shadow, title (large), author, language and
  format chips, warnings as a soft amber inline banner. Narrator card with the voice, speed and speech-check
  toggle. Chapters as a clean list with hover, checkboxes, kind chips, listening time. Sample card with a
  player. A floating **glass action bar** at the bottom with totals (audio length, time on this Mac) and the
  Convert button (glass prominent).
- **Voices**: narrator summary card at the top; engine cards as tiles with an icon, licence chip, speed stat
  and install state; filter bar as a glass bar; voice rows with an avatar circle (initials, tinted by
  language), chips, actions on the right.
- **Job progress**: large progress ring with percent, current chapter, ETA range as the main number, stat
  tiles (elapsed, speed, × real time, chapters), the rate chart with a gradient area fill, quality and
  machine status as small cards, Cancel as a glass button.
- **Job done**: celebratory but calm header (green check with a symbol effect), stat tiles, primary
  "Play" and "Open in Books" buttons.
- **Jobs / Models / Benchmark / Settings**: list rows as cards with hover, state chips, consistent headers.
- **Settings > Languages**: one grouped-form row per registry language (native name headline, English name, an
  On/Off `Chip`, a one-line cost, a capsule Add / Remove button). A language no installed engine speaks shows the
  engine to install and an "Open Models" button. The Book screen shows `BookLanguageBanner` (an `InlineBanner`
  with an "Add <language>" button) when the book's language is off.
- **Sidebar**: standard source-list glass sidebar; job rows with a mini progress ring and state color.

## Dark mode: no purple text

The indigo accent is about 2.8:1 against the dark card surface: unreadable as text. In dark mode, purple is
only ever a fill (prominent buttons, selection, switches, progress) with white text on it, or a stroke
(rings, focus, dashed borders). It is never the colour of text or of symbols.

- Text and symbols that use the accent take `Theme.accentForeground`; any other tint used as a foreground goes
  through `ReadableForeground(color, fallback:)`. Both keep the colour in light mode and switch to the primary
  (or secondary) label colour in dark mode when `Theme.isHardToRead(color)` (contrast below 3.5:1).
- `Chip`, `IconBadge`, `StatTile`, `SurfaceCard`, `InlineBanner` and `EmptyStateView` apply this themselves.
- Never put `.tint(Theme.accent)` on a view containing buttons, pickers, menus or links: the tint colours their
  labels. Tint only a control whose tinted part is a fill (a ProgressView bar, a Toggle). A tinted Slider also
  draws its minimum/maximum value labels in the tint, and hierarchical styles inside it resolve to the tint, so
  give those labels a concrete colour in dark mode (see `SliderValueLabelStyle` in Views/Voice/VoiceView.swift).
- The faintest captions and hint symbols use `Theme.faint` (tertiary grey in light mode, secondary in dark mode,
  where tertiary is about 2.2:1).
- In dark mode the floating glass bar is slightly darker, the cover backdrop is softer, and symbols on accent tiles
  and chips are drawn solid white.
- The sidebar icons are monochrome in dark mode; the Settings window uses a segmented control instead of toolbar
  tabs (macOS draws the selected toolbar tab's label in the accent colour).
