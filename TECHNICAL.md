# Technical notes

Implementation notes for `showcase.asm`, a 16-bit real-mode DOS `.COM` program targeting a
386+ instruction set. (The 256-byte intro lives in its own repo,
[uber256-dos-intro](https://github.com/djayuffe/uber256-dos-intro).)

## Contents
1. [COM model and memory](#com-model-and-memory)
2. [Frame loop and presentation](#frame-loop-and-presentation)
3. [Palette](#palette)
4. [Scene sequencing](#scene-sequencing)
5. [3D engine](#3d-engine)
6. [Starfield, bounce and cores](#starfield-bounce-and-cores)
7. [Music](#music)
8. [Input and shutdown](#input-and-shutdown)
9. [Pitfalls worth remembering](#pitfalls-worth-remembering)

## COM model and memory

DOS loads a COM image at `100h` of its PSP segment; `ORG 100h` makes NASM compute
labels for that. A `.COM` initially owns all free conventional memory, so `start:`
shrinks its own block (`INT 21h AH=4Ah`) to 16 KiB and moves onto a stack inside
it. Nothing is allocated from DOS afterwards: video RAM is the only large buffer.
The image is ~8 KB, so the 16 KiB block leaves headroom for the stack.

## Frame loop and presentation

Mode 13h is 320x200x8 at `A000:0000`. Graphics Controller register 6 (port `3CEh`)
is read-modify-written with `and al,0F3h`, clearing Memory Map Select so the CPU
window becomes 128K: segments `A000h` **and** `B000h` both reach VGA memory,
giving two 64,000-byte pages. Each frame renders into the hidden page, then
`present:`:

1. writes the CRTC start address (index **`0Ch` = high**, **`0Dh` = low**; page 1
   is `4000h` in chain-4 units of 4 bytes),
2. waits for vertical retrace (`3DAh` bit 3),
3. runs `palette_tick` (inside the blank), then increments the frame counter `bp`,
   steps the music and polls Esc.

The start address is written before the retrace wait because some hardware latches
it at retrace start; writing after leaves the flip a frame late. A scanline is
320 bytes so `65536 + 199*320 = 129216` bytes fit the 128K window. Some clones
mirror the first 64K twice; there is no fallback.

`bp` is the single frame clock. It is incremented only in `present:` and every
routine that uses `pusha` preserves it, so visuals, palette and music stay in
phase.

Overlays run after the scene and before presentation, in this order: raster bars
(not in the 3D scenes), scene-progress strip, shutter wipe, scroller. The scroller
is last so a wipe can never cover it.

## Palette

`palette_tick` writes the DAC (`3C8h`/`3C9h`, 6-bit components) every frame:

- **Fixed table first** (`fixed_pal`, 41 entries, indices 1-41): UI colours (1
  black, 2 white, 3 grey, 4-7 scroller rainbow), the shading ramp (8-23), the sky
  gradient (24-39) and two star shades (40-41). UI entries stay at full
  brightness during a fade; scene-art entries are scaled by `v*(limit+1)/64`.
  Scaling, not clamping, keeps hue (clamping `(20,8,28)` at 16 gives
  `(16,8,16)`).
- **Animated sweep second**, indices 42-255 only, skipped entirely in scenes 15-16. In the field scenes it is split across four frames: frame `q = bp mod 4` rewrites every fourth entry (index = q mod 4, each with its own index write), because the full sweep does not fit vertical blank. Interleaving rather than writing one contiguous 64-entry block per frame removes the visible seams a block boundary used to leave. During a fade the whole range is rewritten, since stale entries would show as brightness steps.

Order matters: the sweep is ~640 port writes, longer than vertical blank. When it
ran first the DAC changed part-way down the screen (a visible horizontal tear
in DOSBox that the emulator tests cannot see). The fixed table is ~125 writes and
fits the blank.

Fade: `pal_limit` ramps 0..63 over the first 32 frames of each 512-frame scene and
back down over the last 32. This also covers the very first frame, so no extra
global fade-in is needed.

## Scene sequencing

`cur_scene` is a 0..19 byte counter advanced in `present:` once every `2^SCENE_SHIFT`
frames (512, ~7.3 s) and wrapped at `SCENE_COUNT`; the dispatch, the progress strip
and the music transposition all read it, so they cannot disagree. It is deliberately
not `(bp >> 9) mod 20`: `bp` is 16-bit, so that form has only 128 groups of 512
frames and `128 mod 20 = 8`, which replayed scenes 0 and 1 once at every wrap of the
clock (after ~15.6 minutes). `tests/emu_test.py wrap` runs across the wrap and checks
the index never jumps. `SCENE_SHIFT` must stay at least 2 (the palette code shifts by
`SCENE_SHIFT-2`).

Scenes 1-15 and 18-20 use the field engine below; scenes 16-17 clear with `fill_sky` and draw 3D content.

### Field engine (the "hyper-optimised" renderer)

Budget: one 70 Hz frame, so the work per frame must be small. The previous fields
evaluated sines per pixel (2-3M instructions/frame); the engine does ~240k.

- **Half resolution**: each value is computed per 2x2 block (160x100) and stored with
  `STOSW` (the byte doubled) to the row and, `[es:di+318]`, the row below.
- **Tables**: `sin56` (0..55) and `sin165` (42..205) are built once from `sintab`.
  Values land in palette indices 42..255 (the animated part of the DAC): three
  `sin56` terms plus 42 stay below 207, and `sin165` already includes the offset.
- **Polar maps**: at start `build_maps` fills `ang_map` and `rad_map` (160x100 bytes
  each, at `4000h`, which is why `SETBLOCK` now keeps 64 KiB) with the angle (1/256
  turn, from a 65-entry atan table on min/max folded into the right octant) and
  `floor(sqrt(6(dx^2+dy^2)))` (an integer square root). Tests check both against
  `atan2`/`sqrt` for all 16,000 blocks.
- **Rotozoomer** (`fieldR`): the two 8.8 accumulators are texture coordinates and the top nibble of
  each indexes the 16x16 `tex_tab` tile; centring on (80,50) only needs the low 16 bits, because the
  texture repeats every 65536. **Radar** is `fieldM` with a squared-sawtooth `ta_tab` (`tab_ramp`).
- **Loops**: `fieldW` = `sin56[acc1] + sin56[acc2] + row term` with 8.8 phase
  accumulators (steps in `w_st*`, `w_ry*`); `fieldM` = `ta_tab[angle] + tr_tab[radius]`;
  `fieldS` = `sin165[ta_tab[angle] + tr_tab[radius]]` (spirals). The 256-entry
  `ta_tab`/`tr_tab` are rebuilt each frame (`tab_lin`; `tab_depth` gives the
  tunnel a true `1/r`).
- BH is kept at zero so `BL` can be both index and accumulator, and `BP` (the frame
  clock) is never touched.

## 3D engine

- **Rotation**: `sincos16` interpolates a 256-entry sine table (values x127) from a
  16-bit angle, so the pose changes every frame. Two-axis rotation per vertex.
- **Projection**: `screen = centre + rotated*SCALE / (depth+EYE)`, `CWD`/`IDIV`.
  Depth is clamped to at least 40 and coordinates are clamped, so the divisor can
  never be zero.
- **Culling**: face normals come from the *rotated* vertices and are tested against
  the real eye vector (not just the sign of normal-Z).
- **Lighting**: one directional light, `n.L / (|n||L|)` in 32-bit integers; the
  normal length of a regular solid is a precomputed constant (`obj_norml`), so no
  square root. Result selects one of 16 ramp entries; outlines use step 15.
  Faces are wound outward; the tables were generated and checked by script.
- **Fill**: `fill_poly` walks each edge in 8.8 fixed point filling `poly_min`/
  `poly_max` row arrays, then `REP STOSB`s spans, clipped to the page.
- **Lines**: `draw_line` is the Bresenham `dx+dy` form with `e2` computed once per
  iteration, bounds-checked per pixel (tested against an oracle over ~50k lines).
- Solid for three quarters of each scene, wireframe for the last (`bp & 180h`).

## Starfield, bounce and cores

32 stars; each star's depth `Z = 255 - ((3*bp + 37*i) mod 240)` is derived from the
frame clock alone, so there is no per-star state. (`DIV` leaves the quotient in AX
and the *remainder* in DX; the remainder, 0..239, is what is used, so `Z` is
16..255 and never zero.)

In the wireframe phase `star_bounce` mirrors any star that has entered a field
(radius 56 at the cube, 36 at the octahedron, distance measured as `max+min/2`) to
the same depth outside it, and flags it to flash. A solid core (`core_*_verts`,
`obj_norml` set for its size) is rendered under the wire edges. Stars closer than
`Z=150` add a trail pixel towards the vanishing point.

## Music

OPL2 at `388h`/`389h`, with the required write delays. Five 2-operator melodic
channels plus rhythm mode (register `0BDh`: kick 10h, snare 08h, tom 04h, cymbal
02h, hat 01h).

- Timing: 8 frames per step, 32 steps per bar, 4 bars (Am | C | G | Em, ~15 s).
  A step fires at `bp%8==0`; key-off for the gap lands at `bp%8==6`.
- Notes are packed `fnum | block<<10`. An octave is `+400h`; the block field is 3
  bits, so two act transpositions already reach block 7 and the echo cannot move
  up further.
- Patches have connection bit **0** (true FM; 1 would be additive). `opl_set_instrument`
  takes a channel and an 11-byte patch.
- Everything stays in A minor pentatonic, so the voices cannot clash. The bass
  plays chord roots, the pad chord tones, the echo repeats the lead two steps late
  from frame 24 on, hats add off-beat sixteenths after bar 1, bar 3 has a
  syncopated kick and bar 4 ends with a snare/tom fill.
- `opl_silence` keys off all nine channels and clears rhythm at init and exit.
- **Arp** (channel 4) plays from the second act (scene 9) on: the bar's four chord tones as a
  16th-note arpeggio, read from the pad's chord table, so it cannot leave the chord. From
  that act the kick also lands on steps 10 and 26 of every bar.

### Kick-synced effects

`drum_step` sets `beat = 31` on every kick; `music_tick` decays it by 2 a frame, and
four effects read it:

- **Shake**: `present:` adds `80 * (beat >> 3)` to the CRTC start address, i.e. 0-3 rows
  (one row is 80 start-address units). The rows that scroll in lie outside both pages
  (`64000 + 3*320 < 65536`, and page 1 ends well inside the 128K window) and are black.
- **Flash**: `palette_tick` adds `beat >> 3` (0-3) to scene-art entries after the fade
  scaling, clamped to 63. UI colours never flash, and nothing flashes while a scene fades.
- **Surge**: the starfield depth phase `star_phase` advances by `3 + (beat >> 2)` per
  frame and is kept in 0..239, so there is no jump at any wrap.
- **Ripple**: `fieldW` offsets the row wave phase by `beat << 7`, so the bands bounce.

## Input and shutdown

Esc is read from the 8042 (`64h` status, `60h` data). IRQ1 is masked at the PIC for
the duration, because the BIOS handler otherwise drains the controller first and
Esc is almost never seen. Exit silences the chip, restores IRQ1 and text mode and
returns through DOS.

## Pitfalls worth remembering

- 32-bit register use in 16-bit code leaves upper halves dirty; do address
  arithmetic in 16-bit.
- 16-bit `cmp`/`test ax` right after an 8-bit write to AL/AH is a bug; `audit.py`
  lints for it.
- `SI`/`DI` have no byte halves in 16-bit mode.
- Static audits are text matching only. They passed while a drum pattern never
  fired and while the palette tore. Behaviour needs the emulator tests; look needs
  a real DOSBox run.
- A merge that combines individually reasonable hunks can still fail to assemble;
  always rebuild after merging.
