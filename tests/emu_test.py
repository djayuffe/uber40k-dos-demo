#!/usr/bin/env python3
"""Behavioural tests: run the real .COM binaries in an emulated 16-bit CPU
(Unicorn) and observe what they do to the hardware.

The static audits only grep source text and screenshots can't see sound, so a
drum pattern that never fires, or a chip left ringing after exit, passes every
other check. This traps port I/O and DOS/BIOS interrupts, can call individual
routines in isolation, builds variants of the program (forced scene, faster
scene clock), and snapshots the displayed page.

    python3 -m venv .venv && .venv/bin/pip install unicorn
    .venv/bin/python tests/emu_test.py                 # everything
    .venv/bin/python tests/emu_test.py music|gfx|math|scenes|exit|intro
"""
import sys, re, math, pathlib, subprocess, tempfile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN, UC_HOOK_INTR, UC_HOOK_MEM_UNMAPPED
from unicorn.x86_const import *

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEG = 0x1000
LIN = SEG << 4
fails = []

def check(cond, msg):
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        fails.append(msg)

# ---------------------------------------------------------------- building
def assemble(replacements=(), tag="v"):
    """Assemble showcase.asm with text replacements; returns (com path, listing text)."""
    d = pathlib.Path(tempfile.mkdtemp(prefix=f"u40k_{tag}_"))
    src = (ROOT / "showcase.asm").read_text()
    for old, new in replacements:
        assert old in src, f"pattern not found: {old!r}"
        src = src.replace(old, new, 1)
    (d / "v.asm").write_text(src)
    subprocess.run(["nasm", "-f", "bin", "-Wall", "-Werror", "-l", str(d / "v.lst"),
                    str(d / "v.asm"), "-o", str(d / "v.com")], check=True)
    return d / "v.com", (d / "v.lst").read_text()

def symbol(lst, name):
    """Offset (from the PSP, i.e. already +100h) of a label/variable in the listing.
    Data declarations carry their address on the same line; a bare code label
    (`name:`) has none, so its address is that of the next listed instruction."""
    lines = lst.split("\n")
    pat = re.compile(rf"^\s*\d+\s+(?:([0-9A-Fa-f]{{8}})\s+(?:[0-9A-Fa-f]+(?:<rep [0-9A-Fa-f]+h>)?\s+)?)?{re.escape(name)}(?::|\s|$)")
    addr = re.compile(r"^\s*\d+\s+([0-9A-Fa-f]{8})\s")
    for i, l in enumerate(lines):
        m = pat.match(l)
        if not m:
            continue
        if m.group(1):
            return 0x100 + int(m.group(1), 16)
        for l2 in lines[i + 1:]:
            m2 = addr.match(l2)
            if m2:
                return 0x100 + int(m2.group(1), 16)
    raise AssertionError(f"symbol {name} not found in listing")

def force_scene(n):
    return [("    mov [cur_scene],dl\n    mov al,dl\n", f"    mov byte [cur_scene],{n}\n    mov al,{n}\n")]

# ----------------------------------------------------------------- machine
class Machine:
    def __init__(self, com, esc_frame=10**9, frames_by_poll=False):
        self.opl, self.opl_log = {}, []
        self.opl_index = self.crtc_index = 0
        self.flips = self.vsync_reads = 0
        self.esc_frame, self.frames_by_poll = esc_frame, frames_by_poll
        self.irq_writes, self.modes, self.sp_at_frame = [], [], []
        self.dac, self.dac_idx, self.dac_sub, self.dac_cur = {}, 0, 0, [0, 0, 0]
        self.dac_at = {}               # frame -> (bp the palette was computed from, DAC copy)
        self.start_hi = 0
        self.unmapped, self.exited, self.resized = [], False, False
        self.flip_hooks = []           # callables(machine, page_linear_base, frame)
        self.out_hooks = []            # callables(machine, port, value), after the OUT is processed
        com = pathlib.Path(com) if pathlib.Path(com).is_absolute() else ROOT / com
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0x10000)
        uc.mem_map(LIN, 0x10000)
        uc.mem_map(0xA0000, 0x20000)                 # VGA A000h + B000h pages
        uc.mem_write(LIN + 0x100, com.read_bytes())
        uc.mem_write(LIN, b"\xCD\x20")               # PSP: INT 20h (what 'ret' to 0 reaches)
        for r in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS):
            uc.reg_write(r, SEG)
        uc.reg_write(UC_X86_REG_SP, 0xFFFE)          # DOS leaves a 0 word here
        uc.reg_write(UC_X86_REG_FLAGS, 0x202)
        uc.hook_add(UC_HOOK_INSN, self.on_in, None, 1, 0, UC_X86_INS_IN)
        uc.hook_add(UC_HOOK_INSN, self.on_out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_INTR, self.on_intr)
        uc.hook_add(UC_HOOK_MEM_UNMAPPED,
                    lambda u, a, ad, sz, v, d: self.unmapped.append((hex(ad), sz)) or False)

    def esc(self):
        return self.flips >= self.esc_frame

    def on_in(self, uc, port, size, ud):
        if port == 0x3DA:
            self.vsync_reads += 1
            return 8 if (self.vsync_reads // 2) % 2 else 0
        if port == 0x64 and self.frames_by_poll:
            self.flips += 1
        if port in (0x64, 0x60):
            return 1 if self.esc() else 0
        return 0

    def on_out(self, uc, port, size, value, ud):
        value &= 0xFF
        if port == 0x388: self.opl_index = value
        elif port == 0x389:
            self.opl[self.opl_index] = value
            self.opl_log.append((self.flips, self.opl_index, value))
        elif port == 0x3C8: self.dac_idx, self.dac_sub = value, 0
        elif port == 0x3C9:
            self.dac_cur[self.dac_sub] = value; self.dac_sub += 1
            if self.dac_sub == 3:
                self.dac[self.dac_idx] = tuple(self.dac_cur)
                self.dac_idx, self.dac_sub = (self.dac_idx + 1) & 255, 0
        elif port == 0x3D4: self.crtc_index = value
        elif port == 0x3D5 and self.crtc_index == 0x0C: self.start_hi = value
        elif port == 0x3D5 and self.crtc_index == 0x0D:
            # palette written since the previous flip was computed from bp-1
            # (palette_tick runs before inc bp)
            self.dac_at[self.flips] = (uc.reg_read(UC_X86_REG_BP) - 1, dict(self.dac))
            frame = self.flips
            self.flips += 1
            self.sp_at_frame.append(uc.reg_read(UC_X86_REG_SP))
            page = 0xB0000 if self.start_hi == 0x40 else 0xA0000     # page just rendered
            for h in self.flip_hooks:
                h(self, page, frame)
        elif port == 0x21: self.irq_writes.append(value)
        for h in self.out_hooks:
            h(self, port, value)

    def on_intr(self, uc, intno, ud):
        ax = uc.reg_read(UC_X86_REG_AX); ah = ax >> 8
        uc.reg_write(UC_X86_REG_FLAGS, uc.reg_read(UC_X86_REG_FLAGS) & ~1)
        if intno == 0x10:
            if ah == 0x0F: uc.reg_write(UC_X86_REG_AX, 0x5003)
            else: self.modes.append(ax & 0xFF)
        elif intno == 0x21:
            if ah == 0x4A: self.resized = True
            elif ah == 0x4C: self.exited = True; uc.emu_stop()
        elif intno == 0x20:
            self.exited = True; uc.emu_stop()

    def run(self, max_frames, slice_=10_000_000, budget=8_000_000_000):
        used, started = 0, False
        while not self.exited and used < budget and self.flips < max_frames:
            ip = 0x100 if not started else self.uc.reg_read(UC_X86_REG_IP)
            started = True
            try:
                self.uc.emu_start(ip, 0xFFFF0, count=slice_)
            except Exception as e:
                print("  emulation fault:", e); break
            used += slice_
        return used

    # --- calling one routine in isolation (return address 0 -> PSP INT 20h) ---
    def call(self, addr, **regs):
        self.exited = False
        uc = self.uc
        uc.reg_write(UC_X86_REG_SP, 0xFFF0)
        uc.mem_write(LIN + 0xFFF0, b"\x00\x00")
        for k, v in regs.items():
            uc.reg_write(getattr(__import__("unicorn.x86_const", fromlist=["x"]), f"UC_X86_REG_{k.upper()}"), v)
        uc.emu_start(addr, 0xFFFF0, count=5_000_000)
        return uc

    def rd16(self, off, signed=False):
        v = int.from_bytes(self.uc.mem_read(LIN + off, 2), "little")
        return v - 65536 if signed and v >= 32768 else v

    def wr16(self, off, v):
        self.uc.mem_write(LIN + off, (v & 0xFFFF).to_bytes(2, "little"))

# ---------------------------------------------------------------- music theory
NOTE = "C C# D D# E F F# G G# A A# B".split()
def opl_pitch(fnum, block):
    return fnum * 49716 / 2 ** (20 - block)
def pitch_class(hz):
    midi = 69 + 12 * math.log2(hz / 440.0)
    return NOTE[round(midi) % 12], abs(midi - round(midi)) * 100        # name, cents off

def decode_notes(log, ch):
    """[(frame, pitch class, cents off, hz)] for every key-on on a channel."""
    out, a = [], None
    for f, r, v in log:
        if r == 0xA0 + ch: a = v
        elif r == 0xB0 + ch and v & 0x20 and a is not None:
            hz = opl_pitch(a | ((v & 3) << 8), (v >> 2) & 7)
            name, cents = pitch_class(hz)
            out.append((f, name, cents, hz))
    return out

PENT = {"A", "C", "D", "E", "G"}
BARS = [("Am", {"A", "C", "E"}), ("C", {"C", "E", "G"}), ("G", {"G", "D", "E"}), ("Em", {"E", "G"})]
ROOTS = ["A", "C", "G", "E"]

def test_music(frames=1100):
    print(f"\n== music: 4-bar form, voices, drums ({frames} frames, forced cheap scene) ==")
    com, lst = assemble(force_scene(16), "music")
    m = Machine(com, frames)
    m.run(frames + 60)
    print(f"  {m.flips} frames")
    log, opl = m.opl_log, m.opl

    for ch, (a, b) in {0: (0, 3), 1: (1, 4), 2: (2, 5), 3: (8, 11), 6: (16, 19), 7: (17, 20), 8: (18, 21)}.items():
        check(all((0x20 + o) in opl for o in (a, b)) and (0xC0 + ch) in opl, f"channel {ch} instrument programmed")
    check(all(not (opl[0xC0 + c] & 1) for c in (0, 1, 2, 3)),
          "melodic voices use true FM (connection bit 0), not additive")

    voices = {c: decode_notes(log, c) for c in (0, 1, 2, 3)}
    for c, nm in ((0, "lead"), (1, "bass"), (2, "pad"), (3, "echo")):
        check(voices[c], f"{nm} plays ({len(voices[c])} notes)")
    allnotes = [n for c in voices for n in voices[c]]
    check(max(n[2] for n in allnotes) < 15, f"every note in tune (worst {max(n[2] for n in allnotes):.1f} cents)")

    bar_of = lambda f: (f >> 8) & 3
    lead = voices[0]
    check({n[1] for n in lead} <= PENT, f"lead stays in A minor pentatonic ({sorted({n[1] for n in lead})})")
    check({n[1] for n in voices[3]} <= PENT, "echo stays in A minor pentatonic")
    for bar, (cname, _) in enumerate(BARS):
        n = [x for x in lead if bar_of(x[0]) == bar and x[0] < 1024]
        check(18 <= len(n) <= 28, f"bar {bar+1} ({cname}) lead has a sensible density ({len(n)} notes)")
    bass_ok = all(n[1] == ROOTS[bar_of(n[0])] for n in voices[1])
    check(bass_ok, f"bass plays only the chord root ({'-'.join(ROOTS)} per bar), octave aside")
    pad_ok = all(n[1] in BARS[bar_of(n[0])][1] for n in voices[2])
    check(pad_ok, "pad only plays tones of the current chord (Am C G Em)")
    # four DIFFERENT phrases, repeating exactly after 4 bars
    seq = lambda lo, hi: [(n[0] - lo, n[1]) for n in lead if lo <= n[0] < hi]
    bars = [seq(b * 256, b * 256 + 256) for b in range(4)]
    check(len({tuple(b) for b in bars}) == 4, "the four bars have four different lead phrases (no 3.7 s loop)")
    first = [(n[0] - 8, n[1]) for n in lead if 8 <= n[0] < 72]
    again = [(n[0] - 1032, n[1]) for n in lead if 1032 <= n[0] < 1096]
    check(len(first) > 5 and first == again, f"the form repeats exactly after 4 bars (first {len(first)} lead notes of pass 2 match pass 1)")

    # timing
    check(all(f % 8 == 0 for n in lead + voices[1] + voices[3] for f in [n[0]]), "lead/bass/echo retrigger only on step boundaries")
    check(all(f % 64 == 0 for f in [n[0] for n in voices[2]]), "pad changes every 8 steps")
    lead_f = [n for n in lead if n[0] + 16 <= frames]
    echo_by_f = {n[0]: n for n in voices[3]}
    check(all(n[0] + 16 in echo_by_f and echo_by_f[n[0] + 16][1] == n[1] and abs(echo_by_f[n[0] + 16][3] - n[3]) < 1
              for n in lead_f), f"every echo is the lead's note 2 steps earlier ({len(lead_f)} checked)")
    check(not [n for n in voices[3] if n[0] < 24], "no echo before the lead has played it")

    # drums
    def hits(bit): return sorted(f for f, r, v in log if r == 0xBD and v & bit)
    kick, snare, hat, tom, crash = hits(0x10), hits(0x08), hits(0x01), hits(0x04), hits(0x02)
    pos = lambda f: (f // 8) % 8
    inbar = lambda f: (f // 8) % 32
    check(all(f % 8 == 0 and pos(f) == 0 for f in kick) and len(kick) >= frames // 64 - 1,
          f"kick on every downbeat ({len(kick)} hits)")
    snare_ok = all(pos(f) == 4 or (bar_of(f) == 3 and inbar(f) >= 24) for f in snare)
    check(snare and snare_ok, f"snare on the backbeat, plus the bar-4 fill ({len(snare)} hits)")
    check(hat and all(pos(f) in (2, 6) for f in hat), f"hi-hat only on the off-beats ({len(hat)} hits)")
    check(tom and all(bar_of(f) == 3 and inbar(f) >= 24 for f in tom), f"toms only in the bar-4 fill ({len(tom)} hits)")
    check(crash and all(f % 1024 == 0 for f in crash), f"cymbal only at the top of the form (frames {crash})")

    # clean exit
    check(m.exited, "terminated via INT 21h/4Ch after Esc")
    check(all(not (opl.get(0xB0 + c, 0) & 0x20) for c in range(9)),
          f"all 9 channels keyed off at exit (B0..B8={[hex(opl.get(0xB0+c,0)) for c in range(9)]})")
    check(opl.get(0xBD, 0) == 0, f"rhythm register cleared at exit (0xBD={hex(opl.get(0xBD,0))})")

# ----------------------------------------------------------------- graphics
def page_bytes(m, base): return bytes(m.uc.mem_read(base, 64000))

def test_gfx():
    print("\n== graphics: solid 3D, culling, sky, smooth rotation (forced cube scene) ==")
    com, lst = assemble(force_scene(15), "gfx")
    m = Machine(com, 530)
    snaps, angles = {}, []
    ay, ax_ = symbol(lst, "cube_angle_y"), symbol(lst, "cube_angle_x")
    WANT = {8: "wipe", 200: "solid", 300: "solid", 440: "wire", 480: "wire"}     # bp&180h == 180h -> wireframe
    def hook(mm, page, f):
        angles.append((f, mm.rd16(ay), mm.rd16(ax_)))
        if f in WANT: snaps[f] = page_bytes(mm, page)
    m.flip_hooks.append(hook)
    m.run(540)
    print(f"  {m.flips} frames")
    check(not m.unmapped, f"no access outside mapped memory {m.unmapped[:3]}")
    ramp = lambda b: sum(1 for x in b[:170 * 320] if 8 <= x <= 23)
    check(snaps[8][300] == 1 and snaps[8][199 * 320 + 300] == 1,
          "scene-start shutter bars are fixed black (DAC 1), not an animated palette colour")
    for f, kind in WANT.items():
        if kind == "wipe": continue
        r = ramp(snaps[f])
        if kind == "solid": check(r > 3000, f"frame {f}: solid faces drawn ({r} shaded pixels)")
        else:               check(r == 0, f"frame {f}: wireframe mode draws no filled faces ({r} shaded pixels)")
    wire_px = sum(1 for x in snaps[440][:170 * 320] if x in (2, 3))
    check(wire_px > 150, f"wireframe frame has white/grey edges ({wire_px} px)")
    shades = {x for x in snaps[200][:170 * 320] if 8 <= x <= 23}
    check(len(shades) >= 3, f"faces are lit differently, not one flat colour ({len(shades)} distinct shades)")
    # sky: a clean column well away from the objects/stars; must be a monotone 24..39 gradient
    col = [snaps[200][y * 320 + 2] for y in range(170)]
    col = [v for v in col if 24 <= v <= 39]                  # raster bars cross this column; skip them
    check(len(col) > 150 and col[0] == 24 and all(b >= a for a, b in zip(col, col[1:])) and col[-1] >= 36,
          f"sky is a smooth top-to-bottom gradient (index {col[0]} -> {col[-1]}, {len(col)} sky rows)")
    # culling: a solid cube shows 1-3 faces and the octahedron 1-4 (never all of them)
    # -> total filled area must stay well below the convex-hull of all faces
    check(ramp(snaps[200]) < 14000, f"back faces are culled (filled area {ramp(snaps[200])} px, not whole-solid)")
    # smooth rotation: both angles advance by a constant step EVERY frame
    d_y = {(b[1] - a[1]) & 0xFFFF for a, b in zip(angles[2:], angles[3:])}
    d_x = {(b[2] - a[2]) & 0xFFFF for a, b in zip(angles[2:], angles[3:])}
    check(d_y == {64} and d_x == {128}, f"rotation advances by a constant step every frame (dY={d_y}, dX={d_x})")

def test_math():
    print("\n== math: sine interpolation + polygon rasteriser, in isolation ==")
    com, lst = assemble(force_scene(15), "math")
    m = Machine(com)
    sc = symbol(lst, "sincos16")
    worst, prev, jump = 0, None, 0
    for a in range(0, 65536, 97):
        uc = m.call(sc, ax=a)
        s = uc.reg_read(UC_X86_REG_AX); c = uc.reg_read(UC_X86_REG_DX)
        s = s - 65536 if s >= 32768 else s; c = c - 65536 if c >= 32768 else c
        ex_s, ex_c = 127 * math.sin(2 * math.pi * a / 65536), 127 * math.cos(2 * math.pi * a / 65536)
        worst = max(worst, abs(s - ex_s), abs(c - ex_c))
        if prev is not None: jump = max(jump, abs(s - prev))
        prev = s
    check(worst <= 1.1, f"sin/cos match math.sin/cos within {worst:.2f} (x127 scale) over the full circle")
    # the 255 -> 0 table wrap: angles just either side of a full turn
    pts = []
    for a in (65536 - 300, 65536 - 1, 0, 1, 300):
        uc = m.call(sc, ax=a % 65536); v = uc.reg_read(UC_X86_REG_AX); pts.append(v - 65536 if v >= 32768 else v)
    check(max(abs(b - a) for a, b in zip(pts, pts[1:])) <= 4, f"no discontinuity across the table wrap {pts}")

    # polygon fill, against geometry
    fp = symbol(lst, "fill_poly"); pvx, pvy = symbol(lst, "pv_x"), symbol(lst, "pv_y")
    pc = symbol(lst, "poly_color")
    def fill(pts, color=9):
        m.uc.mem_write(0xB0000, bytes(64000)); m.uc.mem_write(0xB0000 + 64000, bytes(1536))
        for i, (x, y) in enumerate(pts): m.wr16(pvx + 2 * i, x); m.wr16(pvy + 2 * i, y)
        m.uc.mem_write(LIN + pc, bytes([color]))
        m.uc.reg_write(UC_X86_REG_ES, 0xB000)
        m.call(fp)
        mem = bytes(m.uc.mem_read(0xB0000, 64000 + 1536))
        return sum(1 for x in mem[:64000] if x == color), mem[64000:] == bytes(1536)
    n, clean = fill([(10, 10), (110, 10), (10, 110), (10, 110)])
    check(n == 5151 and clean, f"triangle (10,10)-(110,10)-(10,110) fills exactly 5151 px (inclusive pixel count) - got {n}")
    n, clean = fill([(100, 40), (200, 40), (200, 120), (100, 120)])
    check(n == 101 * 81 and clean, f"rectangle (100,40)-(200,120) fills exactly 101x81 = 8181 px - got {n}")
    n, clean = fill([(-50, -50), (400, -50), (400, 300), (-50, 300)])
    check(n == 64000 and clean, f"polygon covering the whole screen fills exactly 64000 px and nothing beyond ({n})")
    n, clean = fill([(-300, 20), (-100, 20), (-100, 90), (-300, 90)])
    check(n == 0 and clean, "polygon entirely off-screen draws nothing")
    n, clean = fill([(300, 150), (500, 160), (480, 400), (310, 380)])
    check(0 < n < 64000 and clean, f"polygon partly off the right/bottom edge is clipped, no overrun ({n} px)")
    n, clean = fill([(50, 50), (50, 50), (50, 50), (50, 50)])
    check(clean, f"degenerate (zero-area) polygon is harmless ({n} px)")

def test_palette():
    print("\n== palette: fixed colours, scene fade preserves hue ==")
    com, lst = assemble(force_scene(15), "pal")
    m = Machine(com, 80); m.run(90)
    base = {39: (20, 8, 28), 24: (0, 0, 4), 23: (63, 63, 63), 8: (7, 9, 24), 41: (63, 60, 48)}
    ok, bad = True, []
    for f in range(2, 36):
        bp, d = m.dac_at[f]
        lim = min(63, 2 * (bp & 511)) if (bp & 511) < 32 else 63
        for i, (r, g, b) in base.items():
            want = tuple(v * (lim + 1) // 64 for v in (r, g, b))
            if d.get(i) != want: bad.append((f, i, d.get(i), want))
    check(not bad, f"scene art fades by SCALING (v*(limit+1)/64) at every frame of the fade-in {bad[:2]}")
    check(all(m.dac_at[f][1].get(2) == (63, 63, 63) and m.dac_at[f][1].get(4) == (63, 0, 0) for f in range(2, 36)),
          "UI colours (white, scroller rainbow) stay at full brightness through the fade")
    d = m.dac_at[60][1]
    check(d[8] == (7, 9, 24) and d[23] == (63, 63, 63) and d[39] == (20, 8, 28), "shading ramp and sky end-points correct at full brightness")

# ------------------------------------------------------------ other programs
def test_scenes():
    print("\n== all 18 scenes + all 3 acts (SCENE_SHIFT=2 variant) ==")
    com, lst = assemble([("%define SCENE_SHIFT 9", "%define SCENE_SHIFT 2")], "scenes")
    cs = LIN + symbol(lst, "cur_scene")
    m = Machine(com, 150)
    seen, overruns, acts = set(), [], set()
    def on_out(mm, port, value):
        if port == 0x389 and 0xB0 <= mm.opl_index <= 0xB3 and (value & 0x20):
            acts.add(mm.uc.mem_read(cs, 1)[0] >> 3)        # act this note was played in
    m.out_hooks.append(on_out)
    def hook(mm, page, f):
        seen.add(mm.uc.mem_read(cs, 1)[0])
        if any(mm.uc.mem_read(page + 64000, 1536)): overruns.append((f, hex(page)))
    m.flip_hooks.append(hook)
    m.run(170, budget=4_000_000_000)
    print(f"  {m.flips} frames; scenes seen: {sorted(seen)}")
    check(not m.unmapped, f"no access outside mapped memory {m.unmapped[:3]}")
    check(seen == set(range(18)), f"all 18 scenes executed (missing {sorted(set(range(18)) - seen)})")
    check(not overruns, f"no scene writes past the 64,000-byte page {overruns[:3]}")
    check(len(set(m.sp_at_frame)) == 1, f"stack balanced through every scene (SPs {sorted(set(map(hex, m.sp_at_frame)))})")
    check(m.exited, "still exits cleanly on Esc after cycling every scene")
    bad, la = [], {}
    for f, r, v in m.opl_log:
        if 0xA0 <= r <= 0xA3: la[r - 0xA0] = v
        if 0xB0 <= r <= 0xB3 and v & 0x20:
            hz = opl_pitch(la.get(r - 0xB0, 0) | ((v & 3) << 8), (v >> 2) & 7)
            if not 30 < hz < 4200: bad.append((r - 0xB0, round(hz)))
    check(not bad, f"every note within 30..4200 Hz across all acts {bad[:3]}")
    check(acts == {0, 1, 2}, f"the melodic voices actually played in all 3 acts (observed {sorted(acts)})")

def test_exit_and_pacing():
    print("\n== frame loop: flip ordering, exit ==")
    com, lst = assemble([], "exit")
    m = Machine(com, 90); m.run(100)
    check(m.exited and len(set(m.sp_at_frame)) == 1, "exits and keeps the stack balanced")
    check(len(m.irq_writes) >= 2 and (m.irq_writes[0] & 2) and not (m.irq_writes[-1] & 2),
          "IRQ1 masked while running, unmasked again at exit")
    src = (ROOT / "showcase.asm").read_text()
    blk = src[src.index("\npresent:\n"):src.index("    inc bp\n    call music_tick")]
    check(blk.index("out dx,al") < blk.index("call wait_vsync") < blk.index("call palette_tick"),
          "present: writes the CRTC start address BEFORE waiting for retrace (correct however the CRTC latches), palette after")

def test_intro(frames=40):
    print(f"\n== UBER256.COM ({frames} frames, Esc pressed after) ==")
    m = Machine("UBER256.COM", frames, frames_by_poll=True)
    m.run(frames + 5, slice_=5_000_000, budget=3_000_000_000)
    print(f"  {m.flips} frames rendered")
    check(not m.unmapped, f"no access outside mapped memory {m.unmapped[:3]}")
    check(0x13 in m.modes and 3 in m.modes, "enters mode 13h and restores text mode 3")
    check(m.exited, "terminates (returns to PSP INT 20h) after Esc")
    check(len(m.irq_writes) >= 2 and (m.irq_writes[0] & 2) and not (m.irq_writes[-1] & 2),
          "IRQ1 masked while running, unmasked again at exit")
    check(m.uc.reg_read(UC_X86_REG_SP) == 0, "stack balanced: final RET popped exactly the DOS return word")

TESTS = {"math": test_math, "palette": test_palette, "gfx": test_gfx, "music": test_music,
         "exit": test_exit_and_pacing, "scenes": test_scenes, "intro": test_intro}

if __name__ == "__main__":
    which = sys.argv[1:] or list(TESTS)
    for w in which:
        TESTS[w]()
    print("\nRESULT:", "ALL PASS" if not fails else f"{len(fails)} FAILED:\n  - " + "\n  - ".join(fails))
    sys.exit(1 if fails else 0)
