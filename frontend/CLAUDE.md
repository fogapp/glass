# Console frontend — non-negotiables

The console is an **instrument**: dense, dark first,
keyboard driven, URL addressable, live. It reads like a dashboard and a
console tool, not a website.

## The cardinal rule

Every color goes through a semantic token defined in `src/index.css`:
`background`, `surface`, `surface-raised`, `foreground`, `muted`, `border`,
`input`, `primary`, `primary-hover`, `primary-foreground`, `positive`,
`negative`, `negative-foreground`, `warning` — and, for charts only,
`series-1..8`, `heat-1..7`, `grid`, `crosshair`.

**Never** write a raw palette class (`bg-blue-500`, `text-gray-700`,
`text-white`) in `.tsx` *or* `.ts`. Themes are token overrides; components
never branch on theme. Guard: `bin/design-guard`.

Charts read the tokens through `charts/theme.ts` (`useChartTheme`), because
a canvas does not repaint when a custom property changes. Colors handed to
a canvas go through `rgb()`/`withAlpha()` there — a canvas silently keeps
its previous fill when it cannot parse one.

## Charts

- Categorical color follows the entity, never its rank: a series grouped by
  app wears that app's `color_slot` (`lib/seriesColors.ts`), the same on
  every chart in the console. Slots are assigned in fixed order and never
  cycled; the eight are validated (dataviz skill) — do not add a ninth.
- One time axis: every `Timeseries` shares the `glass` cursor sync key;
  brushing asks the scope for a new range; deploy markers are drawn on all
  unless the scope bar's Markers switch is off (`?markers=0`).
- A single series gets no legend; two or more always do.
- Text never wears the series color; a dot beside it does.
- Every number leads to its rows: a point, a bar, a cell opens a list with
  exactly that filter and range (`lib/explore.ts` builds the link).
- A run's phases (queue · prepare · model · tools · waiting on a person ·
  deliver · untracked) wear fixed slots, declared once in `lib/runs.ts`, so
  "model" is the same colour in the stacked chart (`Timeseries` `slots`),
  the bar (`charts/PhaseBar`) and the waterfall. Time that was a person's
  is hatched wherever it is a bar (`charts/hatch.ts`), and so is the
  waterfall's row for what no span covers. A run's latency is its *active*
  time everywhere.
- Stacked series use uPlot bands; `fromZero` for counts and rates, fitted
  for gauges.

## Scope and queries

- The scope bar's state (app, range, live, markers) is the URL (`lib/scope.tsx`);
  pages read it with `useScope()` and add their own terms with
  `withScope()`. Never keep a page's own copy of the range.
- In-app links between scoped pages keep the scope: `ScopedLink` /
  `ScopedNavLink` (`components/scope/ScopedLink`), `useScopedNavigate` /
  `useScopedHref` (`lib/scopeHref.ts`) — a plain `/apps/x/endpoints/y`
  would open it in the default range. `useExploreHref` is built on them.
- Telemetry reads go through `useGlassQuery` / `useGlassQueries`
  (`lib/glassQuery.ts`); the spec is the key. Timestamps are rounded so a
  live tick is a cache hit, not a new key.
- The query bar (`telemetry/QueryBar`) completes field names from the
  catalog and values from `/query/values`; `/` focuses it.
- A row of `transactions` is a spine plus the facets its kind carries; a
  filter that names a kind (`kind:run`) narrows the fields offered to those
  (`lib/workFields.ts`). An app's page is built from the kinds it reports
  (`App#kinds`): a harness gets `pages/app/Harness.tsx`.

## Components

- Build a `ui/` primitive before a page needs it twice. Variants are plain
  object maps + `cn()`, not CVA.
- Charts sit in a `Panel`; a query's three states render through
  `QueryBody` — a failed query is never an empty chart. A page's batch is
  `useGlassBatch({ name: spec })` (the scope's range unless a spec names
  one), read by name — `answer("latency")`, never by position. One answer
  of it is `<BatchTimeseries batch answer>` (empty, markers and brushing
  included); a table answer ranked is `tableToBars` → `BarList`, or as a
  table `rankedRows` + `figureColumn` (`lib/ranked`).
- Details open beside the list (`Sheet`), not instead of it; `Esc` closes.
- Forms use `useFormMutation` with `FormError`/`FormFooter`; list screens
  use `QueryState`; a connection's Test uses `useTestConnection` +
  `TestButton`.
- Controls: `h-8/9`, `rounded-[var(--radius-control)]`; cards
  `rounded-[var(--radius-card)]`; figures wear `tabular font-mono`.

## Data

- Query keys come from `lib/queryKeys.ts`. No inline key literals.
- `api.get<T>` trusts `T`. When a serializer changes, `src/types` changes
  in the same commit; closed vocabularies come from `types/generated.ts`
  (`bin/rails glass:types`, checked by `bin/check-types`).

## Keyboard

`⌘K` palette · `g` + letter to jump (see `layout/nav.ts`) · `t` time ·
`[` `]` step · `l` live · `m` markers · `/` query bar · `?` help. Add a shortcut to the
help list when you add one.

## Checks

```bash
npm run lint
npm run build      # tsc -b + vite build
npm test -- --run
```

## Small screens

The rail folds into a drawer below `lg`; the scope bar scrolls sideways;
the Explorer's facet rail and Settings' section nav hide below `lg`/`md`.
Check a page at 390px before shipping it: nothing may scroll sideways.
