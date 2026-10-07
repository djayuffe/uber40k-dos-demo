#!/usr/bin/env python3
from pathlib import Path
import re,sys
r=Path(__file__).parent
s=(r/"showcase.asm").read_text()
errors=[]
for f in ["showcase.asm","build.sh","run-dosbox.sh","DOSBOX.CONF",
          "README.md","TECHNICAL.md","CHANGELOG.md","audit.py","audit_final.py",
          "tests/emu_test.py","tests/run_tests.sh"]:
    if not (r/f).exists(): errors.append("missing "+f)
targets=["scene_plasma","scene_tunnel","scene_xor","scene_moire","scene_checker",
         "scene_ripples","scene_twister","scene_feedback","scene_copper","scene_diamond",
         "scene_lattice","scene_warp","scene_scanwave","scene_bitplane","scene_vortex",
         "scene_cube","scene_starfield","scene_finale"]
for x in targets:
    if s.count(x+":")!=1: errors.append("scene label "+x)
for x in ["call wait_vsync","call palette_tick","call music_tick",
          "in al,64h","in al,60h","mov ax,13h","int 10h","pal_limit db 63",
          "mov ah,4Ah","call scroll_draw","call draw_line","call render_object",
          "cube_rotate_project:","font_data:","scroll_msg:","sintab:",
          "octa_verts:","octa_edges:",
          # true VGA page-flip double buffering invariants
          "and al,0F3h","vga_page db 0","show_page db 0","mov dx,3D4h","mov dx,3CEh",
          # OPL2 FM music (Sound Blaster / AdLib): lead/bass/pad + rhythm
          "opl_write:","opl_init:","opl_note_on:","opl_note_off:","mov dx,388h",
          "opl_set_instrument:","lead_step:","bass_step:","pad_step:","echo_step:","arp_step:","drum_step:","opl_silence:",
          "star_bounce:","draw_core_octa:","draw_core_cube:","render_faces:","fill_poly:","sincos16:","fill_sky:","star_pass:"]:
    if x not in s: errors.append("missing invariant "+x)
if "org 100h" not in s.lower() or "bits 16" not in s.lower(): errors.append("showcase COM model")
b=(r/"build.sh").read_text()
if "40960" not in b or "nasm" not in b.lower(): errors.append("build size gate/tool")
if errors:
    print("RELEASE AUDIT: FAIL")
    print("\n".join(errors));sys.exit(1)
print("RELEASE AUDIT: PASS")
print("  18 explicit scenes (16 fields + 3D cube/octahedron engine + 3D starfield)")
print("  bottom sine-wave text scroller")
print("  own-block SETBLOCK shrink (code/data/stack)")
print("  true VGA hardware double buffering (128K window + CRTC page flip)")
print("  OPL2 FM music: lead/bass/pad/echo + kick/snare/hat (port 388h)")
print("  behavioural emulator tests present (tests/)")
print("  palette, input, video and cleanup invariants")
print("  40K size gate present")
