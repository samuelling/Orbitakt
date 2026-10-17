# Orbitakt

An iPhone drum machine played by the satellites overhead, in the spirit of an Elektron Machinedrum run through a dub desk: sparse, deep and echoing. Every satellite above your horizon is placed with SGP4 from CelesTrak's live catalog, and the drum pattern is a literal reading of your sky: **a radar beam sweeps round from north, and every satellite near the zenith hits as the beam passes its bearing.**

It's the percussion piece of the environmental set with [Aether](https://github.com/samuelling/Aether) (the Bluetooth field), Bellweathered (the weather and sky) and [Leitmotif](https://github.com/samuelling/Leitmotif) (your phone's own data traffic).

## How the sky becomes rhythm

**The sky is the record; the beam is the needle.** The beam goes round once every two bars (or every bar), starting at north and turning clockwise. A satellite due east plays a quarter of the way through, due south halfway, due west three quarters. The dome shows it directly: the beam reaches a dot, the dot flashes, you hear it.

| Track | Satellites | Sound | In the cone | How it moves |
|---|---|---|---|---|
| **NAV** | GPS, Galileo, GLONASS, BeiDou (~20,000 km) | deep kick on the root | ~4 | Bearings change over hours, so the kick pattern shifts slowly |
| **LEO** | Low orbits except Starlink: OneWeb, Iridium, weather and science satellites | tuned rimshot, mostly into the echo | ~2 | Each crosses the sky in about ten minutes; you hear its hit slide through the sweep. New arrivals throw the echo |
| **SWARM** | Starlink | metallic hat, brighter as more of the swarm is up | ~5 | Hats drift, flam and merge as satellites cross |
| **BELT** | The geostationary belt | hi-hat into a gated reverb | ~2 | Never moves: your location's fingerprint |

**The cone.** Each track listens to a cone of sky around the zenith, and every satellite inside it plays once per sweep. The cone adapts slowly (ten-minute time constant) to hold about the target number on average. That divides out the difference between Starlink's hundreds and GPS's dozen, while a busy or empty spell still comes through as more or fewer hits. You can fix a cone by hand in Settings.

**Each hit is one satellite.** Its bearing sets *when* it plays. Its height in the cone sets *how loud* (a satellite at the zenith is loudest; one at the rim, quietest). East–west position sets pan. The beam re-reads the sky each time it passes north, so every hit lands where its satellite was at that moment.

**Literal ⟷ Grid.** Quantize pulls each hit from its exact bearing toward the nearest of 16 slots per sweep (eighths when a sweep is two bars). At 0 every hit is exactly where its satellite is, with the micro-timing that comes with it. At 100 it's a tight grid; swing applies to the grid. Default 50.

**The gated hat.** BELT hits are a longer, ringing hi-hat driving a gated reverb: a dense, bright room that the hit throws open and that slams shut about 150 ms later, cutting the tail dead. A little of the gated room reaches the dub echo. The hat's metal is tuned by where that satellite sits along the geostationary arc: darker in the east (about 3.8 kHz), brighter toward the west (about 6.2 kHz).

**The dub echo** is built into the engine: a stereo ping-pong on a dotted eighth, high- and low-passed and gently saturated in the loop, so repeats get darker and rounder, with a touch of tape wow. A plate reverb sits after it.
- *Throws:* whenever a low-orbit satellite crosses into its cone, or something passes straight overhead, the echo send is thrown open and the feedback pushed toward a spiral. It falls back over a few seconds, the way a dub engineer rides the send. The dome's horizon glows while it happens.
- *Dust:* a breath of hiss and crackle that thickens with the number of satellites overhead.

**Events.**
- *Zenith pings:* anything passing within 4° of straight up (adjustable) rings a glass bar into the echo, pitched by its catalog number. Expect one every minute or so.
- *Crew gong:* while the ISS or Tiangong is above the horizon, a gong every four bars, louder the higher it is.

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
- `RhythmModel.swift`: adaptive cones, the satellites on the radar, pitches, pings, gong, tempo, link, settings
- `OrbitDSP.swift`: the radar sweep on the audio thread (each satellite fires as the beam passes its bearing); the synthesized kit (one modal voice: three decaying partials, a pitch sweep and filtered noise); the dub echo and dust
- `OrbitEngine.swift`: dry bus (drums and echoes) plus a send into a plate reverb
- `DomeView.swift`: the sky dome with its beam, and each track's radar line
- `OrbitaktApp.swift`: app, main screen, settings
- `Shared/`: the link with the other apps
- `AppStore/make_icon.py`: the icon, element 121 after Aether (119) and Bellweathered (120)
