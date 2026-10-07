# Changelog

Releases are tagged `vX.Y.Z`; pushing a tag runs `.github/workflows/release.yml`,
which builds, audits, tests and attaches `UBER256.COM`, `UBERSHOW.COM` and
`SHA256SUMS`. The notes for a tag are taken from its section below.

## [1.3.0] - 2026-10-07

### Added
- **Arpeggio voice** (OPL channel 4) from the second act: the bar's chord tones as plucked
  16th notes, plus extra kicks on steps 10 and 26 of every bar. Verified in tune and in
  chord by the music tests.
- **Kick-synced effects**: screen shake (CRTC start-address jolt), scene-art flash,
  starfield surge and wave-field ripple, all driven by one decaying `beat` value.
  Tests check each one, including that nothing flashes during a scene fade.

## [1.2.2] - 2026-10-07

### Fixed
- **Scene sequence now loops cleanly.** The scene index was `(frame >> 9) mod 18` on a
  16-bit clock, so after ~15.6 minutes scenes 0 and 1 repeated once at the wrap. It is
  now an explicit 0..17 counter advanced every 512 frames. A new test runs across the
  wrap and checks the index never jumps. (Removes the 1.0.0 known limitation.)

## [1.2.1] - 2026-10-07

### Changed
- Housekeeping only; the demo binary behaves as before. The 256-byte intro moved to its
  own repository, [uber256-dos-intro](https://github.com/djayuffe/uber256-dos-intro),
  so this repo now builds and tests just `UBERSHOW.COM` (the size gate is the 40K budget).
- Removed dead code (an unused define and variable), stale comments, and the test
  scaffolding that only the intro used.

## [1.2.0] - 2026-10-05

### Changed
- **Hyper-optimised field renderer**: ~10x cheaper (about 240k instructions per frame,
  down from 2000-3100k) so the demo fits a 70 Hz frame on 486-class hardware. Half
  resolution with doubled-word stores, lookup tables, and precomputed polar angle and
  radius maps. All field scenes were re-expressed on it (tunnel is now a real 1/r
  tunnel; vortex and finale are spirals).
- Scroller draws with direct stores instead of per-pixel `put_pixel` (~60k to ~10k).
- `SETBLOCK` now keeps 64 KiB (image 10 KB, maps at 4000h).
- Tests: polar maps vs `atan2`/`sqrt` for every block, palette range, and a
  per-frame instruction budget.

## [1.1.0] - 2026-10-05

### Changed
- **All field scenes reworked.** Scenes 2-15 and 18 were XOR/shift recurrences that
  rendered as noise. They are now sums of sines (sharing one `FIELD` loop and the
  existing sine table): tunnel, hyperbola bands, moire, soft checker, ripples,
  ribbons, warped plasma, copper bands, diamond rings, lattice, warp bands,
  scanwave, rotating grid, spiral vortex, finale. Validated in a real DOSBox run.

## [1.0.1] - 2026-10-05

### Fixed
- **Palette tear in the field scenes**: the 214-entry animated sweep still
  overran vertical blank in scenes 1-15 and 18, splitting the screen into
  horizontal colour bands. The sweep is now spread over four frames (one 64-index
  block per frame) and done in full only while a scene fades.
- **Scene 1 is a real plasma**: three summed sine waves mapped into the animated
  palette range, replacing an XOR pattern that rendered as tiled noise.

## [1.0.0] - 2026-10-05

First tagged release of the 40K edition.

### Added
- **Solid, shaded 3D engine** (`render_object`): perspective-correct backface
  culling, directional lighting in 32-bit integer maths, scanline polygon fill,
  per-frame interpolated rotation (`sincos16`), night-sky gradient and starfield
  behind a cube and an octahedron.
- **Wireframe phase** (last quarter of the 3D scene): the objects become hollow
  force-fields. Stars that fly into one are mirrored back out and flash warm
  white (`star_bounce`); a small solid core spins inside each (`draw_core_octa`,
  `draw_core_cube`). Near stars drag a short motion trail.
- **OPL2 FM music**: four melodic voices (lead, bass, pad, echo) plus the chip's
  rhythm section over a 4-bar form (Am | C | G | Em, ~15 s). True FM patches,
  bar-4 fill, cymbal at the top of the form, sixteenth-note hats and a syncopated
  kick in later bars, full silence at exit.
- 3D starfield scene, 18 scenes in total, with a sine-wave text scroller,
  scene-progress strip and fades/shutter transitions.
- True hardware double buffering: 128K VGA window plus CRTC start-address flip.
- **Behavioural test suite** (`tests/`): runs the built `.COM` in an emulated
  16-bit CPU and checks music theory, graphics, fixed-point maths, palette,
  frame-loop ordering and clean exit. ~80 checks.
- GitHub Actions: CI on every push and PR, tag-driven releases.

### Fixed
- **Palette tear**: the 256-entry animated DAC sweep ran before the fixed colours
  and overran vertical blank, so the palette changed mid-screen (a hard
  horizontal split). Fixed colours are now written first, the 3D scenes skip the
  sweep, and the sweep covers only indices 42-255. Only visible in a real run.
- Drums never fired and the OPL chip kept ringing after exit.
- Lead echo replayed a note the lead had never played.
- Fades scale colours instead of clamping components, which shifted hue (maroon
  sky mid-fade).
- A 386 32-bit-register leftover (`lea ax,[edx*2+2]`) read a dirty upper EDX.
- Original audit findings: `add al,si` (illegal in 16-bit mode) stopped the
  showcase assembling; `scene_feedback` fell through into the next scene and
  overran memory; the own-block `SETBLOCK` shrink was missing; Esc raced the BIOS
  IRQ1 handler (IRQ1 is now masked); build scripts lacked the executable bit;
  `run-dosbox.sh` silently throttled `cycles=max`.

### Investigated and rejected
Two claims in an upstream commit were tested and found wrong, so the code was not
changed:
- *"CRTC start-address registers are swapped."* Index `0Ch` is Start Address
  **high** and `0Dh` **low**; the existing order is correct, and the "fix" visibly
  tears the display in DOSBox.
- *"`draw_line` can hang."* A 49,517-line oracle (vertical, steep, diagonal,
  off-screen) found 0 hangs and 0 wrong pixels.

### Known limitations
- Field scenes still run the ~640-write animated palette sweep after retrace, so
  very slow machines may show slight palette banding there.
- Some VGA clones alias the two 64K pages; the demo has no fallback for that.
