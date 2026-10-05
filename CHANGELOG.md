# Changelog

Releases are tagged `vX.Y.Z`; pushing a tag runs `.github/workflows/release.yml`,
which builds, audits, tests and attaches `UBER256.COM`, `UBERSHOW.COM` and
`SHA256SUMS`. The notes for a tag are taken from its section below.

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
- The scene index is `(frame >> 9) mod 18` on a 16-bit frame counter. 128 is not a
  multiple of 18, so after ~15.6 minutes of continuous play scenes 0 and 1 repeat
  once at the counter wrap before the cycle resumes.
- Field scenes still run the ~640-write animated palette sweep after retrace, so
  very slow machines may show slight palette banding there.
- Some VGA clones alias the two 64K pages; the demo has no fallback for that.
