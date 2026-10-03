# Low-level notes

## DOS COM execution

DOS loads a COM image at offset `0100h` of its program segment. `CS`, `DS`, `ES`, and `SS` initially describe the program's PSP environment, but this demo explicitly installs `ES=A000h` before framebuffer stores. `ORG 100h` tells NASM to calculate labels for that load convention; it does not emit a header.

## VGA framebuffer

Mode 13h is packed-pixel VGA: 320*200 = 64,000 byte pixels. `ES:DI` is therefore a natural streaming destination. `STOSB` writes AL to `ES:[DI]` and advances DI when the direction flag is clear. DOS normally enters applications with DF clear; production code that must tolerate arbitrary callers can issue `CLD`, at a one-byte size cost.

## Palette DAC

Writing zero to `3C8h` selects DAC entry zero. Subsequent writes to `3C9h` are consumed as R,G,B triplets and automatically advance the palette index. The generated palette intentionally uses modular six-bit ramps rather than storing 768 bytes of palette data.

## Retrace

Input Status Register 1 is available at `3DAh`; bit 3 reflects vertical retrace. The showcase first waits until outside retrace and then until retrace begins. This gives one unambiguous edge per rendered frame. It is synchronization, not a guarantee that rendering itself fits one refresh interval.

## Sizecoding trade-offs

A 256-byte intro optimizes encoded bytes rather than conventional software structure. Registers carry several meanings over their lifetime; arithmetic overflow is useful; tables and abstractions are expensive; direct hardware access replaces APIs. Such code is intentionally unlike maintainable application code.

## CPU baseline

The sources declare a 386+ target because the compact arithmetic uses later x86 instruction forms. They remain 16-bit real-mode programs; 386+ refers to the instruction set, not 32-bit protected mode.


## Frame presentation accuracy

`wait_vsync` waits for the beginning of vertical retrace before `present:` flips the CRTC start-address register to show the page that was just rendered. This is true hardware page flipping — no software backbuffer copy, no tearing. The CRTC update lands inside vertical blank, so the display switches pages at the moment the monitor is already in the non-visible region.

Scene changes use a palette-domain fade envelope. The renderer therefore pays no second full-frame blend pass: DAC output is clamped toward black for 32 frames before/after each 512-frame boundary while the procedural effect clock remains continuous.


## Register-lifetime audit

Rendering loads ES with the current hidden VGA page segment (A000h or B000h) once at frame start. Individual effects may freely reuse AX/BX/CX/DX/SI because STOSB addresses ES:DI; BX is not a persistent framebuffer pointer. Every full-screen scene uses a 320 x 200 loop and emits exactly 64,000 STOSB writes before overlays; scene_cube and scene_starfield clear the page with `rep stosw` and draw 3D objects instead.

## Presentation choreography

Version 5.0 combines two transition mechanisms. `palette_tick` performs the inexpensive DAC-domain fade, while `transition_wipe` covers symmetric top/bottom scanline regions during the first and last 16 frames of each 512-frame scene. `scene_marker` renders eighteen tiny progress blocks directly into the hidden page. `scroll_draw` runs last of the overlays, after `transition_wipe`, so the bottom scroller is never covered by the scene-cut shutter bars. All four overlays execute after the scene renderer and before the retrace/presentation path, so they cannot leave stale pixels between scenes.

## Perspective projection (scene_cube)

Unlike the field scenes, `scene_cube` needs genuine 3D math. Two rotations (Y axis,
then X axis) are applied per vertex using one shared 256-entry sine table; cosine
is read from the same table at a 64-step (quarter-turn) offset rather than keeping
a second table. Each rotation stage is a standard 2D rotation matrix in fixed point:
multiply by the sine/cosine byte (range -63..63), sum, then `SAR` by 6 to undo the
implicit x64 scale. Products stay well within a signed 16-bit range throughout,
since a rotation can't increase a vector's magnitude beyond its original length.

Projection is a true perspective divide, not orthographic: `screen = centre +
(rotated * SCALE) / (depth + EYE_DIST)`, using `CWD`/`IDIV` for the signed 16-bit
division. `EYE_DIST=160` keeps the divisor comfortably positive (vertices stay
within roughly +-70 along any axis after rotation, so depth+160 never approaches
zero) regardless of the current rotation angle. Each vertex's post-rotation depth
is also cached (`proj_z`) so each of the 12 edges can pick a bright-vs-dim colour
from the average depth of its two endpoints, giving simple depth cueing without
implementing real hidden-line removal.

Edges are drawn with a from-scratch Bresenham line routine (the `dx+dy` err-term
variant), operating entirely through memory-resident state rather than registers,
since the routine has more live values (current x/y, both deltas, both step
signs, the error term) than the six general-purpose 16-bit registers can hold at
once without juggling. It bounds-checks every pixel before plotting, so an
out-of-range projected point can never corrupt memory outside the backbuffer --
a deliberate defensive measure after the `scene_feedback` backbuffer-overrun bug
found during this project's audit.

## Reserved DAC indices

`palette_tick`'s main loop animates all 256 DAC entries from one continuous
formula every frame, which looks good for the procedural fields but gives no
index a guaranteed-stable colour. Indices 1-7 are overridden immediately after
that loop runs, every frame, to fixed values: 1=black, 2=white, 3=dim grey, and
4-7 a small fixed rainbow. The text scroller and scene_cube's wireframe use only
these reserved indices, so they stay legible regardless of what the animated
palette is doing elsewhere. This was added after visually confirming in DOSBox
that the scroller/cube, when using plain animated indices, could lose contrast
whenever the animation happened to converge those indices to similar tones.
