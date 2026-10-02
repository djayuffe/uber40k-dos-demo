#!/usr/bin/env python3
"""Behavioural tests: run the real .COM binaries in an emulated 16-bit CPU
(Unicorn) and observe what they do to the hardware.

The static audits (audit*.py) only grep source text and screenshots can't
see sound, so a drum pattern that never fires, or a chip left ringing after
exit, passes every other check. This traps port I/O and DOS/BIOS interrupts
to catch exactly that class of bug.

    python3 -m venv .venv && .venv/bin/pip install unicorn
    .venv/bin/python tests/emu_test.py            # both programs
    .venv/bin/python tests/emu_test.py show 600   # showcase, 600 frames
"""
import sys, pathlib
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INSN, UC_HOOK_INTR, UC_HOOK_MEM_UNMAPPED
from unicorn.x86_const import *

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEG = 0x1000
fails = []

def check(cond, msg):
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        fails.append(msg)

class Machine:
    def __init__(self, com_name, esc_frame, flip_port_is_crtc, frames_by_poll=False):
        self.frames_by_poll = frames_by_poll
        self.opl, self.opl_log = {}, []
        self.opl_index = self.crtc_index = 0
        self.flips = self.vsync_reads = 0
        self.esc_frame = esc_frame
        self.irq_writes, self.modes, self.sp_at_frame = [], [], []
        self.unmapped, self.exited, self.resized = [], False, False
        self.crtc_flip = flip_port_is_crtc
        com = pathlib.Path(com_name).read_bytes() if pathlib.Path(com_name).is_absolute() else (ROOT / com_name).read_bytes()
        uc = self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0x10000)
        uc.mem_map(SEG << 4, 0x10000)
        uc.mem_map(0xA0000, 0x20000)                 # VGA A000h + B000h
        uc.mem_write((SEG << 4) + 0x100, com)
        uc.mem_write(SEG << 4, b"\xCD\x20")          # PSP: INT 20h (what 'ret' reaches)
        for r in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS):
            uc.reg_write(r, SEG)
        uc.reg_write(UC_X86_REG_SP, 0xFFFE)          # DOS leaves a 0 word here
        uc.reg_write(UC_X86_REG_FLAGS, 0x202)
        uc.hook_add(UC_HOOK_INSN, self.on_in, None, 1, 0, UC_X86_INS_IN)
        uc.hook_add(UC_HOOK_INSN, self.on_out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_INTR, self.on_intr)
        uc.hook_add(UC_HOOK_MEM_UNMAPPED, lambda u, a, ad, sz, v, d: self.unmapped.append((hex(ad), sz)) or False)

    def esc(self):
        return self.flips >= self.esc_frame

    def on_in(self, uc, port, size, ud):
        if port == 0x3DA:
            self.vsync_reads += 1
            return 8 if (self.vsync_reads // 2) % 2 else 0
        if port == 0x64 and self.frames_by_poll:
            self.flips += 1                   # intro: one Esc poll per frame
        if port in (0x64, 0x60):
            return 1 if self.esc() else 0
        return 0

    def on_out(self, uc, port, size, value, ud):
        value &= 0xFF
        if port == 0x388: self.opl_index = value
        elif port == 0x389:
            self.opl[self.opl_index] = value
            self.opl_log.append((self.flips, self.opl_index, value))
        elif port == 0x3D4: self.crtc_index = value
        elif port == 0x3D5 and self.crtc_index == 0x0D:
            self.flips += 1
            self.sp_at_frame.append(uc.reg_read(UC_X86_REG_SP))
        elif port == 0x21: self.irq_writes.append(value)

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

    def run(self, max_frames, slice_=10_000_000, budget=6_000_000_000):
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

def test_showcase(frames):
    print(f"\n== UBERSHOW.COM ({frames} frames, Esc pressed after) ==")
    m = Machine("UBERSHOW.COM", frames, True)
    used = m.run(frames + 60)
    print(f"  ran {used/1e6:.0f}M instructions, {m.flips} frames")
    opl, log = m.opl, m.opl_log

    check(not m.unmapped, f"no access outside mapped memory {m.unmapped[:3]}")
    check(m.resized, "SETBLOCK issued before allocating/using memory")
    check(0x13 in m.modes, "VGA mode 13h entered")
    check(len(set(m.sp_at_frame)) == 1,
          f"stack balanced at every frame end (SP values seen: {sorted(set(map(hex, m.sp_at_frame)))})")

    for ch, (a, b) in {0: (0, 3), 1: (1, 4), 2: (2, 5), 3: (8, 11), 6: (16, 19), 7: (17, 20)}.items():
        check(all((0x20 + o) in opl for o in (a, b)) and (0xC0 + ch) in opl,
              f"channel {ch} instrument programmed (operators {a},{b})")
    check(any(r == 0xBD and v & 0x20 for _, r, v in log), "rhythm mode enabled (0xBD bit5)")

    kon = {c: [f for f, r, v in log if r == 0xB0 + c and v & 0x20] for c in range(9)}
    for c, name in ((0, "lead"), (1, "bass"), (2, "pad"), (3, "echo")):
        check(kon[c], f"{name} (ch{c}) plays notes ({len(kon[c])} key-ons)")
    check(all(f % 8 == 0 for f in kon[0] + kon[1] + kon[3]),
          "lead/bass/echo only retrigger on 8-frame step boundaries")
    check(all(f % 128 == 0 for f in kon[2]), "pad only changes every 128 frames")

    # echo must be EXACTLY the lead two steps (16 frames) later, same pitch
    def pitch(ch, f):
        a = [v for fr, r, v in log if fr == f and r == 0xA0 + ch]
        b = [v & 0x1F for fr, r, v in log if fr == f and r == 0xB0 + ch and v & 0x20]
        return (a[-1], b[-1]) if a and b else None
    lead_f = [f for f in kon[0] if f + 16 <= frames]  # lead's step 0 is never played at frame 0
    check(all(pitch(0, f) == pitch(3, f + 16) and pitch(0, f) for f in lead_f),
          f"every echo note is the lead's note 2 steps earlier ({len(lead_f)} checked)")
    check(not [f for f in kon[3] if f < 24], "no echo before the lead has played that note (frame < 24)")
    check(sorted(f + 16 for f in lead_f) == sorted(f for f in kon[3] if f <= frames),
          "echo plays exactly when the lead played 2 steps ago, and never otherwise")

    # drums
    def hits(bit): return [f for f, r, v in log if r == 0xBD and v & bit]
    bd, sd, hh = hits(0x10), hits(0x08), hits(0x01)
    check(bd and sd and hh, f"kick/snare/hat all trigger ({len(bd)}/{len(sd)}/{len(hh)} hits)")
    pos = lambda f: (f // 8) % 8
    check(all(f % 8 == 0 and pos(f) == 0 for f in bd), "kick only on step%8==0")
    check(all(f % 8 == 0 and pos(f) == 4 for f in sd), "snare only on step%8==4")
    check(all(f % 8 == 0 and pos(f) in (2, 6) for f in hh), "hi-hat only on off-beats (2,6)")
    check(len(bd) == len([f for f in range(0, frames, 64)]) or abs(len(bd) - frames // 64) <= 1,
          f"kick count matches the pattern (~{frames//64} expected)")

    # clean exit
    check(m.exited, "terminated via INT 21h/4Ch after Esc")
    check(all(not (opl.get(0xB0 + c, 0) & 0x20) for c in range(9)),
          f"all 9 channels keyed off at exit (B0..B8={[hex(opl.get(0xB0+c,0)) for c in range(9)]})")
    check(opl.get(0xBD, 0) == 0, f"rhythm register fully cleared at exit (0xBD={hex(opl.get(0xBD,0))})")
    check(len(m.irq_writes) >= 2 and not (m.irq_writes[-1] & 2) and (m.irq_writes[0] & 2),
          "IRQ1 masked while running, unmasked again at exit")


def build_fast_variant():
    """Assemble showcase.asm with SCENE_SHIFT=2 (4 frames/scene; palette_tick needs >= 2) so a short
    run visits all 18 scenes and all three act transpositions."""
    import subprocess, re, tempfile
    d = pathlib.Path(tempfile.mkdtemp(prefix="u40k_"))
    src = (ROOT / "showcase.asm").read_text().replace("%define SCENE_SHIFT 9", "%define SCENE_SHIFT 2")
    (d / "fast.asm").write_text(src)
    subprocess.run(["nasm", "-f", "bin", "-Wall", "-Werror", "-l", str(d / "fast.lst"),
                    str(d / "fast.asm"), "-o", str(d / "fast.com")], check=True)
    lst = (d / "fast.lst").read_text()
    m = re.search(r"^\s*\d+\s+([0-9A-Fa-f]{8})\s+\S+\s+cur_scene db", lst, re.M)
    return d / "fast.com", int(m.group(1), 16)

def test_all_scenes():
    print("\n== all 18 scenes + all 3 transposition acts (SCENE_SHIFT=2 variant) ==")
    com, off = build_fast_variant()
    m = Machine(str(com), 150, True)
    seen, overruns, acts = set(), [], set()
    base = (SEG << 4)
    addr = base + 0x100 + off          # nasm's listing gives file offsets (no ORG added)
    def sample():
        cs = m.uc.mem_read(addr, 1)[0]
        seen.add(cs)
        for page in (0xA0000, 0xB0000):             # a page is 64000 bytes; the rest of the segment must stay untouched
            if any(m.uc.mem_read(page + 64000, 1536)):
                overruns.append((cs, hex(page)))
    orig = m.on_out
    def on_out(uc, port, size, value, ud):
        before = m.flips
        orig(uc, port, size, value, ud)
        if port == 0x389 and m.opl_index == 0xB0 and (value & 0x20):
            acts.add(m.uc.mem_read(addr, 1)[0] >> 3)     # act the lead note was played in
        if m.flips != before: sample()
    m.on_out = on_out
    m.uc.hook_add(UC_HOOK_INSN, on_out, None, 1, 0, UC_X86_INS_OUT)
    m.run(170, slice_=10_000_000, budget=3_000_000_000)
    print(f"  {m.flips} frames; scenes seen: {sorted(seen)}")
    check(not m.unmapped, f"no access outside mapped memory {m.unmapped[:3]}")
    check(seen == set(range(18)), f"all 18 scenes executed (missing: {sorted(set(range(18)) - seen)})")
    check(not overruns, f"no scene writes past the 64,000-byte page {overruns[:3]}")
    check(len(set(m.sp_at_frame)) == 1, f"stack balanced through every scene (SPs: {sorted(set(map(hex, m.sp_at_frame)))})")
    check(m.exited, "still exits cleanly on Esc after cycling every scene")
    # every melodic note stays in a sane audible range at every transposition level
    bad, last_a = [], {}
    for f, r, v in m.opl_log:
        if 0xA0 <= r <= 0xA3: last_a[r - 0xA0] = v
        if 0xB0 <= r <= 0xB3 and v & 0x20:
            ch = r - 0xB0
            fnum = last_a.get(ch, 0) | ((v & 3) << 8); block = (v >> 2) & 7
            hz = fnum * 49716 / 2 ** (20 - block)
            if not (30 < hz < 4200): bad.append((ch, round(hz)))
    check(not bad, f"every note within 30..4200 Hz across all acts {bad[:3]}")
    check(acts == {0, 1, 2}, f"lead actually played in all 3 acts (observed acts {sorted(acts)})")

def test_intro(frames=40):
    print(f"\n== UBER256.COM ({frames} frames, Esc pressed after) ==")
    m = Machine("UBER256.COM", frames, False, frames_by_poll=True)
    m.run(frames + 5, slice_=5_000_000, budget=3_000_000_000)
    print(f"  {m.flips} frames rendered")
    check(not m.unmapped, f"no access outside mapped memory {m.unmapped[:3]}")
    check(0x13 in m.modes and 3 in m.modes, "enters mode 13h and restores text mode 3")
    check(m.exited, "terminates (returns to PSP INT 20h) after Esc")
    check(len(m.irq_writes) >= 2 and (m.irq_writes[0] & 2) and not (m.irq_writes[-1] & 2),
          "IRQ1 masked while running, unmasked again at exit")
    check(m.uc.reg_read(UC_X86_REG_SP) == 0,
          "stack balanced: final RET popped exactly the DOS return word (SP wrapped to 0)")

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("all", "show"):
        test_showcase(int(sys.argv[2]) if len(sys.argv) > 2 else 320)
    if which in ("all", "scenes"):
        test_all_scenes()
    if which in ("all", "intro"):
        test_intro()
    print("\nRESULT:", "ALL PASS" if not fails else f"{len(fails)} FAILED: " + "; ".join(fails))
    sys.exit(1 if fails else 0)
