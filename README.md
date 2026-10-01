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
| `intro256.asm` | strict ≤256-byte sizecoded intro | 70 bytes | 386+ | VGA mode 13h | PC speaker (ESC detect only) |
| `showcase.asm` | full multi-scene production demo | ~4.8 KB | 386+ | VGA mode 13h | OPL2 FM (Sound Blaster/AdLib) |

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

### 3D engine: cube + octahedron (scene 16)

The one non-procedural-field scene is driven by a genuine, reusable 3D engine rather
than one hardcoded shape. `render_object` takes a vertex list, an edge list and a
screen-space offset, and does the rest: two-axis rotation (Y then X) using a shared
256-entry sine table (`cos(a) = sin(a+64)`, a quarter-turn lookup, so one table serves
both), a **true perspective projection** (divide by distance from the eye, not
orthographic — nearer faces are visibly larger), and a from-scratch bounds-checked
Bresenham line routine for every edge. Edges are depth-cued: the nearer ones per
object render bright white, the farther ones dim grey.

The scene calls `render_object` twice with different data and different rotation
rates — a cube and an octahedron, spinning independently and offset to opposite
sides of the screen — to actually demonstrate it's an engine and not just "the cube
scene with extra steps". Adding a third shape is a vertex/edge table and four more
lines of calling code, not a new renderer. All of it — rotation, projection, line
draw — is 16-bit fixed-point integer math; no FPU, no floating point.

### 3D starfield (scene 17)

A field of 32 stars, each with a genuine Z depth streaming toward the viewer and
perspective-projected exactly like the cube's vertices (divide by distance, not
orthographic). Every star's position is computed fresh each frame purely as a
function of the frame clock and its own index — no persistent per-star state to
track: Z counts down from far to near and wraps back to far on its own, so stars
continuously fly past and recycle forever without ever needing to be "respawned"
by special-case code. Closer stars render bright white, farther ones dim grey,
the same depth-cueing idea as the cube's edges.

### Sine-wave text scroller

A from-scratch 5×7 bitmap font (33 glyphs: the letters/digits/punctuation the
scroller message actually uses) rendered column-by-column along the bottom 8
scanlines, with each column's vertical position offset by the same sine table the
cube uses, for the classic wavy-scroller look. The foreground colour cycles through
a small fixed rainbow (red/yellow/green/cyan) both along the message and over time,
so it doesn't just sit as flat white. Two DAC indices are reserved as fixed pure
black/white (and four more for the rainbow) so the scroller and cube stay legible
regardless of what the main per-scene palette animation is doing elsewhere — see
"Fixed vs. animated palette" below.

### Music: OPL2 FM (Sound Blaster / AdLib)

`UBERSHOW.COM` drives the OPL2 FM synthesiser chip directly at its fixed I/O port
(`388h`/`389h`) — the same chip every Sound Blaster card carries for AdLib
compatibility, so no `BLASTER` environment-variable base-port detection is needed at
all; this works identically on any SB card and on a plain AdLib. It uses the chip
about as fully as a sizecoded driver reasonably can: three independent melodic
voices plus the chip's built-in rhythm section, not one monophonic beep.

**Three simultaneous FM voices**, each with its own instrument patch and its own
step sequencer, all still perfectly phase-locked to the single global frame counter:
- **Lead** (channel 0) — the original 32-step A-minor-pentatonic call-and-response
  phrase: a clean two-operator FM voice, fast attack, moderate decay.
- **Bass** (channel 1) — a sparse low-register pattern (mostly rests, roots landing
  on the beat) with a punchier, more harmonically rich patch (full modulator depth,
  a half-sine carrier for extra bite), outlining the harmony under the lead.
- **Pad** (channel 2) — a slow sustained chord tone (true-sustain envelope, soft
  volume) that only changes every 128 frames, cycling through A-minor triad tones
  for a gentle harmonic bed under the other two voices.

`opl_set_instrument` is a generic routine — channel number plus an 11-byte patch
(operator characteristics, levels, envelopes, waveforms, feedback/connection) — so
adding a fourth voice is a new patch and a new step table, not new driver code; the
channel-to-operator register mapping (`chan_op1`/`chan_op2`) is the standard OPL2
layout, so it works for any of the chip's 9 channels. `opl_note_on`/`opl_note_off`
take the channel number the same way.

**Rhythm section**: `drum_tick` drives the OPL2's built-in percussion mode (register
`0xBDh`, which repurposes channels 6-7's operators as dedicated drum voices) for a
simple kick-and-snare pattern — bass drum on the downbeat of every 8-step group,
snare on the backbeat — locked to the same step grid as the lead.

All three melodic voices transpose across the show's three acts by **adding 0x400
to the packed note value per step** — block occupies bits 10-12 of that value, so
this is always exactly one octave up regardless of the starting note, the same
"transpose by a real musical interval, not an arbitrary offset" idea the earlier
PC-speaker version used with PIT-divisor halving. Real rests (not a continuous
drone) and a short silence before each retrigger give the lead and bass clean note
attacks; the pad, being a sustained drone, retriggers legato instead.

`intro256.asm` still only uses the PC speaker, and only as a side effect of reading
the keyboard controller for Esc — it has no music of its own, deliberately: a
256-byte sizecoded intro has no room for an FM driver and a note sequencer.

### Fixed vs. animated palette

`palette_tick` drives one continuous animated formula across all 256 DAC entries
every frame — which looks great for the procedural fields, but means no single
index is guaranteed to stay a consistent colour from frame to frame. The scroller
and cube need reliable contrast, so DAC indices **1–7 are reserved** immediately
after the main animated loop runs each frame, overriding whatever it assigned them:
1=black, 2=white, 3=dim grey (cube depth cue), 4–7=a small fixed rainbow (scroller).

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

## Files

- `intro256.asm` — strict sizecoded intro source
- `showcase.asm` — full showcase source (scenes, scroller, cube, music, palette)
- `audit.py`, `audit_final.py`, `release_audit.py` — layered static source audits
- `build.sh` — reproducible NASM build, audit run, and 256-byte gate enforcement
- `run-dosbox.sh` — DOSBox launcher (showcase by default, `UBER256.COM` as `$1`)
- `DOSBOX.CONF` — DOSBox configuration (vsync-correct `cycles=max`/`core=auto`)
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
