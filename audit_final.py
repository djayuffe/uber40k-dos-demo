#!/usr/bin/env python3
from pathlib import Path
import re, sys
p=Path(__file__).with_name("showcase.asm")
s=p.read_text()
errors=[]
required=[
"%define SCENE_COUNT 18","call wait_vsync","call palette_tick",
"in al,64h","in al,60h","scene_finale:","scene_cube:",
"scene_starfield:","pal_limit db 63","scene_marker:","transition_wipe:",
"call scene_marker","call transition_wipe","scroll_draw:","call scroll_draw",
"draw_line:","cube_rotate_project:","render_object:","cur_scene db 0",
# true VGA page-flip double buffering: 128K memory window + CRTC
# start-address flip, not a system-RAM backbuffer + blit
"and al,0F3h","vga_page db 0","show_page db 0","mov dx,3D4h",
# OPL2 FM music (Sound Blaster / AdLib, fixed port 388h/389h): three
# simultaneous voices (lead/bass/pad) plus the built-in rhythm section
"opl_write:","opl_init:","opl_note_on:","opl_note_off:","mov dx,388h",
"opl_set_instrument:","chan_op1 db","chan_op2 db","bass_tick:","pad_tick:",
"drum_tick:","inst_lead db","inst_bass db","inst_pad","inst_bd","inst_sd",
"mov ah,0BDh","opl_silence:","echo_tick:","inst_echo db",
]
for x in required:
    if x not in s: errors.append("missing: "+x)
scenes=re.findall(r"^scene_(?!marker)[a-z0-9_]+:",s,re.M)
if len(scenes)!=18: errors.append(f"expected 18 scenes, found {len(scenes)}")
# scenes whose contract isn't "full 320x200 STOSB sweep ending in jmp overlay"
SPECIAL = {
    # scene_cube renders two objects (cube + octahedron) through the shared
    # render_object engine, which is what actually calls draw_line.
    "scene_cube:": ("rep stosw", "call render_object"),
    "scene_starfield:": ("rep stosw", "idiv word [star_z]"),
}
for label in scenes:
    start=s.index(label)
    nxt=min([i for i in [s.find("\nscene_",start+1),s.find("\noverlay:",start+1)] if i!=-1])
    body=s[start:nxt]
    if label in SPECIAL:
        for needle in SPECIAL[label]:
            if needle not in body: errors.append(f"{label} missing {needle!r}")
    else:
        if "stosb" not in body: errors.append(label+" has no pixel store")
        if "cmp cx,320" not in body or "cmp dx,200" not in body:
            errors.append(label+" lacks canonical 320x200 bounds")
    if label != "scene_finale:" and "jmp overlay" not in body:
        errors.append(label+" does not jump to overlay (falls through into next scene / overruns the VGA page)")
# the chip keeps sounding after exit unless every voice is keyed off
if not re.search(r"^exit:\n\s+call opl_silence", s, re.M):
    errors.append("exit: must call opl_silence first (else the OPL2 rings on after return to DOS)")
if "call opl_silence" not in s.split("opl_init:")[1].split("ret")[0]:
    errors.append("opl_init must start from a silenced chip")
if "mov es,ax\n    xor di,di" not in s:
    errors.append("ES page-segment load missing at main:")
if errors:
    print("AUDIT FAIL")
    print("\n".join(errors)); sys.exit(1)
print("AUDIT PASS: 18 scenes, framebuffer/presentation/cleanup invariants present")
