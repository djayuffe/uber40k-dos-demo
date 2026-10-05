# FINAL DESIGN / ARCHITECTURE REVIEW

## Release verdict

The project is structured as two deliberately different products:

1. `intro256.asm` — sizecoding experiment with a hard <=256-byte build gate.
2. `showcase.asm` — a conventional real-mode VGA production where visual continuity,
   cleanup and readability take priority over byte count.

This separation is the correct architecture. The showcase does not pretend that
production-safe DOS allocation, backbuffering, transitions and audio belong in 256 bytes.

## Rendering architecture

`UBERSHOW.COM` uses VGA mode 13h (320x200x8) with true hardware double
buffering: it widens the VGA CPU window to 128K (Graphics Controller Misc
Register, Memory Map Select = 00) so segments A000h and B000h both address
real video RAM, giving two independent 64,000-byte pages. Each frame renders
entirely into the hidden page, then `present:` flips the CRTC start-address
register to display it — a genuine hardware page flip, not a software
backbuffer copy.

All eighteen scenes obey one renderer contract:
- ES points at the current hidden VGA page.
- DI starts at zero.
- the full-screen renderer emits 64,000 pixels (or, for scene_cube and
  scene_starfield, clears the page with `rep stosw` and draws 3D objects).
- presentation overlays are applied afterward.
- `present:` flips the CRTC to show the finished page.

This keeps effects independent of DOS memory management and VGA presentation,
and eliminates the conventional-memory backbuffer entirely.

## Art direction

The final show is organized conceptually into three acts (cur_scene/8, used
by the music transposition), with the visual progression flowing through
four character families:

- ANALOG (scenes 0–3): plasma, tunnel, multiplier field, moire.
- GEOMETRY (scenes 4–7): grid, ripple, ribbons, feedback.
- DIGITAL (scenes 8–11): copper, diamond, lattice, warp.
- TERMINAL (scenes 12–17): scanwave, bitplane, vortex, cube+octahedron,
  starfield, finale.

The common raster treatment and scene-progress strip make the eighteen
algorithms feel like one production instead of eighteen unrelated test
patterns. Palette generation uses the global frame clock plus scene-family
phase, so the acts change chromatic character without loading assets.

## Motion and pacing

Every effect is driven by the same monotonically increasing frame word. Scenes last
512 frames. A 32-frame DAC fade enters/exits each scene and a short shutter overlay
reinforces the cut. The audio sequencer and raster motion never reset at a scene
boundary, which avoids the 'slideshow' feel produced by restarting all phases.

The renderers intentionally favor 16-bit integer recurrence, shifts, XOR and adds.
Multiply-heavy radial effects exist for contrast but are not used for every scene.

## Audio

OPL2 FM synthesis (Sound Blaster / AdLib, fixed port 388h/389h): four
simultaneous melodic voices (lead, bass, pad, echo) plus the chip's built-in
rhythm section (kick, snare, hi-hat). Each voice has its own instrument patch
and step sequencer, all phase-locked to the global frame counter. The scene
index transposes the note tables (adding 0x400 per act = one octave up), so
the soundtrack follows the visual progression. `opl_silence` keys off all 9
channels and clears the rhythm register at exit.

## Input and cleanup

Keyboard reads are guarded by the 8042 status register. Because interrupts stay enabled
and the BIOS's own INT 9 handler is still attached to IRQ1, polling port 60h directly
without masking that IRQ loses the race almost every time — the BIOS ISR drains the
controller's output buffer first, so Esc would rarely be seen. The demo therefore masks
IRQ1 at the 8259 PIC for its duration and restores the original mask on exit. ESC exits.
The demo silences the OPL2 (keys off all 9 channels, clears the rhythm register),
unmasks IRQ1, restores the original video mode, and returns through INT 21h.

## Known hardware boundary

The CRTC page flip lands inside vertical blank (the flip is issued after
`wait_vsync` detects retrace), so there is no tearing. The only boundary is
that the renderer must finish before the next retrace — on a slow CPU with a
fast monitor this could cause a dropped frame, but not a torn one.

## Final layout

- `intro256.asm` strict sizecode source
- `showcase.asm` full show
- `build.sh` reproducible NASM build and <=256-byte enforcement
- `run-dosbox.sh` launch helper
- `DOSBOX.CONF` emulator configuration
- `audit.py` baseline structural audit
- `audit_final.py` 18-scene renderer audit
- `release_audit.py` final architecture/release audit
- `README.md` user-facing build/run documentation
- `TECHNICAL.md` implementation notes
- `FINAL_REVIEW.md` this design review
- `MANIFEST.sha256` release hashes

## Validation boundary

NASM and DOSBox are now installed and have been used directly: both `.COM` files
assemble cleanly via `build.sh`, and both were launched in real DOSBox and watched
render, animate and exit cleanly on Esc. This is what actually caught the two bugs
that the static source/package audits could not see — an illegal opcode that kept
`showcase.asm` from assembling at all, and a missing own-memory-block shrink that
kept `UBERSHOW.COM` from ever getting past "not enough conventional memory" even
once it did assemble. Static audits remain useful as a fast regression gate, but
they are not a substitute for an actual build-and-run pass, which should be repeated
whenever `showcase.asm` or `intro256.asm` change.

## 6.0 expansion: scene 16 (3D), text scroller, music, raster glow

The showcase grew two non-field scenes (16: 3D cube+octahedron, 17: 3D
starfield) and a persistent bottom overlay:

- **scene_cube** breaks the established "every scene is a full-field STOSB sweep"
  contract on purpose: it's a real 3D vector object (two-axis rotation, true
  perspective projection with a distance divide, a from-scratch Bresenham line
  draw), not another procedural per-pixel field. It clears the page with
  `rep stosw` instead, and `audit_final.py` was extended with a scene-specific
  check for that shape rather than relaxing the general per-scene invariant.
- A 5x7 bitmap-font **sine-wave text scroller** runs along the bottom every frame,
  reusing the cube's sine table for its wave and glyph columns for a classic wavy
  look, with a small fixed rainbow foreground that cycles along the message and
  over time.
- **DAC indices 1-7 are now reserved** immediately after `palette_tick`'s main
  animated loop, overriding whatever it just assigned those indices, so the
  scroller and cube stay legibly high-contrast regardless of the current
  per-scene animated palette. Before this fix the scroller/cube used indices that
  were *also* written by the animated loop and could converge to near-identical
  tones -- confirmed visually (and then fixed) by actually running the showcase
  in DOSBox, not by static review.
- Raster bars changed from one flat scanline to a dim/bright/dim three-line glow.
- Music: replaced an ad hoc note table and linear-subtraction transposition with
  an explicit A-minor-pentatonic scale, real rests, a short pre-retrigger mute for
  staccato note attacks, and octave-consistent transposition (adding 0x400 to the
  packed note value, which is always exactly one octave up regardless of starting
  pitch, unlike the previous raw subtraction). Later expanded from one PC-speaker
  channel to four OPL2 FM voices (lead/bass/pad/echo) plus the built-in rhythm
  section.

`UBERSHOW.COM` grew from 1523 bytes (first audited build) to roughly 3.6 KB; the
SETBLOCK memory shrink in `start:` was widened from 256 to 512 paragraphs (8 KiB)
to keep comfortable headroom for the added font/scroller/cube tables.
