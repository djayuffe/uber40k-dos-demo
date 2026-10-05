# UBER40K — a zero-asset DOS VGA/OPL2 demoscene production

![UBERSHOW running in DOSBox](screenshot.jpg)

Two flat real-mode DOS `.COM` programs, hand-written in NASM assembly, that run on
DOSBox or real VGA/Sound-Blaster-compatible DOS hardware. There are no image files, no
fonts loaded from disk, no music samples or MOD/trackers, no libraries, and no
protected-mode extender — every pixel, glyph, FM note and 3D vertex is generated
procedurally by the code itself. "40K" names the size class this sits in: the full
show, with a real 3D engine and Sound Blaster FM music, still fits comfortably inside
a 40,960-byte budget — it currently runs at roughly a tenth of that.

| File | Purpose | Size | CPU | Video | Audio |
|---|---|---|---|---|---|
| `intro256.asm` | strict ≤256-byte sizecoded intro | 70 bytes | 386+ | VGA mode 13h | none (silent) |
| `showcase.asm` | full multi-scene production demo | ~7.4 KB | 386+ | VGA mode 13h | OPL2 FM (Sound Blaster/AdLib) |

## Quick start

```sh
./build.sh        # assemble both .COM files with NASM, run the audits
./run-dosbox.sh   # run UBERSHOW.COM in DOSBox (pass UBER256.COM for the intro)
```

Press **Esc** to exit cleanly back to DOS. Requires [NASM](https://www.nasm.us/) and
[DOSBox](https://www.dosbox.com/) on your `PATH` (on macOS, `brew install nasm` and
`brew install --cask dosbox` — the launcher also finds `dosbox.app` automatically if
it isn't symlinked onto `PATH`).

## `UBERSHOW.COM` — the showcase

A single continuous demo, driven by one 16-bit frame counter that never resets, so
visuals, palette, music and overlays all stay phase-locked to each other.

**18 scenes**, ~7.3 real seconds each at the emulated monitor's 70 Hz:

| # | Scene | Technique |
|---|---|---|
| 1 | Interference plasma | affine X/Y waves folded through XOR |
| 2 | Radial tunnel | squared centered coordinates, no perspective divide |
| 3 | XOR multiplier field | `x*y` dense nonlinear lattice |
| 4 | Concentric moire | squared radial distance rings |
| 5 | Zooming checker grid | no multiply in the inner loop |
| 6 | Dual-source ripples | Manhattan-distance interference |
| 7 | Twisting vertical ribbons | per-scanline phase shift |
| 8 | Cellular/feedback field | deterministic, no prior-frame dependency |
| 9 | Copper-wave bands | cheap scanline recurrence |
| 10 | Expanding diamond rings | Manhattan distance, no multiply |
| 11 | Animated lattice | diagonal XOR interference |
| 12 | Horizontal warp bands | sign-extended phase offset |
| 13 | Scanwave / CRT bands | odd/even scanline shift |
| 14 | Bitplane interference | AND-masked digital look |
| 15 | Vortex mixer | signed-coordinate XOR, no division |
| 16 | **Cube + octahedron (3D engine)** | real 3D, perspective: see below |
| 17 | **3D starfield** | real 3D, perspective: see below |
| 18 | Finale | combines time, coordinates and radial energy |

Scenes 1–15 and 18 are full-screen procedural fields: a `STOSB` loop touches all
64,000 pixels every frame from cheap integer recurrences (XOR, shifts, the
occasional `IMUL`) — no lookup tables, no asset data. Scenes 16–17 are
architecturally different (see below) and are the only ones that don't fit that
renderer contract.

On top of every scene:
- **Three soft-glow raster bars**, phase-locked to the frame clock, each a
  dim/bright/dim triple scanline rather than one flat line.
- **An 18-block scene-progress marker** in the top-left corner.
- **A palette-domain fade** in/out around every scene boundary (hides the hard cut).
- **A symmetric shutter transition** (black bars closing/opening) layered on top.
- **A colour-cycling sine-wave text scroller** along the bottom (see below).

### 3D engine: solid shaded cube + octahedron (scene 16)

The 3D scene runs on a small reusable engine, not one hardcoded shape. `render_object`
takes a vertex list, a face list and a screen offset and does the rest:

- **Rotation + perspective** — two-axis rotation from a 16-bit angle, then a true
  perspective divide. `sincos16` linearly interpolates a 256-entry ±127 sine table, so
  the pose changes continuously on **every** frame (an earlier version indexed the table
  directly at half a step per frame, which updated every other frame: a visible 35 Hz
  judder on a 70 Hz display).
- **Backface culling** — each face's normal is computed from the *rotated* vertices and
  tested against the real eye position (not just the sign of normal-Z, or faces seen at a
  glancing angle would drop out).
- **Flat lighting** — one directional light, `n·L / (|n||L|)` in 32-bit integer maths,
  mapped onto a 16-step shading ramp reserved in the DAC. Every face of a regular solid
  has the same normal length, so it divides by one precomputed constant, not a square root.
- **Scanline polygon fill** — `fill_poly` walks each edge once in 8.8 fixed point,
  recording left/right extents per row, then fills the spans with `REP STOSB`; clipped to
  the page on all sides. Faces are outlined with the Bresenham line routine.
- **Two render modes** — solid for three quarters of every scene, plain wireframe (the
  original renderer) for the rest.

The face tables are *generated and orientation-checked by script* (the cross product of
each face's first three vertices must point outward), because culling and lighting both
silently depend on that winding being right. The scene draws a cube and an octahedron
with different rotation rates, over a **night-sky gradient with the star field behind
them**, so it reads as a place rather than two shapes on black.

### 3D starfield (scene 17)

A field of 32 stars, each with a genuine Z depth streaming toward the viewer and
perspective-projected exactly like the cube's vertices (divide by distance, not
orthographic). Every star's position is computed fresh each frame purely as a
function of the frame clock and its own index — no persistent per-star state to
track: Z counts down from far to near and wraps back to far on its own, so stars
continuously fly past and recycle forever without ever needing to be "respawned"
by special-case code. Shade steps with depth in four levels (dim grey, mid grey, white, warm white) and the
nearest stars are drawn 2×2, so they read as closer rather than just brighter. The same
`star_pass` also runs behind the cube scene.

### Sine-wave text scroller

A from-scratch 5×7 bitmap font (33 glyphs: the letters/digits/punctuation the
scroller message actually uses) rendered column-by-column along the bottom 8
scanlines, with each column's vertical position offset by the same sine table the
cube uses, for the classic wavy-scroller look. The foreground colour cycles through
a small fixed rainbow (red/yellow/green/cyan) both along the message and over time,
so it doesn't just sit as flat white. Only lit pixels are drawn, each with a one-pixel
black drop shadow, so the sky shows between the letters (it used to sit on a solid black
band); it advances one pixel every frame. Two DAC indices are reserved as fixed pure
black/white (and four more for the rainbow) so the scroller and cube stay legible
regardless of what the main per-scene palette animation is doing elsewhere — see
"Fixed vs. animated palette" below.

### Music: OPL2 FM (Sound Blaster / AdLib)

`UBERSHOW.COM` drives the OPL2 FM synthesiser chip directly at its fixed I/O port
(`388h`/`389h`) — the same chip every Sound Blaster card carries for AdLib
compatibility, so no `BLASTER` environment-variable base-port detection is needed at
all; this works identically on any SB card and on a plain AdLib. It uses the chip
about as fully as a sizecoded driver reasonably can: four melodic voices plus the chip's
built-in rhythm section, arranged as a chord progression rather than a loop.

**A real song form, not a loop.** Everything runs from one global step counter
(8 frames per step, 32 steps per bar) over a **4-bar chord progression — Am | C | G | Em**
(~15 s per pass, versus the 3.7 s identical loop this used to be). Every note stays inside
A minor pentatonic, which fits all four chords, so melody and harmony cannot clash:

- **Lead** (channel 0) — four *different* 32-step phrases, one per chord, landing on that
  chord's tones on the strong beats; the last ends on A to lead back into the first.
- **Bass** (channel 1) — one root/octave/rest pattern played on each bar's chord root
  (A, C, G, E).
- **Pad** (channel 2) — the chord's tones, one every 8 steps. Each change keys off then on,
  so it gets a real swell instead of just gliding.
- **Echo** (channel 3) — the lead's note from two steps ago, replayed softer: a tape-delay
  shimmer. It stays in the lead's octave on purpose (see "Transposition headroom").

**True FM.** The patches set the connection bit to 0, so the modulator actually drives the
carrier. (An earlier version set it to 1, which on the OPL2 means *additive*: two sine
waves simply summed, so the "FM" voices were never FM at all and the modulator level
controlled nothing useful.) The lead and echo carry feedback; the lead and pad have vibrato.

`opl_set_instrument` is a generic routine — channel number plus an 11-byte patch — so a new
voice is a patch and a step table, not new driver code; the channel-to-operator map
(`chan_op1`/`chan_op2`) is the standard OPL2 layout and works for all 9 channels.

**Rhythm section** (the chip's built-in percussion mode, register `0BDh`): kick on the
downbeat, snare on the backbeat, hi-hat on the off-beats; a **snare + tom fill** through the
last 8 steps of bar 4; a **cymbal crash** on the first step of bar 1 marking the top of the
form.

**Clean shutdown**: a real Sound Blaster/AdLib keeps sounding whatever was last keyed
on after the program returns to DOS, so `opl_silence` keys off all 9 channels and
clears the rhythm register at exit (and at init, in case a previous program left
the chip in a state).

**Transposition headroom**: the melodic voices transpose across the show's three acts by **adding 0x400
to the packed note value per step** — block occupies bits 10-12 of that value, so
this is always exactly one octave up regardless of the starting note, the same
"transpose by a real musical interval, not an arbitrary offset" idea the earlier
PC-speaker version used with PIT-divisor halving. Real rests (not a continuous
drone) and a short silence before each retrigger give the lead and bass clean note
attacks. The packed note's block field is only 3 bits wide and the lead's highest
note already sits at block 5, so two act transpositions reach the field's maximum
(7) — which is why the echo can't also shift up an octave without overflowing.

`intro256.asm` is silent: no sound hardware is touched at all, deliberately — a
256-byte sizecoded intro has no room for an FM driver and a note sequencer.

### Fixed vs. animated palette

`palette_tick` drives one continuous animated formula across all 256 DAC entries every frame,
which suits the procedural fields but guarantees no index keeps a stable colour. So a table
of **fixed colours is rewritten over it every frame**: UI (1 black, 2 white, 3 dim grey,
4-7 the scroller rainbow), the 16-step shading ramp for solid faces (8-23), the 16-step sky
gradient (24-39) and two star shades (40-41).

Entries are flagged as UI or scene art. UI stays at full brightness through a scene fade;
scene art fades **by scaling** (`v·(limit+1)/64`), not by clamping each component. A clamp
shifts hue (`(20,8,28)` clamped at 16 becomes `(16,8,16)`: the maroon sky that showed up
mid-fade before this was fixed); scaling only darkens.

## `UBER256.COM` — the strict intro

A classic sizecoded 256-byte intro: almost the entire program is one pixel
recurrence (XOR, add, multiply, shift) over `X`, `Y` and a frame counter, written
directly with `STOSB` — no asset data, no clearing pass, BIOS/DOS used only for mode
entry/exit. Coordinates double as loop counters; register reuse and arithmetic
overflow are the texture generator, not bugs. Comes in at 70 bytes, with the
remaining ~186 bytes of the 256-byte budget unused.

## Hardware model

BIOS `INT 10h` AX=0013h selects 320×200, 256-colour VGA (mode 13h): one byte per
pixel, a 64,000-byte framebuffer at `A000:0000`. Since 64,000 < 65,536, the whole
frame fits in one real-mode segment and a linear `STOSB` can traverse it without
bank switching — `offset = y*320 + x`, and a full-frame renderer doesn't even need
the multiply if it just starts `DI=0` and does 64,000 sequential stores.

The showcase programs the VGA DAC through ports `3C8h`/`3C9h` (six-bit R/G/B per
entry), polls port `3DAh` bit 3 for vertical retrace as a frame-pacing boundary, and
reads the 8042 keyboard controller directly (status port `64h`, data port `60h`) for
Esc — with IRQ1 masked at the 8259 PIC for the program's duration, since otherwise
the BIOS's own interrupt handler races the direct port poll and wins almost every
time (see "Known issues this audit found and fixed" below). Music output goes
through the OPL2 FM synth at ports `388h`/`389h` (see "Music" above).

### True hardware double buffering (VGA page flip)

`UBERSHOW.COM` does not render into a system-RAM backbuffer and copy it to VRAM
every frame. Instead, right after setting mode 13h it reprograms the Graphics
Controller's Miscellaneous Register (port `3CEh` index 6) to widen the VGA CPU
window from the BIOS's default 64K at `A0000h` to a full 128K at `A0000h`
(Memory Map Select = 00) — which makes segments `A000h` *and* `B000h` both
address real VGA memory, giving two independent 64,000-byte pages inside actual
video RAM. Each frame renders entirely into whichever page isn't currently
displayed, then `present:` flips the CRTC start-address register (port `3D4h`
indices `0Ch`/`0Dh`, in chain-4 units of 4 bytes) to display it — a genuine
hardware page flip, not a blit. This removes the need for any DOS conventional-
memory backbuffer allocation entirely.

**Flip order matters.** `present:` writes the new start address *first*, then waits for
retrace, and only then does the palette update and draws into the other page. It used to
wait for retrace and write the address afterwards: on hardware that latches the start
address at retrace start the flip then lands a frame late and the next frame is drawn into
the page still being scanned (visible tearing). DOSBox latches at frame start, which hid it.

A `.COM` program still owns *all* free conventional memory at launch by default
(its PSP block spans to the top of the DOS arena), which matters here because the
program's own font/scroller/cube tables and small stack need conventional memory
to live in — `start:` **shrinks its own memory block** (`AH=4Ah`, SETBLOCK) to
8 KiB immediately, before anything else, and switches onto a small local stack
inside the block it keeps. (It did need this shrink for a 64,000-byte backbuffer
allocation too, before the page-flip rewrite — see "Known issues" below.)

## Timing: vsync pacing vs. DOSBox's `cycles` setting

The showcase paces itself correctly in software regardless of host speed: every
frame polls the real VGA retrace bit via `wait_vsync` before presenting, capping
display rate at the emulated monitor's ~70 Hz. `DOSBOX.CONF` ships with
`cycles=max` / `core=auto` — this does **not** defeat that pacing; it just lets the
CPU render each frame's effect as fast as the host allows and then wait at the
retrace poll, same as the host-fast-forward-then-wait behavior of any other DOSBox
program. A fixed lower cycle count only risks the renderer not finishing before the
next retrace (visibly stuttery), for no benefit — and in testing, a mid-range fixed
value was observed getting silently throttled further by DOSBox's own
auto-adjustment under host load anyway.

`run-dosbox.sh` builds a temporary conf from `DOSBOX.CONF` with the actual
mount/run commands folded into its own `[autoexec]` section before launching with
`-conf` alone: combining `-conf` with separate command-line `-c` autoexec flags was
found (in this testing) to silently cap `cycles=max` at a low fixed value instead of
running full speed, so the launcher avoids that combination entirely.

## Source audits

Three layered static checks, run as part of `./build.sh`:

- **`audit.py`** — structural sanity: COM origin/mode declarations, VGA entry,
  framebuffer usage, rejects accidental x86-64-only register names (`sil`/`dil`/
  etc., illegal in 16-bit real mode — this class of bug did slip through once, see
  below).
- **`audit_final.py`** — per-scene invariants: all 18 scenes present, each one
  either does a full 320×200 `STOSB` sweep ending in `jmp overlay`, or (for
  `scene_cube`/`scene_starfield`) clears via `rep stosw` and projects/draws with
  perspective math instead; checks the DAC/input/cleanup invariants and that every
  scene actually hands off to `overlay` instead of falling through into the next.
- **`release_audit.py`** — whole-tree release gate: every file present, every scene
  label appears exactly once, memory/VGA/palette/input/audio invariants, the strict
  256-byte build gate.

These catch structural regressions fast, but **they are not a substitute for an
actual build-and-run pass** — see below for what a real assemble-and-run turned up
that pure static/text-level checks could not.

## Testing

Three layers, because each catches things the others can't:

1. **Static audits** (`audit.py`, `audit_final.py`, `release_audit.py`, run by
   `./build.sh`) — structure and invariants in the source text, including a narrow
   lint for a 16-bit compare on `AX` straight after an 8-bit write to `AL`/`AH`.
2. **Behavioural tests** (`tests/run_tests.sh`) — runs the *real, built* `.COM` files in an
   emulated 16-bit CPU (Unicorn), trapping port I/O and DOS/BIOS interrupts. It can build
   variants of the program (forced scene, faster scene clock), call individual routines in
   isolation, and snapshot the displayed page. What it asserts:
   - **music** — what the OPL2 receives and when, checked against music theory: every note
     is in tune (<15 cents) and in A minor pentatonic; the bass plays only each bar's chord
     root and the pad only chord tones; the four bars are four different phrases and the
     form repeats exactly; kick/snare/hat/tom/cymbal land only where intended; the chip is
     fully silenced at exit.
   - **graphics** — solid faces are drawn and lit differently, wireframe mode draws none,
     back faces are culled, the sky is a monotone gradient, rotation advances by a constant
     step *every* frame.
   - **math, in isolation** — `sincos16` against `math.sin`/`math.cos` (±0.91 on a ±127
     scale, no discontinuity at the table wrap); `fill_poly` against known geometry (a
     triangle and a rectangle fill their *exact* pixel counts; full-screen, off-screen,
     partly-clipped and degenerate polygons never touch memory outside the page).
   - **palette** — the fade is exactly proportional at every frame and UI colours never fade.
   - **robustness** — all 18 scenes execute without leaving their page or unbalancing the
     stack; every note stays audible at every transposition; the frame loop flips before it
     waits; both programs exit cleanly (IRQ1 restored, stack balanced).
   Needs Python 3; installs `unicorn` into a throwaway `./.venv`; takes a few minutes.
3. **Live DOSBox** (`./run-dosbox.sh`) — the real target, for what the other two can't
   judge: does it look right.

The behavioural layer exists because the first two can't observe sound: a drum
pattern that never fires, or a chip left ringing after exit, passes every static check
and every screenshot.

## Files

- `intro256.asm` — strict sizecoded intro source
- `showcase.asm` — full showcase source (scenes, scroller, cube, music, palette)
- `audit.py`, `audit_final.py`, `release_audit.py` — layered static source audits
- `build.sh` — reproducible NASM build, audit run, and 256-byte gate enforcement
- `run-dosbox.sh` — DOSBox launcher (showcase by default, `UBER256.COM` as `$1`)
- `DOSBOX.CONF` — DOSBox configuration (vsync-correct `cycles=max`/`core=auto`)
- `tests/` — behavioural emulator tests (`run_tests.sh`, `emu_test.py`)
- `MANIFEST.sha256` — SHA-256 hashes of every source file
- `TECHNICAL.md` — low-level implementation notes (COM loading, DAC, retrace, …)
- `FINAL_REVIEW.md` — design/architecture review
- `screenshot.jpg` — `UBERSHOW.COM` running live in DOSBox

## Known issues this audit found and fixed

This project was originally packaged in an environment with **no NASM or DOSBox
available**, so it had never actually been assembled or run before this audit. A
real build-and-run pass (installing both tools and testing live in DOSBox) found
several bugs the static/text-grep audits could not catch on their own:

- **`showcase.asm` didn't assemble at all**: `scene_tunnel` used `add al,si`, which
  is illegal in 16-bit real mode (SI has no addressable low byte, unlike AX/BX/CX/
  DX). Fixed by routing the value through BX.
- **Memory corruption**: `scene_feedback` was missing its `jmp overlay`, so it fell
  through into `scene_copper`'s renderer with `DI` already past the end of the
  64,000-byte backbuffer — wrapping the segment offset and overrunning the
  DOS-allocated block. Fixed, and `audit_final.py` now checks every scene for a
  terminating jump so this can't pass silently again.
- **`UBERSHOW.COM` could never actually run**: it always printed "not enough
  conventional memory" and exited immediately, confirmed live in DOSBox. Root
  cause and fix described above under "A DOS `.COM` memory-model gotcha".
- **Esc was effectively non-functional**: direct 8042 port polling for the
  keyboard raced the BIOS's own IRQ1 handler (which almost always won), with no
  guard in `intro256.asm` at all and an incomplete one in `showcase.asm`. Fixed in
  both by masking IRQ1 at the 8259 PIC for the program's duration.
- **`build.sh`/`run-dosbox.sh` shipped without the executable bit**, so the
  documented commands failed outright.
- **The scroller/cube lost contrast** against the main per-scene animated palette
  (both used plain DAC indices that the animation loop also wrote every frame, so
  foreground/background could converge to similar tones). Fixed by reserving fixed
  DAC entries, as described above.
- **`run-dosbox.sh` silently ran at throttled speed**: combining `-conf` with
  separate `-c` autoexec flags capped DOSBox at a low fixed cycle count instead of
  `cycles=max`. Fixed by folding the autoexec into the conf file itself.
- Several documentation inaccuracies (a mis-described memory-allocation size, a
  stale pixel-store comment) were also corrected.

All three audit scripts and a full `./build.sh` pass; both `.COM` files have been
built with real NASM and run live in DOSBox, confirmed rendering, animating, and
exiting cleanly on Esc.

## Later additions

- **True VGA hardware double buffering**, replacing the original system-RAM
  backbuffer + `REP MOVSW` copy with a real CRTC page flip (see above) — removes
  the DOS conventional-memory backbuffer allocation entirely. Verified live in
  DOSBox and with an extended headless run showing no crash.
- **Scene 17: a 3D starfield** with genuine perspective-projected depth, using
  the same math as the cube.
- **Music extended to a 32-step call-and-response phrase** instead of a 16-step
  loop.
- `run-dosbox.sh` was found to be **silently running at a throttled ~3000 cycles**
  instead of `cycles=max`: combining `-conf` with separate `-c` autoexec flags on
  the command line defeats DOSBox's max-cycles detection in this build. Fixed by
  folding the autoexec commands into the conf file's own `[autoexec]` section and
  launching with `-conf` alone (confirmed live: title bar reads "max 100%
  cycles"). It also didn't fall back to the Homebrew cask's `.app` bundle when
  `dosbox` wasn't on `PATH` — fixed.
- **`draw_line` had a real infinite-loop bug**, found by forcing `scene_cube`
  active and watching it live in DOSBox: the cube rendered one wrong, static
  frame (with a stray out-of-bounds edge) and never animated again, because
  `main:`/`present:` never got back around to `inc bp`. Root cause: the
  Bresenham step must compute `e2 = 2*err` **once** and reuse it for both the
  x-step and y-step conditions; this instead recomputed `e2` from `[line_err]`
  a second time, after the x-step may have already mutated it, which could
  stop the walk from ever landing exactly on the target pixel — the only
  condition the loop checks to terminate. Fixed by computing `e2` once into a
  register and reusing it for both comparisons. Confirmed live in DOSBox: the
  cube now rotates continuously and the starfield animates correctly.
- **Project renamed UBER40K**, with real OPL2 FM music replacing the PC
  speaker (see "Music" above), and the single-cube renderer generalized into
  `render_object`, a reusable wireframe-object engine now driving two
  independently-rotating shapes (cube + octahedron) in scene 16 instead of
  one hardcoded object. Verified live in DOSBox with a forced-scene debug
  build: both objects render and rotate correctly and independently.
- **Music expanded from one monophonic channel to three simultaneous FM
  voices (lead/bass/pad) plus the OPL2's built-in rhythm section** (see
  "Music" above). Generalized `opl_note_on`/`opl_note_off` to take a
  channel number, and added `opl_set_instrument` so new voices are just a
  patch + step table, not new driver code. Verified: all three audit
  scripts pass, a 15s headless run completes with no crash, and a live
  DOSBox run confirmed the rest of the demo (rendering, both 3D objects,
  scroller) is unaffected by the heavier register/channel usage.
- **Second audit pass: the music was broken in ways nothing could see.** Behavioural
  testing (above) found two real bugs in the multi-voice music I had just written and
  described as working — my earlier checks were audits, screenshots and no-crash runs,
  none of which can observe sound:
  - **The drums never fired.** `drum_tick` loaded the baseline into `AL`
    (`mov al,[opl_bd_base]`) and then did `cmp ax,0`, so `AX` was `0020h` and neither
    drum branch could ever match: 0 kick and 0 snare hits. Fixed by keeping the step
    position in `BX`; the static lint now flags this exact pattern (and was checked
    against the buggy commit to prove it would have caught it).
  - **Exit left the chip ringing.** `exit:` called `opl_note_off` with an undefined
    `CL`, silencing an arbitrary channel; the pad was still keyed on after return to
    DOS (and on real hardware would have droned indefinitely). Fixed with
    `opl_silence`.
  - The echo voice added in the same pass initially replayed a note the lead had
    never played (the tick runs after `inc bp`, so lead step 0 is skipped once); the
    test caught it and echoing now starts at frame 24.
  - Expanded in the same pass: a fourth voice (echo), hi-hat on the off-beats, and a
    pad that re-keys on each chord change. The intro (`UBER256.COM`), which had never
    had any behavioural test, is now covered too.
