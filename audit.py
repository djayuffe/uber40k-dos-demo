#!/usr/bin/env python3
from pathlib import Path
import re, sys
root=Path(__file__).resolve().parent
errors=[]
def need(name,s,needle,label):
    if needle not in s: errors.append(f"{name}: missing {label}")
for name in ("showcase.asm",):
    s=(root/name).read_text()
    for needle,label in [("BITS 16","16-bit declaration"),("ORG 100h","COM origin"),("mov ax,13h","VGA mode 13h"),("0A000h","VGA framebuffer")]: need(name,s,needle,label)
    if re.search(r"\b(?:sil|dil|spl|bpl)\b",s,re.I): errors.append(f"{name}: x86-64 byte register in 16-bit source")
s=(root/"showcase.asm").read_text()
for needle,label in [("mov dx,3CEh","VGA 128K memory-window reprogram"),("mov dx,3D4h","CRTC start-address page flip"),("in al,64h","8042 status check"),("wait_vsync:","vertical-retrace pacing"),("vga_page db 0","page-flip state"),("opl_init:","OPL2/SB music setup"),("opl_note_off:","OPL2/SB music cleanup"),("mov dx,388h","OPL2 FM port"),("music_tick:","sound sequencer"),("old_mode","video-mode preservation"),("palette_tick:","animated palette"),("pal_limit","palette transition envelope"),("and ax,511","scene-local transition phase")]: need("showcase.asm",s,needle,label)
if "in al,60h" in s and "in al,64h" not in s: errors.append("showcase.asm: keyboard data read without status guard")
for n in ["plasma","tunnel","xor","moire","checker","ripples","twister","feedback"]: need("showcase.asm",s,"scene_"+n+":",n+" scene")

# --- lint: a 16-bit COMPARE on AX straight after an 8-bit write to AL/AH ---
# This is the exact shape of a real bug (drum_tick loaded the baseline into AL
# and then did `cmp ax,0`, so the compare could never match and the drums never
# fired). Broader "partial register" patterns are far too noisy in effect code,
# where leaving AH untouched is deliberate; a *compare* on the clobbered
# register is almost never intended.
def lint_partial_ax(name, text):
    w8 = re.compile(r"^(mov|or|and|xor|add|sub|inc|dec|not|neg|shl|shr|rol|ror)\s+a[lh]\b")
    cmp16 = re.compile(r"^(cmp|test)\s+ax\b")
    out, prev = [], None
    for n, line in enumerate(text.split("\n"), 1):
        code = line.split(";")[0].strip()
        if not code:
            continue
        if cmp16.match(code) and prev and w8.match(prev[1]):
            out.append(f"{name}:{n}: 'cmp/test ax' right after 8-bit write '{prev[1]}' (line {prev[0]})")
        prev = (n, code) if not code.endswith(":") else None
    return out
_SELFTEST = "    mov al,[x]\n    cmp ax,0\n"
assert lint_partial_ax("selftest", _SELFTEST), "lint failed to flag the known-bad pattern"
for name in ("showcase.asm",):
    errors += lint_partial_ax(name, (root/name).read_text())
print("static source audit:", "PASS" if not errors else "FAIL")
for e in errors: print(" -",e)
sys.exit(bool(errors))
