# Orbitakt for the web

The same instrument as the iPhone app, as one self-contained page: `docs/play/index.html` (served by GitHub Pages at `/play/`).

- `src/sgp4.js` SGP4 + observer maths · `src/catalog.js` CelesTrak TLE catalog, cache, simulated fallback
- `src/dsp.js` the synth (pure JS, runs in an AudioWorklet and in Node) · `src/worklet.js` · `src/plate.js` plate-reverb impulse response · `src/engine.js` Web Audio graph
- `src/model.js` sky → rhythm (port of RhythmModel) · `src/ui.js`, `src/template.html` the page

Build: `node web/build.js` (no dependencies) rewrites `docs/play/index.html`.
Embedding in another site: the iframe needs `allow="geolocation"` for "Use my location".
`test/` holds the reference checks for the maths (they expect reference data made by `gen_ref.py`) and Playwright smoke tests.
