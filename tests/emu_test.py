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
    def call(self, addr, count=5_000_000, **regs):
        self.exited = False
        uc = self.uc
        uc.reg_write(UC_X86_REG_SP, 0xFFF0)
        uc.mem_write(LIN + 0xFFF0, b"\x00\x00")
        for k, v in regs.items():
            uc.reg_write(getattr(__import__("unicorn.x86_const", fromlist=["x"]), f"UC_X86_REG_{k.upper()}"), v)
        uc.emu_start(addr, 0xFFFF0, count=count)
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
    check(all(f % 8 == 0 and (pos(f) == 0 or (bar_of(f) == 2 and inbar(f) == 14)) for f in kick)
          and len([f for f in kick if pos(f) == 0]) >= frames // 64 - 1,
          f"kick on every downbeat, plus one syncopated kick in bar 3 ({len(kick)} hits)")
    snare_ok = all(pos(f) == 4 or (bar_of(f) == 3 and inbar(f) >= 24) for f in snare)
    check(snare and snare_ok, f"snare on the backbeat, plus the bar-4 fill ({len(snare)} hits)")
    hat_ok = all(pos(f) in (2, 6) if bar_of(f) == 0 else pos(f) not in (0, 4) for f in hat)
    check(hat and hat_ok and any(pos(f) in (1, 3, 5, 7) for f in hat),
          f"hi-hat: eighths in bar 1, off-beat sixteenths added later, never on kick/snare ({len(hat)} hits)")
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
        else:               check(0 < r < 1500, f"frame {f}: wireframe mode fills only the small cores ({r} shaded pixels)")
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



def test_bounce():
    print("\n== stars bounce off the wireframe force-fields; solid cores inside ==")
    com, lst = assemble(force_scene(15), "bnc")
    m = Machine(com, 10)
    sb = symbol(lst, "star_bounce")
    sx, sy, hit = symbol(lst, "star_sx"), symbol(lst, "star_sy"), symbol(lst, "star_hit")
    def bounce(x, y, cx, r):
        m.wr16(sx, x); m.wr16(sy, y); m.uc.mem_write(LIN + hit, b"\x00")
        m.call(sb, bx=cx, dx=r)
        return m.rd16(sx, True), m.rd16(sy, True), m.uc.mem_read(LIN + hit, 1)[0]
    metric = lambda dx, dy: max(abs(dx), abs(dy)) + min(abs(dx), abs(dy)) // 2
    x, y, h = bounce(90 + 20, 100, 90, 56)
    check(h == 1 and x > 90 + 56 and y == 100, f"star 20px inside the field is mirrored to 36px outside ({x},{y})")
    x, y, h = bounce(90 + 80, 100, 90, 56)
    check(h == 0 and (x, y) == (170, 100), "star outside the field is untouched")
    ok = all(metric(bounce(90 + dx, 100 + dy, 90, 56)[0] - 90, bounce(90 + dx, 100 + dy, 90, 56)[1] - 100) >= 56
             for dx in range(-50, 51, 7) for dy in range(-50, 51, 7) if dx or dy)
    check(ok, "every deflected star lands on or outside the field boundary")
    def stars_inside(replacements):
        com2, _ = assemble(force_scene(15) + replacements, "bnc2")
        mm = Machine(com2, 515)
        seen = []
        def hook(m2, page, f):
            if 400 <= f <= 505:                      # wireframe quarter
                px = page_bytes(m2, page)
                n = 0
                for yy in range(46, 154):
                    for xx in range(36, 144):
                        if metric(xx - 90, yy - 100) < 54 and px[yy * 320 + xx] in (40, 41): n += 1
                seen.append(n)
        mm.flip_hooks.append(hook); mm.run(520)
        return sum(seen)
    on = stars_inside([])
    off = stars_inside([("    mov byte [bounce_on],1\n", "    mov byte [bounce_on],0\n")])
    check(on == 0 and off > 0, f"no star inside the cube field with bounce on ({on}); without it some are ({off})")
    # cores: a lit solid shape appears inside the wireframe cube/octahedron
    com3, _ = assemble(force_scene(15), "core")
    mm = Machine(com3, 450); core = []
    def hook3(m2, page, f):
        if f == 440:
            px = page_bytes(m2, page)
            core.append(sum(1 for yy in range(80, 120) for xx in range(70, 110) if 8 <= px[yy * 320 + xx] <= 23))
            core.append(sum(1 for yy in range(85, 115) for xx in range(215, 245) if 8 <= px[yy * 320 + xx] <= 23))
    mm.flip_hooks.append(hook3); mm.run(460)
    check(len(core) == 2 and core[0] > 150 and core[1] > 60, f"solid cores drawn inside both wireframes ({core})")

def test_fields():
    print("\n== field engine: polar maps, tables, value range, per-frame cost ==")
    import math
    com, lst = assemble([], "fld")
    m = Machine(com, 5)
    m.call(symbol(lst, "build_tabs"), count=2_000_000)
    m.call(symbol(lst, "build_maps"), count=40_000_000)
    angm, radm = 0x4000, 0x4000 + 16000
    A = bytes(m.uc.mem_read(LIN + angm, 16000)); R = bytes(m.uc.mem_read(LIN + radm, 16000))
    bad_r = bad_a = 0
    for y in range(100):
        for x in range(160):
            dx, dy = x - 80, y - 50
            want_r = int(math.sqrt(6 * (dx * dx + dy * dy)))
            if abs(R[y * 160 + x] - want_r) > 1: bad_r += 1
            if dx or dy:
                want_a = (math.atan2(dy, dx) / (2 * math.pi) * 256) % 256
                d = abs(A[y * 160 + x] - want_a); d = min(d, 256 - d)
                if d > 1.5: bad_a += 1
    check(bad_r == 0, f"radius map = sqrt(6(dx^2+dy^2)) within 1 for all 16000 blocks ({bad_r} bad)")
    check(bad_a == 0, f"angle map = atan2 within 1.5/256 turn for all blocks ({bad_a} bad)")
    s56 = bytes(m.uc.mem_read(LIN + symbol(lst, "sin56"), 256)); s165 = bytes(m.uc.mem_read(LIN + symbol(lst, "sin165"), 256))
    check(min(s56) == 0 and max(s56) == 55, f"sin56 spans 0..55 ({min(s56)}..{max(s56)})")
    check(min(s165) >= 42 and max(s165) <= 205, f"sin165 spans the animated palette 42..205 ({min(s165)}..{max(s165)})")
    # every field scene: pixels come from the animated palette range, and the frame is cheap
    from unicorn.x86_const import UC_X86_REG_IP
    worst = 0
    for scene in (0, 1, 2, 3, 5, 7, 8, 13, 14, 17):
        com2, _ = assemble(force_scene(scene), f"fs{scene}")
        mm = Machine(com2, 60); marks, st, lows = [], {"used": 0}, []
        def hook(m2, page, f, marks=marks, st=st, lows=lows):
            marks.append(st["used"])
            if f == 40:
                px = page_bytes(m2, page)
                lows.append(sum(1 for y in range(12, 170) for x in range(0, 320, 3) if px[y * 320 + x] < 42))
        mm.flip_hooks.append(hook)
        started = False
        while mm.flips < 62 and not mm.exited:
            ip = 0x100 if not started else mm.uc.reg_read(UC_X86_REG_IP); started = True
            mm.uc.emu_start(ip, 0xFFFF0, count=5000); st["used"] += 5000
        d = [b - a for a, b in zip(marks[10:], marks[11:])]
        worst = max(worst, max(d))
        check(lows and lows[0] < 0.06 * 158 * 107, f"scene {scene + 1}: field uses the animated palette range ({lows[0] if lows else '?'} stray pixels)")
    check(worst < 330_000, f"every sampled field frame costs under 330k instructions (worst {worst // 1000}k; the old fields cost 2000-3100k)")

def test_lines(n=4000):
    print(f"\n== draw_line oracle: {n} random + structured lines, in isolation ==")
    import random, re as _re
    com, lst = assemble(force_scene(15), "lines")
    m = Machine(com)
    dl = symbol(lst, "draw_line")
    X0, Y0, X1, Y1, COL = (symbol(lst, s) for s in ("line_x0", "line_y0", "line_x1", "line_y1", "line_color"))
    zero = bytes(64000 + 1536)
    rnd = random.Random(40)
    cases = [(10, 10, 10, 90), (10, 90, 10, 10), (5, 50, 300, 50), (300, 50, 5, 50), (20, 20, 120, 120),
             (120, 20, 20, 120), (20, 20, 21, 190), (20, 20, 22, 21), (0, 0, 319, 199), (319, 199, 0, 0),
             (0, 199, 319, 0), (50, 50, 50, 50), (-2000, -2000, 2200, 2000), (160, -1500, 161, 1500),
             (-1500, 100, 1800, 101), (0, 0, 1, 199), (0, 0, 319, 1)]
    cases += [(rnd.randint(-40, 360), rnd.randint(-40, 240), rnd.randint(-40, 360), rnd.randint(-40, 240)) for _ in range(n)]
    cases += [(rnd.randint(0, 319), rnd.randint(0, 199), rnd.randint(0, 319), rnd.randint(0, 199)) for _ in range(n // 2)]
    hang, bad, checked = [], [], 0
    for x0, y0, x1, y1 in cases:
        m.uc.mem_write(0xB0000, zero)
        for off, v in ((X0, x0), (Y0, y0), (X1, x1), (Y1, y1)): m.wr16(off, v)
        m.uc.mem_write(LIN + COL, b"\x07")
        m.uc.reg_write(UC_X86_REG_ES, 0xB000)
        m.uc.reg_write(UC_X86_REG_FLAGS, 0x202)             # DF clear, as DOS leaves it
        m.exited = False
        m.call(dl)
        if not m.exited:
            hang.append((x0, y0, x1, y1)); continue
        mem = bytes(m.uc.mem_read(0xB0000, 64000 + 1536))
        got = {(i % 320, i // 320) for i in (mo.start() for mo in _re.finditer(rb"[^\x00]", mem[:64000]))}
        dx, dy = x1 - x0, y1 - y0
        ok = mem[64000:] == bytes(1536)
        # every pixel drawn must be within half a pixel of the true line; every on-screen
        # step of the long axis must be drawn exactly once; endpoints (if visible) drawn
        for (px, py) in got:
            if abs(dx) >= abs(dy):
                ty = y0 + dy * ((px - x0) / dx) if dx else y0
                ok &= abs(py - ty) <= 0.5 + 1e-9 and min(x0, x1) <= px <= max(x0, x1)
            else:
                tx = x0 + dx * ((py - y0) / dy)
                ok &= abs(px - tx) <= 0.5 + 1e-9 and min(y0, y1) <= py <= max(y0, y1)
        # coverage: wherever the true line is unambiguously on-screen (0 <= y <= 199) the
        # long-axis column/row must have been drawn. Exact half-pixel ties on the boundary are
        # deliberately NOT required (Bresenham may round them either way).
        if abs(dx) >= abs(dy):
            cols = {px for px, py in got}
            for k in range(abs(dx) + 1):
                px = x0 + (k if dx >= 0 else -k); ty = y0 + (dy * (px - x0) / dx if dx else 0)
                if 0 <= px <= 319 and 0 <= ty <= 199 and px not in cols: ok = False; break
        else:
            rows = {py for px, py in got}
            for k in range(abs(dy) + 1):
                py = y0 + (k if dy >= 0 else -k); tx = x0 + dx * (py - y0) / dy
                if 0 <= py <= 199 and 0 <= tx <= 319 and py not in rows: ok = False; break
        if (0 <= x0 <= 319 and 0 <= y0 <= 199): ok &= (x0, y0) in got
        if (0 <= x1 <= 319 and 0 <= y1 <= 199): ok &= (x1, y1) in got
        checked += 1
        if not ok: bad.append((x0, y0, x1, y1))
    check(not hang, f"never hangs: every line terminates ({checked} lines run) {hang[:3]}")
    check(not bad, f"every pixel within 1/2 px of the true line, endpoints drawn, nothing outside the page ({len(bad)} bad) {bad[:3]}")

def test_crtc():
    print("\n== page flip: CRTC start-address register order ==")
    com, lst = assemble([], "crtc")
    m = Machine(com, 6)
    seq = []
    orig_out = m.on_out
    def tap(mm, port, value):
        if port == 0x3D4: seq.append(["idx", value])
        elif port == 0x3D5 and seq and seq[-1][0] == "idx": seq[-1] = ("reg", seq[-1][1], value)
    m.out_hooks.append(tap)
    m.run(8)
    regs = [(r[1], r[2]) for r in seq if r[0] == "reg" and r[1] in (0x0C, 0x0D)]
    pairs = [(regs[i][1], regs[i + 1][1]) for i in range(0, len(regs) - 1, 2)]
    check(all(regs[i][0] == 0x0C and regs[i + 1][0] == 0x0D for i in range(0, len(regs) - 1, 2)),
          "each flip writes index 0Ch then 0Dh")
    # VGA: 0Ch = Start Address HIGH, 0Dh = LOW. Page 0 = 0000h, page 1 = 4000h (65536 / 4, chain-4)
    check(pairs[:4] == [(0x00, 0x00), (0x40, 0x00), (0x00, 0x00), (0x40, 0x00)],
          f"(0Ch,0Dh) alternates (00h,00h) / (40h,00h): page 1 = start address 4000h  {pairs[:4]}")

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

TESTS = {"lines": test_lines, "crtc": test_crtc, "math": test_math, "palette": test_palette, "gfx": test_gfx, "bounce": test_bounce, "fields": test_fields, "music": test_music,
         "exit": test_exit_and_pacing, "scenes": test_scenes, "intro": test_intro}

if __name__ == "__main__":
    which = sys.argv[1:] or list(TESTS)
    for w in which:
        if w == "lines" and len(sys.argv) > 2 and sys.argv[1] == "lines": TESTS[w](int(sys.argv[2]))
        elif w.isdigit(): continue
        else: TESTS[w]()
    print("\nRESULT:", "ALL PASS" if not fails else f"{len(fails)} FAILED:\n  - " + "\n  - ".join(fails))
    sys.exit(1 if fails else 0)
