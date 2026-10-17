# Orbitakt

An iPhone drum machine played by the satellites overhead, in the spirit of an Elektron Machinedrum run through a dub desk: sparse, deep and echoing. Every satellite above your horizon is placed with SGP4 from CelesTrak's live catalog, and four families of them become four Euclidean rhythms: E(k, n), where **k is how many of that family are up there right now.**

It's the percussion piece of the environmental set with [Aether](https://github.com/samuelling/Aether) (the Bluetooth field), Bellweathered (the weather and sky) and [Leitmotif](https://github.com/samuelling/Leitmotif) (your phone's own data traffic).

## How the sky becomes rhythm

| Track | Satellites | Sound | In the cone | Character |
|---|---|---|---|---|
| **NAV** | GPS, Galileo, GLONASS, BeiDou (~20,000 km) | deep kick on the root | ~4 of 16 | Four up is four on the floor; three or five bend it. Changes over hours |
| **LEO** | Low orbits except Starlink: OneWeb, Iridium, weather and science satellites | tuned rimshot, mostly into the echo | ~2 of 16 | A few arrivals a minute, and each one throws the echo |
| **SWARM** | Starlink | metallic hat, brighter as more of the swarm is up | ~5 of 16 | Turns over every few seconds |
| **BELT** | The geostationary belt | dub chord stab | ~2 of 12 | Never moves: your location's fingerprint, drifting 12 against 16 |

**The cone.** Each track listens to a cone of sky around the zenith. By default the cone adapts like contrast gain control: it settles where it holds about the target number of satellites on average, then follows slowly (60 s time constant). The long-run density is divided out, and the moment-to-moment comings and goings pass straight through as changes in k. You can fix a cone by hand in Settings.

**One hit per satellite.** The playhead sweeps the sky clockwise from north once per bar. Euclid's algorithm spreads the k hits evenly, the bar is rotated to start at the newest arrival's bearing, and each hit plays the next satellite clockwise. East–west position sets pan. A new pattern is adopted only when its track wraps, so changes land on the bar line.

**Trig probability.** Like a Machinedrum trig condition, each step holds a chance rather than a plain on/off: satellites high in their cone always play, ones near the rim flicker in and out (about 45% at the rim for rimshots and hats, 70% for stabs; the kick always plays). Height also sets velocity.

**The stab.** BELT hits play a four-note chord built on the scale (root, third, fifth and seventh degree, or a sus-style voicing in five-note scales). The chord's root comes from where that satellite sits along the geostationary arc, east low to west high. Four detuned saws go through a resonant lowpass that snaps shut, the classic dub-techno chord, and almost all of it goes into the echo. With Bellweathered nearby, daylight opens the filter a little.

**The dub echo** is built into the engine: a stereo ping-pong on a dotted eighth, high- and low-passed and gently saturated in the loop, so repeats get darker and rounder, with a touch of tape wow. A plate reverb sits after it.
- *Throws:* whenever a low-orbit satellite crosses into its cone, or something passes straight overhead, the echo send is thrown open and the feedback pushed toward a spiral. It falls back over a few seconds, the way a dub engineer rides the send. The dome's horizon glows while it happens.
- *Dust:* a breath of hiss and crackle that thickens with the number of satellites overhead.

**Events.**
- *Zenith pings:* anything passing within 4° of straight up (adjustable) rings a glass bar into the echo, pitched by its catalog number. Expect one every minute or so.
- *Crew gong:* while the ISS or Tiangong is above the horizon, a gong every two bars, louder the higher it is.

**Tempo** is the period of the low orbits overhead, thirteen octaves up. A 95.6-minute Starlink orbit is 1/5736 Hz; × 2¹³ that's 85.7 BPM, a relaxed dub tempo. Higher shells are a little slower. You can also set it by hand, or follow Aether. Swing defaults to 10%.

## Playing together

Orbitakt listens in on Aether and Bellweathered over MultipeerConnectivity (Bluetooth or peer-to-peer Wi-Fi, no router needed), the same way Leitmotif does. Bellweathered's sky sets the key, Aether's radio room sets the tempo (folded by octaves into 60–132 BPM), and the orbits keep the rhythm. Both are optional, and each can be switched off in Settings › Together.

Aether and Bellweathered are the two *leads* and pair with each other; any other app is a *listener* that never invites and never sends, and both leads invite it in. So all four apps can play at once and the duo behaves exactly as before. The leads' Settings › Duo lists Orbitakt under "Listening in". `Shared/DuoLink.swift` is an identical copy of the Aether repo's (and Leitmotif's `Duo/` copy): change all three together.

## Data and accuracy

- **Catalog:** CelesTrak's active-satellites list (`GROUP=active&FORMAT=tle`, over 10,000 objects). CelesTrak updates every ~2 hours and allows one download per update, so Orbitakt fetches at most once every 12 hours and caches it. After any non-data reply (e.g. 403) it waits 12 hours; it never retries on its own. With no connection it uses its cache (up to 30 days old) or the simulated sky.
- **Propagation:** `SGP4.swift` is Vallado's SGP4 (WGS-72, "improved" mode). A Python mirror of the same code matches the reference implementation to 1e-9 km on the AFSPC verification set. High orbits run through the same equations without SDP4's lunar-solar terms, which keeps GPS and geostationary satellites within about 0.04° of the full model over three days. Highly eccentric high orbits (Molniya-type) are left out.
- **Observer:** your approximate location (rounded to ~1 km), WGS-84, with TEME → Earth-fixed by GMST (IAU-82). Polar motion and UT1−UTC are ignored; both are far below a dot's width.
- **Simulated sky:** the real shells as Walker constellations (Starlink 43°/53°/70°/97.6°, OneWeb, Iridium, Kuiper, the four navigation constellations, ~560 geostationary, both stations, and 1,800 scattered low orbits). Densities are realistic; positions are invented.

The whole catalog is propagated twice a second on a background queue (a few milliseconds). The sequencer runs on the audio thread, so hits land on the exact sample.

## Install on your iPhone

Needs a Mac with Xcode 16 or newer (Xcode 26 for iOS 26).

1. Open `Orbitakt.xcodeproj`.
2. **Signing & Capabilities** → **Team**: the project already uses the same team as Aether. If the bundle ID `com.samuelling.orbitakt` is taken, change it.
3. Choose your iPhone and press **▶ Run**.
4. Allow location (to know which sky is yours) and local network (to find Aether and Bellweathered), then tap **Play the sky**. Headphones or a decent speaker recommended: the kick sits at 49–92 Hz.

## Code map

- `SGP4.swift`: TLE parsing, SGP4, observer look angles, sidereal time
- `Catalog.swift`: families, CelesTrak fetch and cache, the simulated sky
- `SkyTracker.swift`: background propagation, snapshots of what's above the horizon
- `RhythmModel.swift`: adaptive cones, Euclidean patterns, pitches, pings, gong, tempo, link, settings
- `OrbitDSP.swift`: audio-thread sequencer with trig probability; the synthesized kit (a modal drum voice: three decaying partials, a pitch sweep and filtered noise; a four-saw stab voice); the dub echo and dust
- `OrbitEngine.swift`: dry bus (drums and echoes) plus a send into a plate reverb
- `DomeView.swift`: the sky dome and the step rows
- `OrbitaktApp.swift`: app, main screen, settings
- `Shared/`: the link with the other apps
- `AppStore/make_icon.py`: the icon, element 121 after Aether (119) and Bellweathered (120)
