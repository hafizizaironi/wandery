# Wandery — Launch Image Kit (v2 · feature tour)

Generated marketing imagery + an App Store screenshot compositor.

## Layout
```
marketing/
├── appstore/
│   ├── captions.md            # the 8-frame feature-tour story
│   ├── manifest.json          # frame → eyebrow + headline + sub + bg + screenshot
│   ├── compose_screenshots.py # Pillow compositor (bg + 3-tier type + iPhone/Dynamic Island)
│   └── fonts/                 # Instrument Serif + Space Mono (Google Fonts, OFL)
├── raw/
│   ├── bg/v2/   frame1..8_*.png     # abstract map-motif backgrounds (1536×2688)
│   ├── promo/v2/ P1/P2/P3 *.png     # abstract promo art
│   └── screens/ 01..08_*.png        # real UI screenshots
└── out/        frame1..8_*.png      # FINAL App Store frames (1320×2868)
```

## The set (v2)
8-frame feature tour — abstract **map-motif line art** backgrounds, **iPhone + Dynamic Island** frame, three-tier type (**Space Mono** terracotta kicker · **Instrument Serif** headline · sans subline):
1 Your circle (feed) · 2 Snap & score (camera+AI ring) · 3 Trending · 4 Discover swipe · 5 The map (clusters) · 6 Scouted (place detail) · 7 My Hunt · 8 Home Screen (widgets).

Promo v2 (`raw/promo/v2/`): hero 16:9 + 1:1, pattern 1:1, invite 9:16 — raw abstract art (text overlay optional).

## Re-running
```
cd appstore && python3 compose_screenshots.py        # needs pillow
```
Edit captions/assets in `manifest.json`; swap a screenshot in `raw/screens/`; re-run.

## Notes
- Fonts are the app's intended brand faces (Instrument Serif per `Shared/Font+Hunt.swift`), bundled OFL — free to embed.
- Status-bar clocks differ across captures (11:51–12:23) — optional uniform-9:41 overlay available.
- v1 (photoreal café) backgrounds/frames are preserved in `raw/bg/`, `raw/promo/` (un-suffixed).

## Upload
App Store Connect → 6.9" slot (downscales to 6.7"/6.5"). Every frame shows real app UI → guideline 2.3.3 OK.
Brand: terracotta `#B5523A` · sage `#7A8B6F` · cream `#F7F5F2` · ink `#282520` · **"Stay hunting. 🔥"**
