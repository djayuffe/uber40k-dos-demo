#!/usr/bin/env python3
from pathlib import Path
import re, sys
root=Path(__file__).resolve().parent
errors=[]
def need(name,s,needle,label):
    if needle not in s: errors.append(f"{name}: missing {label}")
for name in ("intro256.asm","showcase.asm"):
    s=(root/name).read_text()
    for needle,label in [("BITS 16","16-bit declaration"),("ORG 100h","COM origin"),("mov ax,13h","VGA mode 13h"),("0A000h","VGA framebuffer")]: need(name,s,needle,label)
    if re.search(r"\b(?:sil|dil|spl|bpl)\b",s,re.I): errors.append(f"{name}: x86-64 byte register in 16-bit source")
s=(root/"showcase.asm").read_text()
for needle,label in [("mov dx,3CEh","VGA 128K memory-window reprogram"),("mov dx,3D4h","CRTC start-address page flip"),("in al,64h","8042 status check"),("wait_vsync:","vertical-retrace pacing"),("vga_page db 0","page-flip state"),("opl_init:","OPL2/SB music setup"),("opl_note_off:","OPL2/SB music cleanup"),("mov dx,388h","OPL2 FM port"),("music_tick:","sound sequencer"),("old_mode","video-mode preservation"),("palette_tick:","animated palette"),("pal_limit","palette transition envelope"),("and ax,511","scene-local transition phase")]: need("showcase.asm",s,needle,label)
if "in al,60h" in s and "in al,64h" not in s: errors.append("showcase.asm: keyboard data read without status guard")
for n in ["plasma","tunnel","xor","moire","checker","ripples","twister","feedback"]: need("showcase.asm",s,"scene_"+n+":",n+" scene")
print("static source audit:", "PASS" if not errors else "FAIL")
for e in errors: print(" -",e)
sys.exit(bool(errors))
