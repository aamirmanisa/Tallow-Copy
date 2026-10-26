# Visual identity — tallowx

One tool, one claim: the copy happened and can be proven. The identity is the Tallow family palette
(tallow rendered amber on ink), applied to two assets — a hero and one diagram that shows what
verification actually reads.

## Tokens

| Token | Dark | Light | Used for |
|---|---|---|---|
| `bg` | `#0D0C0B` | `#FBF8F2` | background |
| `panel` | `#171513` | `#FFFFFF` | diagram nodes |
| `panel2` | `#1D1A17` | `#F7F2E8` | the node that carries the verdict |
| `rule` | `#2E2924` | `#E0D6C4` | hairlines, arrows, grid |
| `text` | `#F4EFE6` | `#17150F` | wordmark, node titles |
| `muted` | `#A79E8F` | `#6B6459` | tagline, secondary labels |
| `faint` | `#6E675D` | `#9A9184` | captions |
| `accent` | `#E39B3E` | `#A35C05` | the verified path |
| `ok` / `warn` | `#6FAF8A` / `#D2705C` | `#2F7A53` / `#A8402C` | verified / failed |

Amber marks the path that proves something — the arrow into verification, the matching byte run.
Grey marks the copy itself, which is not the claim.

## Type

- **Wordmark** — Lato Black, converted to outlines.
- **Labels** — DejaVu Sans Mono, also converted to outlines.
- **Prose** — GitHub's own stack; the README sets no fonts.

Outlines keep the composition identical on a machine that has neither font installed.

## Inventory

| File | What it is |
|---|---|
| `tallowx-hero-{dark,light}.png` | README hero: wordmark, claim, SRC/DST byte motif |
| `tallowx-verify-{dark,light}.png` | what a run proves, and the three things it does not |
| `src/*.svg` | editable sources the PNGs are rendered from |
| `src/brand.py` | tokens, text-to-outline conversion, SVG primitives |
| `src/make_assets.py` | regenerates both assets |

## Regenerating

```console
$ python3 assets/src/make_assets.py
```

`brand.py` reads Lato Black and DejaVu Sans Mono from `/usr/share/fonts`. Rasterising uses headless
Chromium; snap Chromium on this host cannot read `/root`, so run the script from a copy of
`assets/src/` under `/home/…` and copy the output back.
