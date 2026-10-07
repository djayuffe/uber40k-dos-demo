; UBER DOS SHOWCASE 5.0 - polished procedural VGA demo
; NASM syntax, DOS .COM, 386+, VGA, OPL2 FM (Sound Blaster/AdLib). No external assets.
BITS 16
ORG 100h

%define SCENE_SHIFT 9             ; 512 frames/scene (~7.3 s at 70 Hz)
%define SCENE_COUNT 18            ; 18 primary scenes (16 fields + cube + starfield)
%define SCROLL_BASE_Y 182         ; bottom text-scroller baseline row
%define SCROLL_BG 1                ; fixed black (see palette_tick reserved DAC entries)
; Scroller foreground cycles across fixed DAC indices 4..7 (a small rainbow,
; see palette_tick) rather than one fixed colour -- see scroll_draw.
%define CUBE_FG 2                 ; fixed white, near-edge wireframe colour
%define CUBE_FG_DIM 3             ; fixed dim grey, far-edge wireframe colour
%define CUBE_EYE_DIST 160         ; perspective-divide distance from the eye
%define CUBE_PROJ_SCALE 110       ; perspective projection scale factor
%define SHADE_BASE 8              ; DAC 8..23: 16-step shading ramp for solid faces
%define SKY_BASE 24               ; DAC 24..39: night-sky gradient, 16 steps
%define STAR_MID 40               ; DAC 40: mid-grey star
%define STAR_NEAR 41              ; DAC 41: warm-white nearest stars
%define LIGHT_X -4                ; light direction (toward the light), |L| = 14
%define LIGHT_Y -6
%define LIGHT_Z -12
%define STAR_COUNT 32             ; stars in scene_starfield
%define STAR_SCALE 20             ; starfield perspective projection scale

start:
    ; A .COM program owns ALL free conventional memory at launch (its PSP
    ; block spans to the top of the DOS arena). This demo renders into video
    ; RAM directly (true page flip, see present:) and needs no DOS-allocated buffer,
    ; but it keeps its code, data tables and a small local stack in
    ; conventional memory. Shrinking the PSP block to 16 KiB gives a bounded
    ; footprint and keeps the local stack (stack_top) inside a known region
    ; instead of floating somewhere in the default 64 KiB.
    mov ax,cs
    mov es,ax
    mov bx,4096                   ; 4096 paragraphs = 64 KiB: image + stack + the polar maps
    mov ah,4Ah                    ; covers code+data+stack (font, scroller,
    int 21h                       ; cube tables) with room to spare.
    mov ax,cs
    mov ss,ax
    mov sp,stack_top              ; switch onto our own stack inside that block
    push cs
    pop ds
    mov ah,0Fh
    int 10h
    mov [old_mode],al
    mov ax,13h
    int 10h
    ; True hardware double buffering: widen the VGA CPU window from the
    ; BIOS mode-13h default (64K @ A0000h) to 128K @ A0000h (Graphics
    ; Controller Misc Register, Memory Map Select = 00), so segments A000h
    ; and B000h both address real VGA memory -- two independent 64,000-byte
    ; pages. Each frame renders entirely into the currently-hidden page,
    ; then present: flips the CRTC start address to display it: a real
    ; page flip, not a software copy into A000h.
    mov dx,3CEh
    mov al,6
    out dx,al
    inc dx
    in al,dx
    and al,0F3h                   ; Memory Map Select = 00 (128K @ A0000h)
    out dx,al
    mov byte [vga_page],0         ; page we render into next (0=A000h,1=B000h)
    in al,21h
    mov [pic_mask],al
    or al,2                       ; mask IRQ1 so BIOS int 9 cannot race
    out 21h,al                    ; our own port-60h/64h polling for Esc
    call build_tabs
    call build_maps
    xor bp,bp
    call palette_tick
    call opl_init

main:
    mov al,[vga_page]              ; render into the currently-hidden page
    cmp al,0
    je .page0
    mov ax,0B000h
    jmp .haveseg
.page0:
    mov ax,0A000h
.haveseg:
    mov es,ax
    xor di,di
    ; cur_scene is a 0..SCENE_COUNT-1 counter advanced in present: once per
    ; 2^SCENE_SHIFT frames; scene_marker and music_tick read the same byte.
    mov al,[cur_scene]
    cmp al,0
    je scene_plasma
    cmp al,1
    je scene_tunnel
    cmp al,2
    je scene_xor
    cmp al,3
    je scene_moire
    cmp al,4
    je scene_checker
    cmp al,5
    je scene_ripples
    cmp al,6
    je scene_twister
    cmp al,7
    je scene_feedback
    cmp al,8
    je scene_copper
    cmp al,9
    je scene_diamond
    cmp al,10
    je scene_lattice
    cmp al,11
    je scene_warp
    cmp al,12
    je scene_scanwave
    cmp al,13
    je scene_bitplane
    cmp al,14
    je scene_vortex
    cmp al,15
    je scene_cube
    cmp al,16
    je scene_starfield
    jmp scene_finale

; ---------------------------------------------------------------------------
; Field scenes 1-15 and 18: the "hyper-optimised" renderer.
;
; The old fields evaluated a sum of sines for every one of 64,000 pixels
; (2-3 million instructions a frame: far beyond what a 486 can do in one 70 Hz
; frame). Three tricks bring that down to about 200k:
;   * HALF RESOLUTION (optical hack): every value is computed once per 2x2
;     block (160x100) and written as a doubled word to two rows. The fields are
;     smooth, so the eye sees no difference, and the palette flows underneath.
;   * LOOKUP TABLES instead of maths: a pixel is a few table reads and adds.
;     sin56/sin165 are built once from the sine table; the per-frame tables
;     (ta_tab, tr_tab) are 256 entries each.
;   * PRECOMPUTED POLAR MAPS: the angle and radius of every block (ang_map,
;     rad_map) are computed once at start, so tunnels, rings and spirals are
;     just  TA[angle] + TR[radius]  with no atan/sqrt per frame.
; Three pixel loops cover every scene:
;   fieldW  two linear waves + a row wave   (plasma, lattices, bars, grids)
;   fieldM  TA[angle] + TR[radius]          (tunnel, moire, ripples, orbs)
;   fieldS  sin(TA[angle] + TR[radius])     (spirals)
; Values always land in palette indices 42..255, the part of the DAC that
; palette_tick animates, so the colours flow over time.
; ---------------------------------------------------------------------------
%macro WSET 8                     ; x-step/y-step/speed of wave 1 and 2, y-step/speed of the row wave
    mov word [w_st1],%1
    mov word [w_ry1],%2
    mov ax,bp
    imul ax,%3
    mov [w_p1],ax
    mov word [w_st2],%4
    mov word [w_ry2],%5
    mov ax,bp
    imul ax,%6
    mov [w_p2],ax
    mov word [w_ry3],%7
    mov ax,bp
    imul ax,%8
    mov [w_p3],ax
%endmacro
%macro TABLIN 4                   ; table[i] = src[(BL + i*step)&255] + add
    mov si,%1
    mov di,%2
    mov dl,%3
    mov dh,%4
    call tab_lin
%endmacro

; 1: plasma
scene_plasma:
    WSET 900,1400,0200h, -700,1100,-0180h, 900,0100h
    call fieldW
    jmp overlay
; 2: tunnel: angle stripes x true 1/r depth rings
scene_tunnel:
    mov ax,bp
    add ax,ax
    mov bl,al
    TABLIN sin56,ta_tab,3,0
    call tab_depth
    call fieldM
    jmp overlay
; 3: orbs: two crossing wave families in polar space
scene_xor:
    mov ax,bp
    mov bx,ax
    add ax,ax
    add ax,bx
    mov bl,al
    TABLIN sin56,ta_tab,2,0
    mov ax,bp
    shl ax,2
    neg ax
    mov bl,al
    TABLIN sin56,tr_tab,3,42
    call fieldM
    jmp overlay
; 4: moire: fine rays against moving rings
scene_moire:
    mov bx,bp
    TABLIN sin56,ta_tab,8,0
    mov ax,bp
    shl ax,2
    neg ax
    mov bl,al
    TABLIN sin56,tr_tab,3,42
    call fieldM
    jmp overlay
; 5: soft checker (egg-crate)
scene_checker:
    WSET 820,0,0180h, 0,1310,-0200h, 0,0
    call fieldW
    jmp overlay
; 6: ripples: pure rings travelling outwards
scene_ripples:
    xor bl,bl
    TABLIN sin56,ta_tab,0,0
    mov ax,bp
    shl ax,3
    neg ax
    mov bl,al
    TABLIN sin56,tr_tab,5,42
    call fieldM
    jmp overlay
; 7: ribbons
scene_twister:
    WSET 1640,80,0300h, -980,-60,0200h, 200,0100h
    call fieldW
    jmp overlay
; 8: interference of three moving waves
scene_feedback:
    WSET 1100,-900,0280h, 700,1500,-0300h, 900,0200h
    call fieldW
    jmp overlay
; 9: copper bars
scene_copper:
    WSET 60,2620,0500h, -100,1700,0380h, 3300,-0400h
    call fieldW
    jmp overlay
; 10: diamonds
scene_diamond:
    WSET 820,1310,0300h, 820,-1310,-0300h, 0,0
    call fieldW
    jmp overlay
; 11: fine diagonal lattice
scene_lattice:
    WSET 1640,2620,0200h, 1640,-2620,-0200h, 0,0
    call fieldW
    jmp overlay
; 12: wavy bands
scene_warp:
    WSET 300,1800,0400h, -200,-1400,0300h, 1100,0200h
    call fieldW
    jmp overlay
; 13: scanwave
scene_scanwave:
    WSET 410,3930,0600h, -205,1300,-0300h, 2600,0500h
    call fieldW
    jmp overlay
; 14: rotating grid: the two wave directions turn with the frame clock
scene_bitplane:
    mov bx,bp
    shr bx,1
    push bx
    add bx,64
    and bx,255
    movsx ax,byte [sintab+bx]     ; cos
    mov si,ax
    pop bx
    and bx,255
    movsx ax,byte [sintab+bx]     ; sin
    mov bx,si
    imul bx,6
    mov [w_st1],bx
    mov bx,ax
    imul bx,10
    mov [w_ry1],bx
    mov bx,ax
    imul bx,-6
    mov [w_st2],bx
    mov bx,si
    imul bx,10
    mov [w_ry2],bx
    mov ax,bp
    imul ax,0200h
    mov [w_p1],ax
    mov word [w_p2],0
    mov word [w_ry3],0
    mov word [w_p3],0
    call fieldW
    jmp overlay
; 15: vortex: three spiral arms
scene_vortex:
    mov ax,bp
    add ax,ax
    mov bl,al
    TABLIN ident,ta_tab,3,0
    mov ax,bp
    shl ax,2
    mov bl,al
    TABLIN ident,tr_tab,3,0
    call fieldS
    jmp overlay

; 16: the 3D engine scene. It clears the page with the night-sky gradient and
; starfield, then draws real 3D objects (two-axis rotation, perspective
; projection, culling, lighting, polygon fill, Bresenham lines) instead of a
; per-pixel field.
; Two independent 3D objects sharing one engine (render_object): a cube and
; an octahedron, each spun by a different pair of angle rates and offset to
; opposite sides of the screen, so they visibly rotate differently rather
; than looking like one re-skinned object.
scene_cube:
    call fill_sky
    ; Solid and shaded for three quarters of every 512-frame scene, plain
    ; wireframe for the last quarter -- the same engine, two render modes.
    ; In wireframe mode the objects also become hollow force-fields: stars
    ; bounce off them (star_bounce) and a small solid core spins inside each.
    mov ax,bp
    and ax,180h
    cmp ax,180h
    mov byte [obj_solid],1
    mov byte [bounce_on],0
    jne .sc_mode
    mov byte [obj_solid],0
    mov byte [bounce_on],1
.sc_mode:
    call star_pass

    cmp byte [obj_solid],0
    jne .no_core1
    call draw_core_octa              ; hollow cube: small solid octahedron inside
.no_core1:
    mov cl,7                       ; angle = frame * 128 (0.5 table step per
    mov ax,bp                      ; frame, as before) but kept as a 16-bit
    shl ax,cl                      ; value so sincos16 can interpolate: the
    mov [cube_angle_y],ax          ; pose now changes EVERY frame, not every
    mov cl,6                       ; other one
    mov ax,bp
    shl ax,cl
    mov [cube_angle_x],ax
    mov word [obj_verts_ptr],cube_verts
    mov word [obj_edges_ptr],cube_edges
    mov word [obj_faces_ptr],cube_faces
    mov word [obj_vbytes],8*6
    mov word [obj_ebytes],12*2
    mov word [obj_fbytes],6*4
    mov eax,[cube_norml]
    mov [obj_norml],eax
    mov word [obj_offset_x],-70
    mov word [obj_offset_y],0
    mov byte [obj_fg],CUBE_FG
    mov byte [obj_fg_dim],CUBE_FG_DIM
    call render_object

    cmp byte [obj_solid],0
    jne .no_core2
    call draw_core_cube              ; hollow octahedron: small solid cube inside
.no_core2:
    mov cl,6
    mov ax,bp
    shl ax,cl
    mov [cube_angle_y],ax
    mov cl,7
    mov ax,bp
    shl ax,cl
    mov [cube_angle_x],ax
    mov word [obj_verts_ptr],octa_verts
    mov word [obj_edges_ptr],octa_edges
    mov word [obj_faces_ptr],octa_faces
    mov word [obj_vbytes],6*6
    mov word [obj_ebytes],12*2
    mov word [obj_fbytes],8*4
    mov eax,[octa_norml]
    mov [obj_norml],eax
    mov word [obj_offset_x],70
    mov word [obj_offset_y],0
    mov byte [obj_fg],CUBE_FG
    mov byte [obj_fg_dim],CUBE_FG_DIM
    call render_object
    jmp overlay

; 17: 3D starfield. Each star has a genuine Z depth, computed fresh every
; frame as a function of the frame clock and star index (no persistent
; per-star state needed): Z counts down from far to near and wraps back to
; far, so stars continuously stream toward the viewer. Perspective-divides
; by Z exactly like scene_cube's projection, just for points instead of
; wireframe edges, and brightens as a star gets closer.
scene_starfield:
    mov byte [bounce_on],0
    call fill_sky
    call star_pass
    jmp overlay

; 18: finale: a fast two-armed spiral
scene_finale:
    mov bx,bp
    neg bx
    TABLIN ident,ta_tab,2,0
    mov ax,bp
    mov bx,ax
    add ax,ax
    add ax,bx
    add ax,ax
    neg ax
    mov bl,al
    TABLIN ident,tr_tab,5,0
    call fieldS
    jmp overlay


overlay:
    ; Three smooth raster bars, positions phase-locked to global frame clock.
    ; The 3D scenes (15, 16) have their own sky and no animated palette, so the
    ; bars (which take their colour from it) would be black stripes: skip them.
    mov al,[cur_scene]
    sub al,15
    cmp al,2
    jb .nobars
    mov ax,bp
    and ax,127
    add ax,30
    call raster_line
    mov ax,bp
    shr ax,1
    and ax,63
    add ax,92
    call raster_line
    mov ax,bp
    shr ax,2
    and ax,31
    add ax,150
    call raster_line
.nobars:
    call scene_marker
    call transition_wipe
    call scroll_draw              ; bottom sine-wave text scroller, drawn
                                   ; after the transition wipe so it's never
                                   ; covered by the scene-cut shutter bars

present:
    ; Page flip, in the order that is correct however the CRTC latches its start
    ; address: write the new start address FIRST, then wait for retrace, and only
    ; then draw into the other page. (This used to wait for retrace and write the
    ; address afterwards: on hardware that latches at retrace start the flip then
    ; lands a frame late, and the next frame is drawn into the page still being
    ; scanned -- visible tearing. DOSBox latches at frame start, which hid it.)
    mov al,[vga_page]
    mov [show_page],al
    xor al,1
    mov [vga_page],al
    mov al,[show_page]
    cmp al,0
    je .show0
    mov bx,4000h                  ; page1 (B000h) = byte offset 65536,
    jmp .haveaddr                 ; /4 for chain-4 start-address units
.show0:
    xor bx,bx                     ; page0 (A000h) = byte offset 0
.haveaddr:
    ; VGA CRTC: index 0Ch = Start Address HIGH, index 0Dh = Start Address LOW
    ; (IBM VGA reference / FreeVGA). Page 1 = byte offset 65536 = 4000h in
    ; chain-4 units, so it is written as 0Ch=40h, 0Dh=00h. Swapping the two
    ; would display page 0 shifted by 256 bytes and never show page 1.
    mov al,[beat]                 ; screen shake: the kick pushes the display down
    shr al,3                      ; 0..3 rows (one row = 80 start-address units),
    jz .noshake                   ; settling back as the beat decays. The rows that
    mov cl,80                     ; scroll in at the bottom lie outside both pages
    mul cl                        ; and are black.
    add bx,ax
.noshake:
    mov dx,3D4h
    mov al,0Ch
    out dx,al
    inc dx
    mov al,bh
    out dx,al
    dec dx
    mov al,0Dh
    out dx,al
    inc dx
    mov al,bl
    out dx,al
    call wait_vsync               ; new page is now what's on screen
    call palette_tick             ; DAC writes happen inside vertical blank
    inc bp
    ; Advance the scene counter every 2^SCENE_SHIFT frames. It is a counter, not
    ; (bp >> SCENE_SHIFT) mod SCENE_COUNT: bp is 16-bit, so that expression has
    ; only 128 groups of 512 frames and 128 mod 18 = 2, which replayed scenes 0
    ; and 1 once at every wrap of the frame clock.
    test bp,(1 << SCENE_SHIFT) - 1
    jnz .same_scene
    mov al,[cur_scene]
    inc al
    cmp al,SCENE_COUNT
    jb .scene_ok
    xor al,al
.scene_ok:
    mov [cur_scene],al
.same_scene:
    call music_tick
    call key_escape
    jnc main

exit:
    call opl_silence
    mov al,[pic_mask]
    out 21h,al                    ; restore BIOS IRQ1 keyboard servicing
    xor ah,ah
    mov al,[old_mode]
    int 10h
    mov ax,4C00h
    int 21h

; AX = y. ES still points at the page being rendered here. Draws a soft 3-scanline glow
; (dim/bright/dim) instead of one flat line, a classic fatter raster bar.
raster_line:
    cmp ax,199
    ja .done
    push ax
    push bx
    push cx
    push di
    mov [raster_cy],ax             ; centre y (mul below clobbers dx, so this
                                    ; can't just live in a register)
    cmp ax,0
    je .no_above
    dec ax
    mov bx,320
    mul bx
    mov di,ax
    mov cx,320
    mov al,232
    rep stosb
.no_above:
    mov ax,[raster_cy]
    mov bx,320
    mul bx
    mov di,ax
    mov cx,320
    mov al,248
    rep stosb

    mov ax,[raster_cy]
    cmp ax,199
    je .no_below
    inc ax
    mov bx,320
    mul bx
    mov di,ax
    mov cx,320
    mov al,232
    rep stosb
.no_below:
    pop di
    pop cx
    pop bx
    pop ax
.done: ret


; Scene identity strip: SCENE_COUNT small blocks at the top, current scene
; highlighted. Deliberately tiny: 17 blocks * 8x8 pixels ~= 1088 stores/frame.
scene_marker:
    push ax
    push bx
    push cx
    push dx
    push di
    mov dl,[cur_scene]
    xor dh,dh
    xor bx,bx
.sm_next:
    mov ax,bx
    shl ax,3
    add ax,4
    mov di,ax
    mov cx,8
    mov al,32
    cmp bx,dx
    jne .sm_color
    mov al,252
.sm_color:
    push cx
    mov cx,8
    rep stosb
    pop cx
    add di,312
    loop .sm_color
    inc bx
    cmp bx,SCENE_COUNT
    jb .sm_next
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Cheap transition shutter. During the first/last 16 frames of a scene,
; black bars close/open symmetrically. Palette fade remains the primary blend.
transition_wipe:
    push ax
    push bx
    push cx
    push dx
    push di
    mov ax,bp
    and ax,511
    cmp ax,16
    jb .tw_have
    cmp ax,496
    jb .tw_done
    mov bx,512
    sub bx,ax
    mov ax,bx
.tw_have:
    ; AX=0..15. Convert to number of covered scanlines, 96..6.
    mov bx,ax
    shl ax,1
    add ax,bx
    mov bx,100
    sub bx,ax
    cmp bx,0
    jle .tw_done
    mov dx,bx
    xor di,di
.tw_top:
    mov cx,320
    mov al,1                      ; fixed black (DAC 1); index 0 belongs to the
    rep stosb                     ; animated palette and showed up as dull olive
    dec dx
    jnz .tw_top
    mov ax,bx
    mov dx,200
    sub dx,ax
    mov ax,dx
    mov cx,320
    mul cx
    mov di,ax
    mov dx,bx
.tw_bottom:
    mov cx,320
    mov al,1                      ; fixed black (DAC 1); index 0 belongs to the
    rep stosb                     ; animated palette and showed up as dull olive
    dec dx
    jnz .tw_bottom
.tw_done:
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ===== field-scene engine (see the comment above the scene block) =====

; table[i] = src[(BL + i*DL)&255] + DH   (SI = source, DI = destination)
tab_lin:
    xor bh,bh
    mov cx,256
.tl:
    mov al,[si+bx]
    add al,dh
    mov [di],al
    inc di
    add bl,dl
    dec cx
    jnz .tl
    ret

; tr_tab[r] = sin56[2600/(r+10) - 4*frame] + 42: a true perspective depth
; (1/r), which is what makes the tunnel look like a tunnel.
tab_depth:
    xor si,si
.td:
    mov bx,si
    add bx,10
    mov ax,2600
    xor dx,dx
    div bx
    mov dx,bp
    shl dx,2
    sub ax,dx
    mov bl,al
    xor bh,bh
    mov al,[sin56+bx]
    add al,42
    mov [tr_tab+si],al
    inc si
    cmp si,256
    jb .td
    ret

; fieldW: value = sin56[wave1] + sin56[wave2] + row term, where the wave
; phases advance by [w_st1]/[w_st2] (8.8) per block and by [w_ry*] per row.
fieldW:
    mov ax,[w_p1]
    mov [wr1],ax
    mov ax,[w_p2]
    mov [wr2],ax
    mov al,[beat]                 ; the row wave jumps by up to 16 steps on a kick
    xor ah,ah                     ; and settles back: the bands visibly bounce
    shl ax,7
    add ax,[w_p3]
    mov [wr3],ax
    xor di,di
    xor bh,bh
    mov word [fw_y],100
.row:
    mov bl,[wr3+1]
    mov al,[sin56+bx]
    add al,FIXED_PAL_COUNT+1
    mov [rowc],al
    mov ax,[w_ry3]
    add [wr3],ax
    mov dx,[wr1]
    mov ax,[w_ry1]
    add [wr1],ax
    mov cx,[wr2]
    mov ax,[w_ry2]
    add [wr2],ax
    lea ax,[di+320]
    mov [row_end],ax
.px:
    mov bl,dh
    mov al,[sin56+bx]
    mov bl,ch
    add al,[sin56+bx]
    add al,[rowc]
    add dx,[w_st1]
    add cx,[w_st2]
    mov ah,al
    stosw
    mov [es:di+318],ax
    cmp di,[row_end]
    jb .px
    add di,320
    dec word [fw_y]
    jnz .row
    ret

; fieldM: value = ta_tab[angle] + tr_tab[radius] (maps are per 2x2 block)
fieldM:
    xor si,si
    xor di,di
    xor bh,bh
    mov dx,100
.row:
    mov cx,160
.px:
    mov bl,[ang_map+si]
    mov al,[ta_tab+bx]
    mov bl,[rad_map+si]
    add al,[tr_tab+bx]
    mov ah,al
    stosw
    mov [es:di+318],ax
    inc si
    dec cx
    jnz .px
    add di,320
    dec dx
    jnz .row
    ret

; fieldS: value = sin165[ta_tab[angle] + tr_tab[radius]]
fieldS:
    xor si,si
    xor di,di
    xor bh,bh
    mov dx,100
.row:
    mov cx,160
.px:
    mov bl,[ang_map+si]
    mov al,[ta_tab+bx]
    mov bl,[rad_map+si]
    add al,[tr_tab+bx]
    mov bl,al
    mov al,[sin165+bx]
    mov ah,al
    stosw
    mov [es:di+318],ax
    inc si
    dec cx
    jnz .px
    add di,320
    dec dx
    jnz .row
    ret

; ----- one-time setup (called from start) -----

; sin56[i]  = 0..55   (a sine, offset to be non-negative)
; sin165[i] = 42..205 (the same wave stretched over the palette, +42)
; ident[i]  = i
build_tabs:
    xor si,si
.bt:
    movsx ax,byte [sintab+si]
    add ax,127
    mov bx,ax
    imul ax,56
    shr ax,8
    mov [sin56+si],al
    imul bx,165
    shr bx,8
    add bl,FIXED_PAL_COUNT+1
    mov [sin165+si],bl
    mov ax,si
    mov [ident+si],al
    inc si
    cmp si,256
    jb .bt
    ret

; integer square root: AX = floor(sqrt(AX)) (AX treated as unsigned)
isqrt:
    push bx
    push cx
    push dx
    mov bx,ax                     ; n
    xor ax,ax                     ; result
    mov cx,4000h                  ; highest power of four
.a:
    cmp cx,bx
    jbe .b
    shr cx,2
    jmp .a
.b:
    test cx,cx
    jz .done
    mov dx,ax
    add dx,cx
    cmp bx,dx
    jb .lt
    sub bx,dx
    shr ax,1
    add ax,cx
    jmp .nx
.lt:
    shr ax,1
.nx:
    shr cx,2
    jmp .b
.done:
    pop dx
    pop cx
    pop bx
    ret

; Polar maps for the 160x100 block grid, centre (80,50):
;   rad_map = floor(sqrt(6*(dx^2+dy^2)))   (0..231, a screen-filling radius)
;   ang_map = angle in 1/256 turns
; Both are computed once; the angle uses a 65-entry atan table on the ratio of
; the smaller to the larger coordinate and folds it into the right octant.
build_maps:
    xor di,di
    mov word [bm_y],-50
.y:
    mov word [bm_x],-80
.x:
    mov ax,[bm_x]
    imul ax,ax
    mov bx,[bm_y]
    imul bx,bx
    add ax,bx
    imul ax,6
    call isqrt
    mov [rad_map+di],al
    mov ax,[bm_x]
    cwd
    xor ax,dx
    sub ax,dx                     ; |x|
    mov bx,[bm_y]
    mov dx,bx
    sar dx,15
    xor bx,dx
    sub bx,dx                     ; |y|
    xor cx,cx                     ; cx = 1 if the angle is steeper than 45 degrees
    cmp bx,ax
    jbe .ns
    xchg ax,bx
    inc cx
.ns:
    test ax,ax
    jz .a0
    shl bx,6
    xchg ax,bx                    ; ax = minor*64, bx = major
    xor dx,dx
    div bx                        ; ax = ratio 0..64
    mov bx,ax
    movzx ax,byte [atan_tab+bx]
    test cx,cx
    jz .ns2
    neg ax
    add ax,64
.ns2:
    cmp word [bm_x],0
    jge .xp
    neg ax
    add ax,128
.xp:
    cmp word [bm_y],0
    jge .yp
    neg ax
.yp:
    mov [ang_map+di],al
    jmp .st
.a0:
    mov byte [ang_map+di],0
.st:
    inc di
    inc word [bm_x]
    cmp word [bm_x],80
    jl .x
    inc word [bm_y]
    cmp word [bm_y],50
    jl .y
    ret

wait_vsync:
    mov dx,3DAh
.w0: in al,dx
    test al,8
    jnz .w0
.w1: in al,dx
    test al,8
    jz .w1
    ret

; Palette morphing: scene number changes channel relationships, frame changes phase.
palette_tick:
    ; Scene-local triangular brightness envelope.  The first/last 32 frames
    ; fade through black, hiding the hard procedural scene switch cheaply.
    mov ax,bp
    and ax,511
    cmp ax,32
    jb .fade_in
    cmp ax,480
    jae .fade_out
    mov byte [pal_limit],63
    jmp .pal_begin
.fade_in:
    shl ax,1
    mov [pal_limit],al
    jmp .pal_begin
.fade_out:
    mov bx,512
    sub bx,ax
    shl bx,1
    mov [pal_limit],bl
.pal_begin:
    xor al,al                     ; beat flash: scene art lifts by beat>>3 after a
    cmp byte [pal_limit],63       ; kick, but never while the scene is fading
    jne .nb
    mov al,[beat]
    shr al,3
.nb:
    mov [beat_boost],al
    ; Fixed entries go FIRST: they are all the 3D scenes use, and these ~125
    ; port writes fit inside the vertical blank we are called in. The long
    ; animated sweep (~640 writes) used to run first and spilled into the visible
    ; frame, so the DAC changed mid-screen (a hard horizontal palette tear).
    ; Fixed-colour entries (UI colours, the face-shading ramp, the sky gradient,
    ; star shades) are rewritten here every frame, overriding whatever the
    ; animated loop above just gave those indices, so they never drift. Entries
    ; flagged 1 are scene art and follow the scene fade (clamped to pal_limit like
    ; the animated colours, so a scene fades in/out as a whole); flag 0 is UI
    ; (scroller, outlines) and stays at full brightness through the fade.
    mov si,fixed_pal
    mov cx,FIXED_PAL_COUNT
.fp:
    mov dx,3C8h
    lodsb
    out dx,al                    ; select index
    inc dx                       ; dx = 3C9h
    lodsb
    mov bl,al                    ; bl = fade flag
    lodsb
    call .fpout
    lodsb
    call .fpout
    lodsb
    call .fpout
    loop .fp
    mov al,[cur_scene]           ; 3D scenes (15, 16) need only the fixed
    sub al,15                    ; entries: skip the sweep entirely
    cmp al,2
    jb .done
    ; The sweep is spread over four frames (a 64-index block per frame, chosen
    ; by bp) so each frame's DAC traffic still fits vertical blank; the colours
    ; only drift one step per frame, so a block that is up to 3 frames stale is
    ; invisible. While a scene fades the whole range is rewritten instead, since
    ; stale blocks would show as brightness steps (the screen is dark then).
    mov byte [sweep_mask],255
    cmp byte [pal_limit],63
    jne .sw_full
    mov byte [sweep_mask],63
    mov ax,bp
    and al,3
    mov cl,6
    shl al,cl                    ; AL = first index of this frame's block
    jnz .sw_go
.sw_full:
    mov al,FIXED_PAL_COUNT+1     ; block 0 / full sweep start after the fixed entries
.sw_go:
    mov cl,al
    mov dx,3C8h
    out dx,al
    inc dx
    xor ch,ch                    ; CX = palette index
.pt:
    mov ax,cx
    add ax,bp
    mov bx,bp
    shr bx,11                    ; act/scene family drives palette identity
    shl bx,2
    add ax,bx
    and al,63
    call .limit
    out dx,al

    mov ax,cx
    shr al,1
    add ax,bp
    mov bx,bp
    shr bx,SCENE_SHIFT
    xor ax,bx
    and al,63
    call .limit
    out dx,al

    mov ax,cx
    not al
    add ax,bp
    mov bx,bp
    shr bx,SCENE_SHIFT-2
    add ax,bx
    and al,63
    call .limit
    out dx,al

    inc cl
    test cl,[sweep_mask]
    jnz .pt
.done:
    ret
.fpout:
    test bl,bl
    jz .fo_emit
    mov ah,[pal_limit]            ; fade by SCALING (v * (limit+1) / 64), not by
    inc ah                        ; clamping each component: a clamp turns e.g.
    mul ah                        ; (20,8,28) into (16,8,16) and shifts the hue
    shr ax,6                      ; (the maroon sky seen mid-fade); scaling just
    add al,[beat_boost]           ; darkens it. Exact (v) when limit = 63 and no
    cmp al,63                     ; beat. Scene art also brightens on each kick
    jbe .fo_emit                  ; (beat_boost 0..3), clamped to the 6-bit DAC.
    mov al,63
.fo_emit:
    out dx,al
    ret
.limit:
    cmp al,[pal_limit]
    jbe .ok
    mov al,[pal_limit]
.ok: ret

; Bottom sine-wave text scroller. Column-major: for each of the 320 screen
; columns, finds which glyph column it currently shows (scrollpos + x, into
; the precomputed scroll_msg glyph-index strip), looks the glyph bitmap up
; in font_data, and stamps its 8 rows with a per-column sine-table vertical
; offset for the classic wavy-scroller look. Advances scrollpos afterward.
scroll_draw:
    pusha
    mov word [scroll_x],0
.col:
    mov cx,[scroll_x]
    mov ax,[scrollpos]
    add ax,cx
    cmp ax,SCROLL_MSG_LEN*8
    jb .nowrap
    sub ax,SCROLL_MSG_LEN*8
.nowrap:
    mov bx,ax
    shr bx,3                       ; bx = character index
    and ax,7                       ; ax = bit index within glyph (0..7)
    mov dx,ax
    mov al,[scroll_msg+bx]
    push ax                        ; save glyph index (bx is about to change)
    mov ax,bp
    shr ax,4
    add ax,bx                      ; colour cycles both along the message
    and ax,3                       ; and over time, for a travelling-rainbow
    add ax,4                       ; look. Indices 4..7: see palette_tick.
    mov [scroll_fg_now],al
    pop ax
    xor ah,ah
    shl ax,3                       ; ax = glyph_index*8 = font_data offset
    mov si,ax
    add si,font_data
    mov cx,dx                      ; cx = bit index -> shift count
    mov bl,80h
    shr bl,cl                      ; bl = this column's bit mask in a glyph row
    mov ax,bp
    add ax,[scroll_x]
    and ax,255
    mov di,ax
    movsx ax,byte [sintab+di]
    sar ax,5                       ; wave amplitude ~ -4..4 px (table is x127)
    add ax,SCROLL_BASE_Y
    mov dx,ax                      ; dx = this column's base Y
    ; Direct stores instead of put_pixel (the column's rows are always on screen:
    ; baseline 182 +-4, 8 rows): di = y*320 + x, then +320 per glyph row. Each lit
    ; pixel gets a black drop shadow down-right, stored first so the glyph colour
    ; lands on top of it; only lit pixels are drawn, so the sky shows through.
    mov ax,dx
    shl ax,6
    mov di,ax
    shl ax,2
    add di,ax                      ; dx*64 + dx*256 = dx*320
    add di,[scroll_x]
    mov bh,[scroll_fg_now]
    mov cx,8
.row:
    mov al,[si]
    inc si
    test al,bl
    jz .rownext
    mov byte [es:di+321],SCROLL_BG
    mov [es:di],bh
.rownext:
    add di,320
    dec cx
    jnz .row
    mov ax,[scroll_x]
    inc ax
    mov [scroll_x],ax
    cmp ax,320
    jb .col
    ; advance one pixel EVERY frame (70 px/s). It used to move every other frame
    ; (35 px/s), which judders against a 70 Hz display.
    mov ax,[scrollpos]
    inc ax
    cmp ax,SCROLL_MSG_LEN*8
    jb .advstore
    xor ax,ax
.advstore:
    mov [scrollpos],ax
    popa
    ret

; AX = angle in 16 bits (65536 = one full turn). Returns AX = sin, DX = cos,
; scaled +-127, LINEARLY INTERPOLATED between the 256 table entries. Rotation
; used to index the table directly at half a step per frame, so a pose only
; changed every second frame (a visible 35 Hz judder on a 70 Hz display) and
; vertices snapped to a coarse grid; interpolating makes the motion continuous
; at any speed.
sincos16:
    push bx
    push cx
    push si
    mov si,ax
    call sin16
    push ax
    mov ax,si
    add ax,4000h                  ; cos(a) = sin(a + quarter turn)
    call sin16
    mov dx,ax
    pop ax
    pop si
    pop cx
    pop bx
    ret
sin16:
    mov bx,ax
    mov cl,8
    shr bx,cl                     ; bx = table index 0..255
    mov cx,ax
    and cx,0FFh                   ; cx = fraction 0..255 between entries
    movsx ax,byte [sintab+bx]     ; s0
    inc bl                        ; next entry (bh=0, so bl wraps 255 -> 0)
    movsx bx,byte [sintab+bx]     ; s1
    sub bx,ax
    imul bx,cx                    ; (s1-s0)*frac: |s1-s0|<=4 so this is tiny
    add bx,80h                    ; round to nearest instead of truncating:
    sar bx,8                      ; halves the worst-case error (1.5 -> 1.0)
    add ax,bx
    ret

; Rotate one 3D point (cube_px,cube_py,cube_pz) by cube_angle_y (around the
; Y axis) then cube_angle_x (around the X axis), using the shared sintab
; (cos(a) = sin((a+64)&255), a quarter-turn ahead in the same table), then
; project it in perspective to screen space in (cube_sx,cube_sy).
cube_rotate_project:
    pusha
    mov ax,[cube_angle_y]
    call sincos16
    mov [cube_t1],ax                ; sinY
    mov [cube_t2],dx                ; cosY

    mov ax,[cube_px]
    imul ax,[cube_t2]
    mov bx,ax
    mov ax,[cube_pz]
    imul ax,[cube_t1]
    sub bx,ax
    sar bx,7                        ; undo the x127 table scale
    mov [cube_rx],bx                ; x*cosY - z*sinY

    mov ax,[cube_px]
    imul ax,[cube_t1]
    mov bx,ax
    mov ax,[cube_pz]
    imul ax,[cube_t2]
    add bx,ax
    sar bx,7                        ; undo the x127 table scale
    mov [cube_rz],bx                ; x*sinY + z*cosY

    mov ax,[cube_py]
    mov [cube_ry],ax

    mov ax,[cube_angle_x]
    call sincos16
    mov [cube_t1],ax                ; sinX
    mov [cube_t2],dx                ; cosX

    mov ax,[cube_ry]
    imul ax,[cube_t2]
    mov bx,ax
    mov ax,[cube_rz]
    imul ax,[cube_t1]
    sub bx,ax
    sar bx,7                        ; undo the x127 table scale
    mov [cube_ry2],bx                ; y*cosX - z*sinX

    mov ax,[cube_ry]
    imul ax,[cube_t1]
    mov bx,ax
    mov ax,[cube_rz]
    imul ax,[cube_t2]
    add bx,ax
    sar bx,7                        ; undo the x127 table scale
    mov [cube_rz2],bx                ; y*sinX + z*cosX (final depth)

    ; True perspective projection (not orthographic): divide by distance
    ; from the eye, so edges nearer the viewer project larger. cube_rz2
    ; SHOULD stay within roughly +-70 (it can't exceed the original
    ; vertex's vector length under exact rotation), but this is fixed-point
    ; integer math, not exact matrix rotation -- clamp the divisor to a
    ; safe minimum regardless, so IDIV can never be handed a near-zero (or
    ; negative) denominator. A too-small divisor here was observed to blow
    ; up the projected coordinate into a huge value, which produced a
    ; degenerate line draw_line could take a very long time to walk.
    mov ax,[cube_rz2]
    add ax,CUBE_EYE_DIST
    cmp ax,40
    jge .depth_ok
    mov ax,40
.depth_ok:
    mov [cube_depth],ax
    mov ax,[cube_rx]
    imul ax,CUBE_PROJ_SCALE
    cwd
    idiv word [cube_depth]
    add ax,160
    call .clamp_sx
    mov [cube_sx],ax
    mov ax,[cube_ry2]
    imul ax,CUBE_PROJ_SCALE
    cwd
    idiv word [cube_depth]
    add ax,100
    call .clamp_sy
    mov [cube_sy],ax
    popa
    ret
    ; Defensive belt-and-suspenders clamp: even with the depth clamp above,
    ; keep the final screen coordinate within a generous but bounded range
    ; so draw_line's Bresenham walk can never be handed an extreme endpoint.
.clamp_sx:
    cmp ax,-2000
    jge .csx_lo_ok
    mov ax,-2000
.csx_lo_ok:
    cmp ax,2320
    jle .csx_hi_ok
    mov ax,2320
.csx_hi_ok:
    ret
.clamp_sy:
    cmp ax,-2000
    jge .csy_lo_ok
    mov ax,-2000
.csy_lo_ok:
    cmp ax,2200
    jle .csy_hi_ok
    mov ax,2200
.csy_hi_ok:
    ret

; Night-sky gradient fill of the whole page (ES:0): 16 shades of the fixed sky
; ramp, 13 rows each, dark at the top to dusky blue at the horizon. The 3D scenes
; used to clear to flat black.
fill_sky:
    push ax
    push bx
    push cx
    push dx
    push di
    xor di,di
    mov dl,SKY_BASE
    mov dh,13
    mov bx,200
.fs_row:
    mov al,dl
    mov ah,al
    mov cx,160
    rep stosw
    dec dh
    jnz .fs_same
    mov dh,13
    cmp dl,SKY_BASE+15
    jae .fs_same
    inc dl
.fs_same:
    dec bx
    jnz .fs_row
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; BX = x, AX = y (signed), DL = colour: clipped single-pixel plot into the page
; at ES. Preserves every register.
put_pixel:
    push ax
    push cx
    push di
    cmp ax,0
    jl .pp_done
    cmp ax,199
    jg .pp_done
    cmp bx,0
    jl .pp_done
    cmp bx,319
    jg .pp_done
    push dx
    mov cx,320
    mul cx
    pop dx
    add ax,bx
    mov di,ax
    mov [es:di],dl
.pp_done:
    pop di
    pop cx
    pop ax
    ret

; Small solid core spinning inside a wireframe object (counter-rotating, drawn
; BEFORE the wireframe so the edges stay on top). The caller's per-object
; parameters are fully reloaded afterwards, so these only touch obj_* state.
draw_core_octa:
    mov byte [obj_solid],1
    mov cl,5
    mov ax,bp
    shl ax,cl
    neg ax
    mov [cube_angle_y],ax
    mov cl,6
    mov ax,bp
    shl ax,cl
    mov [cube_angle_x],ax
    mov word [obj_verts_ptr],core_octa_verts
    mov word [obj_edges_ptr],octa_edges
    mov word [obj_faces_ptr],octa_faces
    mov word [obj_vbytes],6*6
    mov word [obj_ebytes],12*2
    mov word [obj_fbytes],8*4
    mov dword [obj_norml],13967
    mov word [obj_offset_x],-70
    mov word [obj_offset_y],0
    mov byte [obj_fg],CUBE_FG
    mov byte [obj_fg_dim],CUBE_FG_DIM
    call render_object
    mov byte [obj_solid],0
    ret

draw_core_cube:
    mov byte [obj_solid],1
    mov cl,6
    mov ax,bp
    shl ax,cl
    neg ax
    mov [cube_angle_y],ax
    mov cl,5
    mov ax,bp
    shl ax,cl
    mov [cube_angle_x],ax
    mov word [obj_verts_ptr],core_cube_verts
    mov word [obj_edges_ptr],cube_edges
    mov word [obj_faces_ptr],cube_faces
    mov word [obj_vbytes],8*6
    mov word [obj_ebytes],12*2
    mov word [obj_fbytes],6*4
    mov dword [obj_norml],8064
    mov word [obj_offset_x],70
    mov word [obj_offset_y],0
    mov byte [obj_fg],CUBE_FG
    mov byte [obj_fg_dim],CUBE_FG_DIM
    call render_object
    mov byte [obj_solid],0
    ret

; Reflect the current star (star_sx/star_sy) off a round force-field of radius
; DX centred at (BX,100): a star that has penetrated the field by some depth is
; mirrored to that same distance outside it, so it appears to bounce. Distance
; is the cheap octagonal metric max+min/2 (within ~8% of a circle). Sets
; star_hit when it deflects, so the star can flash.
star_bounce:
    push ax
    push cx
    push dx
    push si
    push di
    mov [bnc_r],dx
    mov [bnc_c],bx
    mov ax,[star_sx]
    sub ax,bx
    mov di,ax                      ; di = dx from centre
    mov ax,[star_sy]
    sub ax,100
    mov si,ax                      ; si = dy from centre
    mov ax,di
    cwd
    xor ax,dx
    sub ax,dx                      ; |dx|
    mov cx,si
    mov dx,cx
    sar dx,15
    xor cx,dx
    sub cx,dx                      ; |dy|
    cmp ax,cx
    jge .sb_ord
    xchg ax,cx
.sb_ord:
    shr cx,1
    add ax,cx                      ; ax = m
    jz .sb_done
    cmp ax,[bnc_r]
    jge .sb_done
    mov [bnc_m],ax
    mov cx,[bnc_r]
    shl cx,1
    sub cx,ax
    mov [bnc_f],cx                 ; mirrored distance 2R - m
    mov ax,di
    imul word [bnc_f]
    idiv word [bnc_m]
    add ax,[bnc_c]
    mov [star_sx],ax
    mov ax,si
    imul word [bnc_f]
    idiv word [bnc_m]
    add ax,100
    mov [star_sy],ax
    mov byte [star_hit],1
.sb_done:
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; 3D starfield pass (no clear, so it can sit behind other scenes). 32 stars, each
; with a genuine Z computed fresh from the frame clock; shade steps with depth in
; four levels and the nearest stars are drawn 2x2, so they read as closer rather
; than just brighter.
star_pass:
    pusha
    mov word [star_idx],0
    xor si,si
.st_loop:
    mov ax,[star_phase]
    mov cx,[star_idx]
    imul cx,37
    add ax,cx
    xor dx,dx
    mov cx,240
    div cx
    mov ax,255
    sub ax,dx
    mov [star_z],ax

    mov ax,[star_base_x+si]
    mov cx,STAR_SCALE
    imul ax,cx
    cwd
    idiv word [star_z]
    add ax,160
    mov [star_sx],ax
    mov ax,[star_base_y+si]
    mov cx,STAR_SCALE
    imul ax,cx
    cwd
    idiv word [star_z]
    add ax,100
    mov [star_sy],ax
    mov byte [star_hit],0
    cmp byte [bounce_on],0
    je .st_nb
    mov bx,90                      ; cube field (centre x = 160-70)
    mov dx,56
    call star_bounce
    mov bx,230                     ; octahedron field (centre x = 160+70)
    mov dx,36
    call star_bounce
.st_nb:

    mov ax,[star_z]
    mov dl,CUBE_FG_DIM
    cmp ax,192
    jge .st_col
    mov dl,STAR_MID
    cmp ax,128
    jge .st_col
    mov dl,CUBE_FG
    cmp ax,64
    jge .st_col
    mov dl,STAR_NEAR
.st_col:
    cmp byte [star_hit],0
    je .st_nohit
    mov dl,STAR_NEAR               ; a star that just bounced flashes warm white
.st_nohit:
    mov bx,[star_sx]
    mov ax,[star_sy]
    call put_pixel
    cmp byte [star_hit],0
    jne .st_big
    cmp word [star_z],64
    jge .st_trail
.st_big:
    inc bx
    call put_pixel
    inc ax
    call put_pixel
    dec bx
    call put_pixel
.st_trail:
    cmp word [star_z],150          ; closer stars drag a short dim trail back
    jge .st_next                   ; towards the vanishing point (motion streak)
    mov ax,[star_sx]
    sub ax,160
    cwd
    mov cx,5
    idiv cx
    mov bx,[star_sx]
    sub bx,ax
    mov ax,[star_sy]
    sub ax,100
    cwd
    idiv cx
    neg ax
    add ax,[star_sy]
    mov dl,CUBE_FG_DIM
    call put_pixel
.st_next:
    add si,2
    mov ax,[star_idx]
    inc ax
    mov [star_idx],ax
    cmp ax,STAR_COUNT
    jb .st_loop
    mov al,[beat]                 ; the stars fly by at 3 depth units a frame,
    shr al,2                      ; surging by up to 7 more right after a kick
    xor ah,ah
    add ax,3
    add ax,[star_phase]
    cmp ax,240
    jb .ph_ok
    sub ax,240
.ph_ok:
    mov [star_phase],ax
    popa
    ret

; Scanline-fill the convex polygon in pv_x/pv_y (4 vertices; a triangle repeats
; its last) with poly_color. Every edge is walked once in 8.8 fixed point,
; recording the leftmost/rightmost x it reaches on each row; the spans are then
; filled with REP STOSB. Rows and columns are clipped to the page.
fill_poly:
    pusha
    mov ax,[pv_y]
    mov bx,ax                     ; bx = ymin
    mov dx,ax                     ; dx = ymax
    mov si,2
.fp_ext:
    mov ax,[pv_y+si]
    cmp ax,bx
    jge .fp_nomin
    mov bx,ax
.fp_nomin:
    cmp ax,dx
    jle .fp_nomax
    mov dx,ax
.fp_nomax:
    add si,2
    cmp si,8
    jb .fp_ext
    cmp dx,0
    jl .fp_done
    cmp bx,199
    jg .fp_done
    cmp bx,0
    jge .fp_c1
    xor bx,bx
.fp_c1:
    cmp dx,199
    jle .fp_c2
    mov dx,199
.fp_c2:
    mov [pf_ymin],bx
    mov [pf_ymax],dx
    mov ax,dx                     ; end of the row range, as a word index
    shl ax,1                      ; (16-bit on purpose: the upper half of EDX
    add ax,2                      ; holds leftovers from earlier 32-bit math)
    mov [pf_end],ax
    mov si,bx
    shl si,1
    mov cx,dx
    sub cx,bx
    inc cx
.fp_init:
    mov word [poly_min+si],7FFFh
    mov word [poly_max+si],8000h
    add si,2
    loop .fp_init

    xor si,si
.fp_edges:
    mov bx,si
    add bx,2
    and bx,7                      ; next vertex, wrapping after four
    mov ax,[pv_x+si]
    mov [ed_x0],ax
    mov ax,[pv_y+si]
    mov [ed_y0],ax
    mov ax,[pv_x+bx]
    mov [ed_x1],ax
    mov ax,[pv_y+bx]
    mov [ed_y1],ax
    call edge_rows
    add si,2
    cmp si,8
    jb .fp_edges

    mov ax,[pf_ymin]
    mov cx,320
    mul cx
    mov [pf_rowbase],ax
    mov si,[pf_ymin]
    shl si,1
.fp_rows:
    mov ax,[poly_min+si]
    mov bx,[poly_max+si]
    cmp ax,bx
    jg .fp_skip
    cmp bx,0
    jl .fp_skip
    cmp ax,319
    jg .fp_skip
    cmp ax,0
    jge .fp_l
    xor ax,ax
.fp_l:
    cmp bx,319
    jle .fp_r
    mov bx,319
.fp_r:
    mov cx,bx
    sub cx,ax
    inc cx
    mov di,[pf_rowbase]
    add di,ax
    mov al,[poly_color]
    rep stosb
.fp_skip:
    add word [pf_rowbase],320
    add si,2
    cmp si,[pf_end]
    jb .fp_rows
.fp_done:
    popa
    ret

; Walk one polygon edge (ed_x0,ed_y0)-(ed_x1,ed_y1) top to bottom in 8.8 fixed
; point, widening poly_min/poly_max on every row it crosses inside the clipped
; row range.
edge_rows:
    pusha
    mov ax,[ed_y0]
    cmp ax,[ed_y1]
    je .er_flat
    jl .er_ordered
    xchg ax,[ed_y1]               ; make y0 < y1 by swapping the endpoints
    mov [ed_y0],ax
    mov ax,[ed_x0]
    xchg ax,[ed_x1]
    mov [ed_x0],ax
.er_ordered:
    movsx eax,word [ed_x1]
    movsx edx,word [ed_x0]
    sub eax,edx
    shl eax,8
    movsx ecx,word [ed_y1]
    movsx edx,word [ed_y0]
    sub ecx,edx                   ; dy > 0
    cdq
    idiv ecx                      ; eax = dx/dy in 8.8
    mov [ed_slope],eax
    movsx ebx,word [ed_x0]
    shl ebx,8
    add ebx,80h                   ; start at the pixel centre
    mov si,[ed_y0]
.er_loop:
    cmp si,[pf_ymin]
    jl .er_next
    cmp si,[pf_ymax]
    jg .er_done
    mov eax,ebx
    sar eax,8
    push si
    shl si,1
    cmp ax,[poly_min+si]
    jge .er_nomin
    mov [poly_min+si],ax
.er_nomin:
    cmp ax,[poly_max+si]
    jle .er_nomax
    mov [poly_max+si],ax
.er_nomax:
    pop si
.er_next:
    add ebx,[ed_slope]
    inc si
    cmp si,[ed_y1]
    jle .er_loop
    jmp .er_done
.er_flat:
    mov si,[ed_y0]
    cmp si,[pf_ymin]
    jl .er_done
    cmp si,[pf_ymax]
    jg .er_done
    shl si,1
    mov ax,[ed_x0]
    call .er_upd
    mov ax,[ed_x1]
    call .er_upd
.er_done:
    popa
    ret
.er_upd:
    cmp ax,[poly_min+si]
    jge .eu_a
    mov [poly_min+si],ax
.eu_a:
    cmp ax,[poly_max+si]
    jle .eu_b
    mov [poly_max+si],ax
.eu_b:
    ret

; Solid pass for render_object: for every face compute its normal from the
; ROTATED vertices, cull it if it points away from the eye (perspective-correct
; test against the real eye position, not just the sign of normal-Z, or faces
; seen at a glancing angle would drop out), light it with one directional light,
; fill it with the matching step of the shading ramp, and outline it.
render_faces:
    pusha
    mov word [face_off],0
.rf_loop:
    mov si,[obj_faces_ptr]
    add si,[face_off]
    xor ah,ah
    mov al,[si]
    shl ax,1
    mov [fv0],ax
    mov al,[si+1]
    xor ah,ah
    shl ax,1
    mov [fv1],ax
    mov al,[si+2]
    xor ah,ah
    shl ax,1
    mov [fv2],ax
    mov al,[si+3]
    xor ah,ah
    shl ax,1
    mov [fv3],ax

    mov bx,[fv0]                  ; A
    mov di,[fv1]                  ; B
    mov si,[fv2]                  ; C
    mov ax,[rot_x+di]
    sub ax,[rot_x+bx]
    mov [fu_x],ax
    mov ax,[rot_y+di]
    sub ax,[rot_y+bx]
    mov [fu_y],ax
    mov ax,[proj_z+di]
    sub ax,[proj_z+bx]
    mov [fu_z],ax
    mov ax,[rot_x+si]
    sub ax,[rot_x+bx]
    mov [fv_x],ax
    mov ax,[rot_y+si]
    sub ax,[rot_y+bx]
    mov [fv_y],ax
    mov ax,[proj_z+si]
    sub ax,[proj_z+bx]
    mov [fv_z],ax

    mov ax,[fu_y]                 ; n = u x v
    imul ax,[fv_z]
    mov dx,[fu_z]
    imul dx,[fv_y]
    sub ax,dx
    mov [fc_nx],ax
    mov ax,[fu_z]
    imul ax,[fv_x]
    mov dx,[fu_x]
    imul dx,[fv_z]
    sub ax,dx
    mov [fc_ny],ax
    mov ax,[fu_x]
    imul ax,[fv_y]
    mov dx,[fu_y]
    imul dx,[fv_x]
    sub ax,dx
    mov [fc_nz],ax

    ; visible iff n . (A - eye) < 0, eye at (0,0,-CUBE_EYE_DIST); 32-bit since
    ; |n| ~ 6400 times coordinates ~ 60 overflows 16 bits
    movsx eax,word [fc_nx]
    movsx edx,word [rot_x+bx]
    imul eax,edx
    movsx ecx,word [fc_ny]
    movsx edx,word [rot_y+bx]
    imul ecx,edx
    add eax,ecx
    movsx ecx,word [fc_nz]
    movsx edx,word [proj_z+bx]
    add edx,CUBE_EYE_DIST
    imul ecx,edx
    add eax,ecx
    jge .rf_next                  ; facing away: skip

    movsx eax,word [fc_nx]        ; lighting: n . L / (|n||L|) -> 0..15
    imul eax,eax,LIGHT_X
    movsx edx,word [fc_ny]
    imul edx,edx,LIGHT_Y
    add eax,edx
    movsx edx,word [fc_nz]
    imul edx,edx,LIGHT_Z
    add eax,edx
    imul eax,eax,13               ; full-on light -> 13, +1 ambient = 14: the
    cdq                           ; brightest face stays one step darker than the
    idiv dword [obj_norml]        ; outline (step 15), so outlines never vanish
    add eax,1                     ; a little ambient so no face goes fully dark
    test eax,eax
    jge .rf_lo
    xor eax,eax
.rf_lo:
    cmp eax,15
    jle .rf_hi
    mov eax,15
.rf_hi:
    add al,SHADE_BASE
    mov [poly_color],al

    xor bx,bx                     ; copy the four screen-space vertices
.rf_pv:
    mov si,[fv0+bx]
    mov ax,[proj_x+si]
    mov [pv_x+bx],ax
    mov ax,[proj_y+si]
    mov [pv_y+bx],ax
    add bx,2
    cmp bx,8
    jb .rf_pv
    call fill_poly

    mov byte [line_color],SHADE_BASE+15   ; bright outline
    xor bx,bx
.rf_edge:
    mov si,bx
    add si,2
    and si,7
    mov ax,[pv_x+bx]
    mov [line_x0],ax
    mov ax,[pv_y+bx]
    mov [line_y0],ax
    mov ax,[pv_x+si]
    mov [line_x1],ax
    mov ax,[pv_y+si]
    mov [line_y1],ax
    call draw_line
    add bx,2
    cmp bx,8
    jb .rf_edge
.rf_next:
    add word [face_off],4
    mov ax,[face_off]
    cmp ax,[obj_fbytes]
    jb .rf_loop
    popa
    ret

; Generic wireframe-object renderer: projects every vertex of an arbitrary
; object (any vertex/edge list, up to 8 vertices) through cube_rotate_project
; -- so it uses whatever cube_angle_y/cube_angle_x the caller set -- offsets
; the result in screen space by (obj_offset_x,obj_offset_y) so more than one
; object can share the screen without colliding, then draws every edge with
; the same near/far depth-cued colouring as the original single-cube scene.
; This is what makes the engine support more than one hardcoded shape: the
; cube and the octahedron are both just data fed through this one routine.
render_object:
    pusha
    xor bx,bx
    xor si,si
.rv_loop:
    mov di,[obj_verts_ptr]
    add di,bx
    mov ax,[di]
    mov [cube_px],ax
    mov ax,[di+2]
    mov [cube_py],ax
    mov ax,[di+4]
    mov [cube_pz],ax
    call cube_rotate_project
    mov ax,[cube_sx]
    add ax,[obj_offset_x]
    mov [proj_x+si],ax
    mov ax,[cube_sy]
    add ax,[obj_offset_y]
    mov [proj_y+si],ax
    mov ax,[cube_rz2]
    mov [proj_z+si],ax
    mov ax,[cube_rx]
    mov [rot_x+si],ax
    mov ax,[cube_ry2]
    mov [rot_y+si],ax
    add bx,6
    add si,2
    cmp bx,[obj_vbytes]
    jb .rv_loop

    cmp byte [obj_solid],0
    je .ro_wire
    call render_faces
    popa
    ret
.ro_wire:

    xor si,si
.re_loop:
    mov di,[obj_edges_ptr]
    add di,si
    mov al,[di]
    xor ah,ah
    shl ax,1
    mov bx,ax
    mov ax,[proj_x+bx]
    mov [line_x0],ax
    mov ax,[proj_y+bx]
    mov [line_y0],ax
    mov ax,[proj_z+bx]
    mov dx,ax                      ; dx = vertex-0 depth
    mov di,[obj_edges_ptr]
    add di,si
    mov al,[di+1]
    xor ah,ah
    shl ax,1
    mov bx,ax
    mov ax,[proj_x+bx]
    mov [line_x1],ax
    mov ax,[proj_y+bx]
    mov [line_y1],ax
    add dx,[proj_z+bx]             ; dx = sum of both endpoints' depth
    mov al,[obj_fg]
    mov [line_color],al
    cmp dx,0                       ; average depth < 0 => nearer the eye
    jl .ro_near
    mov al,[obj_fg_dim]
    mov [line_color],al
.ro_near:
    call draw_line
    add si,2
    cmp si,[obj_ebytes]
    jb .re_loop
    popa
    ret

; General-purpose Bresenham line draw between (line_x0,line_y0) and
; (line_x1,line_y1) in line_color, with per-pixel bounds checks so an
; out-of-range projected point can never write outside the page.
draw_line:
    pusha
    mov ax,[line_x1]
    sub ax,[line_x0]
    mov word [line_sx],1
    cmp ax,0
    jge .no_negx
    neg ax
    mov word [line_sx],-1
.no_negx:
    mov [line_dx],ax

    mov ax,[line_y1]
    sub ax,[line_y0]
    mov word [line_sy],1
    cmp ax,0
    jge .no_negy
    neg ax
    mov word [line_sy],-1
.no_negy:
    neg ax
    mov [line_dy],ax                ; -abs(y1-y0)

    mov ax,[line_dx]
    add ax,[line_dy]
    mov [line_err],ax

    mov ax,[line_x0]
    mov [line_cx],ax
    mov ax,[line_y0]
    mov [line_cy],ax
.loop:
    mov ax,[line_cy]
    cmp ax,0
    jl .noplot
    cmp ax,199
    jg .noplot
    mov bx,[line_cx]
    cmp bx,0
    jl .noplot
    cmp bx,319
    jg .noplot
    mov cx,320
    mul cx
    add ax,bx
    mov di,ax
    mov al,[line_color]
    stosb
.noplot:
    mov ax,[line_cx]
    cmp ax,[line_x1]
    jne .step
    mov ax,[line_cy]
    cmp ax,[line_y1]
    jne .step
    jmp .done
.step:
    ; e2 must be computed ONCE from err and reused for BOTH the x-step and
    ; y-step conditions (the standard Zingl dx+dy algorithm). This used to
    ; recompute e2 from [line_err] a second time for the y-step check --
    ; after the x-step above may have already mutated line_err -- which
    ; could stop the walk from ever landing exactly on (x1,y1), the only
    ; condition .loop checks to terminate: a genuine infinite loop. bx
    ; holds e2 here and is never touched by the x-step block below, so it
    ; stays correct for the y-step's comparison too.
    mov ax,[line_err]
    mov bx,ax
    shl bx,1                       ; bx = e2 = 2*err, computed once
    cmp bx,[line_dy]
    jl .skipx
    mov ax,[line_err]
    add ax,[line_dy]
    mov [line_err],ax
    mov ax,[line_cx]
    add ax,[line_sx]
    mov [line_cx],ax
.skipx:
    cmp bx,[line_dx]               ; reuse the SAME e2 computed above
    jg .skipy
    mov ax,[line_err]
    add ax,[line_dx]
    mov [line_err],ax
    mov ax,[line_cy]
    add ax,[line_sy]
    mov [line_cy],ax
.skipy:
    jmp .loop
.done:
    popa
    ret

key_escape:
    in al,64h
    test al,1
    jz .no
    in al,60h
    cmp al,1
    je .yes
.no: clc
    ret
.yes: stc
    ret

; --- OPL2 FM synth driver (Sound Blaster / AdLib, port 388h/389h) ---
; The OPL2 chip is at a fixed I/O port on every SB card regardless of its
; base DSP address, so no BLASTER-variable detection is needed. Every write
; is index-then-data with the chip's required settle delays (a handful of
; dummy status-port reads; OPL2 doesn't need precise timing, just "long
; enough", so this avoids a hardware-specific wait-state calculation).

; Write AL to OPL2 register AH.
opl_write:
    push ax
    push bx
    push cx
    push dx
    mov bl,al                     ; stash the data byte (the wait loop
    mov dx,388h                   ; below clobbers al via "in al,dx")
    mov al,ah
    out dx,al
    mov cx,6
.w1: in al,dx
    loop .w1
    mov al,bl
    mov dx,389h
    out dx,al
    mov cx,35
.w2: in al,dx
    loop .w2
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; OPL2 channel -> operator register-offset map (standard chip layout: 18
; operators serve 9 two-operator channels, in three groups of 3 channels
; each 8 registers apart). opl_set_instrument and the note routines below
; use this so they work for any channel 0-8, not just a single hardcoded
; voice -- which is what lets this driver run a lead, a bass and a pad
; simultaneously instead of one monophonic channel.
chan_op1 db 0,1,2,8,9,10,16,17,18
chan_op2 db 3,4,5,11,12,13,19,20,21

; Program channel CL's two operators and feedback/connection from an
; 11-byte instrument patch at DS:SI: [mod char,level,AD,SR,wave, car
; char,level,AD,SR,wave, feedback/connection]. "char" packs EG-TYPE
; (sustain) in bit5 and multiple in bits0-3; "level" packs KSL/total
; level; "AD"/"SR" are attack-decay / sustain-release nibble pairs.
opl_set_instrument:
    push ax
    push bx
    push dx
    push si
    mov bl,cl
    xor bh,bh
    mov dl,[chan_op1+bx]           ; dl = modulator operator offset
    mov dh,[chan_op2+bx]           ; dh = carrier operator offset

    mov al,[si]
    mov ah,20h
    add ah,dl
    call opl_write
    mov al,[si+1]
    mov ah,40h
    add ah,dl
    call opl_write
    mov al,[si+2]
    mov ah,60h
    add ah,dl
    call opl_write
    mov al,[si+3]
    mov ah,80h
    add ah,dl
    call opl_write
    mov al,[si+4]
    mov ah,0E0h
    add ah,dl
    call opl_write

    mov al,[si+5]
    mov ah,20h
    add ah,dh
    call opl_write
    mov al,[si+6]
    mov ah,40h
    add ah,dh
    call opl_write
    mov al,[si+7]
    mov ah,60h
    add ah,dh
    call opl_write
    mov al,[si+8]
    mov ah,80h
    add ah,dh
    call opl_write
    mov al,[si+9]
    mov ah,0E0h
    add ah,dh
    call opl_write

    mov al,[si+10]
    mov ah,0C0h
    add ah,cl
    call opl_write

    pop si
    pop dx
    pop bx
    pop ax
    ret

; Key every channel off and clear the whole rhythm register. Used at init
; (the chip may still hold a previous program's notes) and at exit: a real
; Sound Blaster/AdLib keeps sounding whatever was last keyed on after we
; return to DOS, so leaving a voice on is audible long after the demo ends.
opl_silence:
    push ax
    push cx
    xor cl,cl
.os_loop:
    call opl_note_off
    inc cl
    cmp cl,9
    jb .os_loop
    mov ah,0BDh
    xor al,al
    call opl_write
    pop cx
    pop ax
    ret

; One-time setup: four independent melodic voices (lead/bass/pad, channels
; 0-2) plus the chip's built-in rhythm section (bass drum + snare, borrowed
; from channels 6-7) -- a real small arrangement instead of one monophonic
; beep, using as much of what the OPL2 actually offers as this driver
; reasonably can.
opl_init:
    call opl_silence
    mov ah,01h
    mov al,20h                    ; enable waveform select (registers 0..3)
    call opl_write

    mov cl,0
    mov si,inst_lead
    call opl_set_instrument
    mov cl,1
    mov si,inst_bass
    call opl_set_instrument
    mov cl,2
    mov si,inst_pad
    call opl_set_instrument
    mov cl,3
    mov si,inst_echo
    call opl_set_instrument
    mov cl,4
    mov si,inst_arp
    call opl_set_instrument
    mov cl,6
    mov si,inst_bd
    call opl_set_instrument
    mov cl,7
    mov si,inst_sd
    call opl_set_instrument
    mov cl,8                      ; tom (op 18) and cymbal (op 21) live here
    mov si,inst_sd
    call opl_set_instrument

    ; Rhythm-channel frequencies are set once via their own A/B registers;
    ; in rhythm mode the key-on bit normally in 0xB6/0xB7 is ignored, each
    ; drum instead triggered by its own bit in 0xBDh (see drum_tick).
    mov ah,0A6h
    mov al,44h                    ; bass drum pitch (~A1, deep thump)
    call opl_write
    mov ah,0B6h
    mov al,06h
    call opl_write
    mov ah,0A7h
    mov al,06h                    ; snare pitch (~D2, brighter than BD)
    call opl_write
    mov ah,0B7h
    mov al,07h
    call opl_write
    mov ah,0A8h
    mov al,06h                    ; tom pitch (~D3)
    call opl_write
    mov ah,0B8h
    mov al,0Ah
    call opl_write

    mov byte [opl_bd_base],20h    ; rhythm mode on, no extra AM/VIB depth
    mov ah,0BDh
    mov al,20h
    call opl_write
    ret

; AX = packed fnum/block (fnum in bits 0-9, block in bits 10-12; see the
; `notes` table comment), CL = channel (0-8) -- key that channel's note on.
opl_note_on:
    push ax
    push bx
    push cx
    mov bx,ax
    mov ah,0A0h
    add ah,cl
    mov al,bl                     ; fnum low 8 bits
    call opl_write
    mov ax,bx
    push cx                       ; shr needs CL=8, but CL holds the channel
    mov cl,8
    shr ax,cl
    pop cx                        ; channel is back in cl for the B-register
    and al,1Fh
    or al,20h                     ; key-on bit
    mov ah,0B0h
    add ah,cl
    call opl_write
    pop cx
    pop bx
    pop ax
    ret

; CL = channel (0-8) -- key that channel's note off.
opl_note_off:
    push ax
    mov ah,0B0h
    add ah,cl
    xor al,al                     ; key-on bit clear; block/fnum don't
    call opl_write                ; matter while silent
    pop ax
    ret

; 32-step A-minor-pentatonic phrase (a 16-step call, then a complementary
; 16-step response) with rests, update every 8 frames (~8.75 Hz at VGA
; 70 Hz). A 0 entry in `notes` is a rest: the channel is keyed off rather
; than retriggered, so the pattern has actual rhythm instead of one
; continuous drone. Transposed by show act (cur_scene/8, the same shared
; value main: already computed) by adding 0x400 per step to the packed
; note value -- block occupies bits 10-12, so this is exactly one octave
; up each time, regardless of the starting note.
; ---- Music: one shared step clock, five voices ------------------------------
; The song is a 4-bar chord progression (Am | C | G | Em) of 32 steps per bar, a
; step being 8 frames (~8.75 steps/s), so the whole form is ~15 s instead of the
; old identical 3.7 s loop. Every note stays inside A minor pentatonic, which fits
; all four chords, so melody and harmony can't clash. m_step is the global step
; (0..127); everything below derives from it, so the voices can't drift apart.
;
; Two phases per step: at bp%8 == 6 the lead/bass/echo keys go off and the drum
; bits clear (a brief silence so the next note has a real attack); at bp%8 == 0
; the step boundary fires every voice.
music_tick:
    mov al,[beat]                 ; the kick sets beat to 31; it decays 2 a frame
    sub al,2                      ; and drives the visual effects (screen shake,
    jnc .beat_ok                  ; palette flash, star surge, wave ripple)
    xor al,al
.beat_ok:
    mov [beat],al
    mov ax,bp
    and ax,7
    cmp ax,6
    je .mt_gap
    test ax,ax
    jnz .mt_done
    mov ax,bp
    mov cl,3
    shr ax,cl
    and ax,127
    mov [m_step],ax
    mov dl,[cur_scene]            ; act transposition: 0, 1 or 2 octaves up, as
    shr dl,3                      ; 0x400 per octave (the 3-bit block field sits
    cmp dl,2                      ; in bits 10-12 of the packed note)
    jbe .mt_tr
    mov dl,2
.mt_tr:
    xor dh,dh
    mov cl,10
    shl dx,cl
    mov [m_trans],dx
    call lead_step
    call bass_step
    call pad_step
    call echo_step
    call arp_step
    call drum_step
.mt_done:
    ret
.mt_gap:
    mov cl,0
    call opl_note_off
    mov cl,1
    call opl_note_off
    mov cl,3
    call opl_note_off
    mov cl,4
    call opl_note_off
    mov al,[opl_bd_base]
    mov ah,0BDh
    call opl_write
    ret

; LEAD (channel 0): four different 32-step phrases, one per chord, each landing
; on that chord's tones on the strong beats; the last ends on A to lead back
; into the first.
lead_step:
    mov si,[m_step]
    shl si,1
    mov ax,[lead_notes+si]
    test ax,ax
    jz .ls_rest
    add ax,[m_trans]
    mov cl,0
    call opl_note_on
    ret
.ls_rest:
    mov cl,0
    call opl_note_off
    ret

; BASS (channel 1): one rhythm pattern (root / octave / rest) played on each
; bar's chord root.
bass_step:
    mov bx,[m_step]
    and bx,31
    mov dl,[bass_pat+bx]
    test dl,dl
    jz .bs_rest
    mov ax,[m_step]
    mov cl,5
    shr ax,cl
    and ax,3                      ; bar 0..3
    shl ax,1
    mov si,ax
    mov ax,[bass_roots+si]
    cmp dl,2
    jne .bs_root
    add ax,400h                   ; octave up
.bs_root:
    add ax,[m_trans]
    mov cl,1
    call opl_note_on
    ret
.bs_rest:
    mov cl,1
    call opl_note_off
    ret

; PAD (channel 2): the chord's tones, one every 8 steps (4 per bar). Keyed off
; then on, so each change gets a real swell instead of just gliding.
pad_step:
    mov ax,[m_step]
    test al,7
    jnz .ps_done
    mov cl,3
    shr ax,cl
    and ax,15
    shl ax,1
    mov si,ax
    mov ax,[pad_chords+si]
    add ax,[m_trans]
    mov cl,2
    call opl_note_off
    call opl_note_on
.ps_done:
    ret

; ECHO (channel 3): the lead's note from two steps ago, replayed softer. Same
; octave as the lead on purpose: the packed note's 3-bit block field tops out at
; 7 and the lead's highest note (block 5) plus two act transpositions reaches it.
; Silent until the lead has played that note (the tick runs after inc bp, so
; step 0 is skipped once).
echo_step:
    cmp bp,24
    jb .es_rest
    mov si,[m_step]
    sub si,2
    and si,127
    shl si,1
    mov ax,[lead_notes+si]
    test ax,ax
    jz .es_rest
    add ax,[m_trans]
    mov cl,3
    call opl_note_on
    ret
.es_rest:
    mov cl,3
    call opl_note_off
    ret

; ARP (channel 4), from the second act on (scene 9 onwards): the bar's four
; chord tones plucked in a 16th-note arpeggio. It reuses the pad's chord table, so
; it can never leave the chord; the act transposition applies as for the others.
arp_step:
    cmp byte [cur_scene],8
    jb .ar_rest
    mov ax,[m_step]
    mov cl,5
    shr ax,cl
    and ax,3                      ; bar 0..3
    shl ax,3                      ; 4 words per bar
    mov si,ax
    mov bx,[m_step]
    and bx,3
    shl bx,1
    add si,bx
    mov ax,[pad_chords+si]
    add ax,[m_trans]
    mov cl,4
    call opl_note_on
    ret
.ar_rest:
    mov cl,4
    call opl_note_off
    ret

; RHYTHM: kick on the downbeat, snare on the backbeat, hi-hat on the off-beats;
; a tom+snare fill through the last 8 steps of bar 4; a cymbal crash on the first
; step of bar 1 to mark the top of the form. One 0BDh write per step.
drum_step:
    mov ax,[m_step]
    mov bx,ax
    and bx,7                      ; position within the beat group
    mov dx,ax
    and dx,31                     ; step within the bar
    mov cl,5
    shr ax,cl
    and ax,3                      ; bar
    mov cl,[opl_bd_base]
    cmp bx,0
    jne .dr_notbd
    or cl,10h                     ; bass drum
.dr_notbd:
    cmp bx,4
    jne .dr_notsd
    or cl,08h                     ; snare
.dr_notsd:
    cmp bx,2
    je .dr_hh
    cmp bx,6
    jne .dr_nohh
.dr_hh:
    or cl,01h                     ; hi-hat
.dr_nohh:
    test ax,ax
    jz .dr_no16                   ; bar 1 keeps plain eighth-note hats; later
    test bx,1                     ; bars add the off-beat sixteenths, so the
    jz .dr_no16                   ; groove builds across the form
    or cl,01h
.dr_no16:
    cmp ax,2
    jne .dr_nosync
    cmp dx,14
    jne .dr_nosync
    or cl,10h                     ; syncopated extra kick, bar 3
.dr_nosync:
    cmp byte [cur_scene],8        ; from the second act: a kick on steps 10 and 26
    jb .dr_noact                  ; of every bar too (a driving off-beat pattern)
    cmp dx,10
    je .dr_act
    cmp dx,26
    jne .dr_noact
.dr_act:
    or cl,10h
.dr_noact:
    cmp ax,3
    jne .dr_nofill
    cmp dx,24
    jb .dr_nofill
    or cl,0Ch                     ; fill: snare + tom every step
.dr_nofill:
    test ax,ax
    jnz .dr_write
    test dx,dx
    jnz .dr_write
    or cl,02h                     ; crash cymbal at the top of the form
.dr_write:
    test cl,10h
    jz .dr_nobeat
    mov byte [beat],31            ; a kick: start the visual beat envelope
.dr_nobeat:
    mov al,cl
    mov ah,0BDh
    call opl_write
    ret

; Lead phrases, 4 bars x 32 steps (0 = rest). Packed OPL2 fnum|block<<10 values,
; generated from the note names in the comments, not typed by hand.
lead_notes:
    ; bar 1: Am
    dw 0x1244,0x12b2,0x1365,0,0x1306,0x12b2,0x1244,0
    dw 0x1365,0,0x1306,0x12b2,0x1244,0,0x1205,0x1244
    dw 0x12b2,0,0x1365,0,0x1605,0x1365,0x1306,0
    dw 0x12b2,0x1306,0x12b2,0x1244,0x1205,0,0x1244,0
    ; bar 2: C
    dw 0x12b2,0x1365,0x1605,0,0x1365,0x1306,0x12b2,0
    dw 0x1605,0,0x1365,0x1306,0x12b2,0,0x1244,0x12b2
    dw 0x1306,0,0x1365,0,0x12b2,0x1306,0x1365,0
    dw 0x1205,0x1244,0x12b2,0x1306,0x12b2,0,0x1365,0
    ; bar 3: G
    dw 0x1306,0,0x1365,0x1306,0x1205,0,0x1244,0x1205
    dw 0x1306,0x1365,0x1306,0,0x12b2,0x1244,0x1205,0
    dw 0x1244,0,0x12b2,0x1306,0x1365,0,0x1306,0x12b2
    dw 0x1244,0x1205,0x1244,0,0x1205,0,0x1306,0
    ; bar 4: Em
    dw 0x1365,0,0x1605,0x1365,0x1306,0,0x12b2,0x1244
    dw 0x1365,0x1306,0x1365,0,0x1205,0x1244,0x12b2,0
    dw 0x1365,0,0x1306,0,0x12b2,0,0x1244,0
    dw 0x1205,0x1244,0x12b2,0x1306,0x1365,0,0,0x1244

; bass: 1 = chord root, 2 = root an octave up, 0 = rest (steps within a bar)
bass_pat db 1,0,0,1,0,0,2,0,1,0,0,1,0,2,0,1
         db 1,0,0,1,0,0,2,0,1,0,0,2,0,1,0,2
; bass roots per bar: A1 C2 G2 E2
bass_roots dw 0x0644,0x06b2,0x0a05,0x0765
; pad chord tones, 4 per bar (Am, C, G, Em), one every 8 steps
pad_chords dw 0x1244,0x12b2,0x1365,0x12b2
           dw 0x12b2,0x1365,0x1605,0x1365
           dw 0x1205,0x1306,0x1365,0x1306
           dw 0x0f65,0x1205,0x1365,0x1205
old_mode db 3
vga_page db 0                     ; which page we render into next
show_page db 0                    ; which page present: just flipped to
pal_limit db 63
pic_mask db 0
m_step dw 0                       ; global music step 0..127 (see music_tick)
beat db 0                         ; 31 on each kick, decays 2 a frame (visual sync)
beat_boost db 0                   ; palette lift (0..3) derived from beat, this frame
star_phase dw 0                   ; starfield depth phase, 0..239, surges on the beat
m_trans dw 0                      ; act transposition for this step, in packed-note units
cur_scene db 0                    ; current scene 0..17, advanced in present:;
                                   ; shared with scene_marker/music_tick so
                                   ; they can't drift out of sync with it

; --- OPL2 instrument patches: [mod char,level,AD,SR,wave, car same x5,
; feedback/connection] -- see opl_set_instrument ---
opl_bd_base db 0                  ; baseline 0BDh value (rhythm on, no hit)
inst_lead db 01h,16h,0F4h,74h,00h, 41h,00h,0F3h,65h,00h, 04h   ; FM, feedback 2, carrier vibrato
inst_bass db 01h,0Eh,0F2h,75h,00h, 01h,00h,0F2h,66h,01h, 02h   ; FM, half-sine carrier for bite
inst_echo db 01h,20h,0F2h,75h,00h, 01h,14h,0F2h,75h,00h, 04h   ; FM, softer than the lead
inst_pad  db 21h,2Ch,43h,66h,00h, 61h,12h,33h,35h,00h, 00h    ; sustained, low mod index, vibrato
inst_arp  db 01h,1Ah,0F8h,55h,00h, 01h,00h,0F8h,56h,00h, 06h   ; FM pluck: fast attack and decay
inst_bd   db 01h,00h,0F0h,55h,00h, 01h,00h,0F0h,55h,00h, 00h
inst_sd   db 0Dh,00h,0F0h,33h,02h, 0Dh,00h,0F0h,33h,02h, 00h

; --- bottom sine-wave text scroller state ---
scrollpos dw 0
scroll_x dw 0
scroll_fg_now db 4
raster_cy dw 0

; --- rotating wireframe cube scene state ---
cube_angle_y dw 0
cube_angle_x dw 0
cube_px dw 0
cube_py dw 0
cube_pz dw 0
cube_t1 dw 0
cube_t2 dw 0
cube_rx dw 0
cube_ry dw 0
cube_rz dw 0
cube_ry2 dw 0
cube_rz2 dw 0
cube_sx dw 0
cube_sy dw 0
cube_depth dw 0
proj_x times 8 dw 0
proj_y times 8 dw 0
proj_z times 8 dw 0                ; rotated Z per vertex (depth)
rot_x times 8 dw 0                 ; rotated X/Y per vertex, for face normals
rot_y times 8 dw 0

; --- generic multi-object renderer state (render_object) ---
obj_verts_ptr dw 0
obj_edges_ptr dw 0
obj_vbytes dw 0                   ; vertex count * 6
obj_ebytes dw 0                   ; edge count * 2
obj_offset_x dw 0                 ; screen-space translation for this object
obj_offset_y dw 0
obj_fg db 0
obj_fg_dim db 0
obj_solid db 0                    ; 1 = filled/shaded faces, 0 = wireframe
obj_faces_ptr dw 0
obj_fbytes dw 0                   ; face count * 4
obj_norml dd 0                    ; |normal|*|light| for this object

; --- face renderer / polygon fill working state ---
face_off dw 0
fv0 dw 0
fv1 dw 0
fv2 dw 0
fv3 dw 0
fu_x dw 0
fu_y dw 0
fu_z dw 0
fv_x dw 0
fv_y dw 0
fv_z dw 0
fc_nx dw 0
fc_ny dw 0
fc_nz dw 0
pv_x times 4 dw 0                 ; polygon vertices in screen space
pv_y times 4 dw 0
poly_color db 0
pf_ymin dw 0
pf_ymax dw 0
pf_end dw 0
pf_rowbase dw 0
ed_x0 dw 0
ed_y0 dw 0
ed_x1 dw 0
ed_y1 dw 0
ed_slope dd 0
poly_min times 200 dw 0           ; per-scanline left/right extent of the polygon
poly_max times 200 dw 0

; --- 3D starfield scene state ---
; --- field engine state and tables ---
ANG_MAP equ 4000h                 ; per-block angle map, 160*100 bytes
RAD_MAP equ 4000h+16000           ; per-block radius map
ang_map equ ANG_MAP
rad_map equ RAD_MAP
w_st1 dw 0
w_st2 dw 0
w_ry1 dw 0
w_ry2 dw 0
w_ry3 dw 0
w_p1 dw 0
w_p2 dw 0
w_p3 dw 0
wr1 dw 0
wr2 dw 0
wr3 dw 0
rowc db 0
row_end dw 0
fw_y dw 0
bm_x dw 0
bm_y dw 0
ta_tab times 256 db 0
tr_tab times 256 db 0
sin56 times 256 db 0
sin165 times 256 db 0
ident times 256 db 0
atan_tab db 0,1,1,2,3,3,4,4,5,6,6,7,8,8,9,9,10,11,11,12,12,13,13,14,15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,23,23,24,24,25,25,25,26,26,27,27,27,28,28,29,29,29,30,30,30,31,31,31,32,32
star_idx dw 0
sweep_mask db 255
star_hit db 0
bounce_on db 0
bnc_r dw 0
bnc_c dw 0
bnc_m dw 0
bnc_f dw 0
star_z dw 0
star_sx dw 0
star_sy dw 0
star_base_x dw -93,-10,-36,-98,129,66,-135,-39,108,-137,-49,129,-38,-8,-69,66
            dw -8,-40,-98,44,33,-15,85,-87,-110,0,35,-52,-115,-34,-110,-99
star_base_y dw -89,-33,-60,78,-73,-87,-72,-36,59,48,88,12,19,-94,83,-8
            dw -56,-9,-72,-71,-7,-84,42,1,46,65,52,85,-84,-21,-36,2

cube_verts: dw -40,-40,-40
            dw  40,-40,-40
            dw  40, 40,-40
            dw -40, 40,-40
            dw -40,-40, 40
            dw  40,-40, 40
            dw  40, 40, 40
            dw -40, 40, 40
cube_edges: db 0,1, 1,2, 2,3, 3,0, 4,5, 5,6, 6,7, 7,4, 0,4, 1,5, 2,6, 3,7

; Octahedron: one vertex out along each +/- axis; every vertex connects to
; every vertex on a DIFFERENT axis (12 edges), but never to its own
; opposite (that would cross through the centre, not an edge).
octa_verts: dw  35,  0,  0
            dw -35,  0,  0
            dw   0, 35,  0
            dw   0,-35,  0
            dw   0,  0, 35
            dw   0,  0,-35
core_cube_verts: dw -12,-12,-12
                 dw  12,-12,-12
                 dw  12, 12,-12
                 dw -12, 12,-12
                 dw -12,-12, 12
                 dw  12,-12, 12
                 dw  12, 12, 12
                 dw -12, 12, 12
core_octa_verts: dw  24,  0,  0
                 dw -24,  0,  0
                 dw   0, 24,  0
                 dw   0,-24,  0
                 dw   0,  0, 24
                 dw   0,  0,-24
octa_edges: db 0,2, 0,3, 0,4, 0,5, 1,2, 1,3, 1,4, 1,5, 2,4, 2,5, 3,4, 3,5


; Faces, 4 vertex indices each (triangles repeat their last vertex), wound so
; that (B-A)x(C-A) points OUTWARD -- generated and checked by script, because
; backface culling and lighting both depend on that orientation being right.
cube_faces:
    db 3,2,1,0
    db 4,5,6,7
    db 4,7,3,0
    db 1,2,6,5
    db 0,1,5,4
    db 7,6,2,3
octa_faces:
    db 0,2,4,4
    db 0,4,3,3
    db 0,3,5,5
    db 0,5,2,2
    db 1,4,2,2
    db 1,3,4,4
    db 1,5,3,3
    db 1,2,5,5
; |normal| * |light| per object: every face of a regular solid has the same
; normal length, so lighting divides by one constant instead of a square root.
cube_norml dd 89600
octa_norml dd 29705

fixed_pal:
    db 1,0,0,0,0
    db 2,0,63,63,63
    db 3,0,24,24,24
    db 4,0,63,0,0
    db 5,0,63,63,0
    db 6,0,0,50,0
    db 7,0,0,55,63
    db 8,1,7,9,24
    db 9,1,7,11,28
    db 10,1,8,14,31
    db 11,1,10,17,34
    db 12,1,12,20,37
    db 13,1,15,24,40
    db 14,1,18,27,42
    db 15,1,22,31,45
    db 16,1,26,35,47
    db 17,1,30,39,49
    db 18,1,35,42,52
    db 19,1,40,46,54
    db 20,1,45,50,56
    db 21,1,50,54,58
    db 22,1,56,58,60
    db 23,1,63,63,63
    db 24,1,0,0,4
    db 25,1,1,0,5
    db 26,1,2,1,7
    db 27,1,4,1,8
    db 28,1,5,2,10
    db 29,1,6,2,12
    db 30,1,8,3,13
    db 31,1,9,3,15
    db 32,1,10,4,16
    db 33,1,12,4,18
    db 34,1,13,5,20
    db 35,1,14,5,21
    db 36,1,16,6,23
    db 37,1,17,6,24
    db 38,1,18,7,26
    db 39,1,20,8,28
    db 40,1,44,44,50
    db 41,1,63,60,48
FIXED_PAL_COUNT equ 41

; --- general-purpose line-draw state (Bresenham, used by scene_cube) ---
line_x0 dw 0
line_y0 dw 0
line_x1 dw 0
line_y1 dw 0
line_cx dw 0
line_cy dw 0
line_dx dw 0
line_dy dw 0
line_sx dw 0
line_sy dw 0
line_err dw 0
line_color db 0

align 16
stack_bottom: times 256 db 0      ; our own small stack, kept by the SETBLOCK
stack_top:

; ---- font 5x7 bitmap, CHARSET order, 8 bytes/glyph (8th row blank) ----
; charset: ' ABCDEFGHIKLMNOPRSTUVWXY023456/,-'  (33 glyphs)
font_data:
    db 0,0,0,0,0,0,0,0,112,136,136,248,136,136,136,0,240,136,136,240
    db 136,136,240,0,120,128,128,128,128,128,120,0,240,136,136,136,136,136,240,0
    db 248,128,128,240,128,128,248,0,248,128,128,240,128,128,128,0,120,128,128,184
    db 136,136,120,0,136,136,136,248,136,136,136,0,248,32,32,32,32,32,248,0
    db 136,144,160,192,160,144,136,0,128,128,128,128,128,128,248,0,136,216,168,136
    db 136,136,136,0,136,200,168,152,136,136,136,0,112,136,136,136,136,136,112,0
    db 240,136,136,240,128,128,128,0,240,136,136,240,160,144,136,0,120,128,128,112
    db 8,8,240,0,248,32,32,32,32,32,32,0,136,136,136,136,136,136,112,0
    db 136,136,136,136,136,80,32,0,136,136,136,168,168,216,136,0,136,136,80,32
    db 80,136,136,0,136,136,80,32,32,32,32,0,112,136,152,168,200,136,112,0
    db 112,136,8,16,32,64,248,0,248,8,48,8,8,136,112,0,16,48,80,144
    db 248,16,16,0,248,128,240,8,8,136,112,0,112,128,128,240,136,136,112,0
    db 8,16,32,32,64,128,128,0,0,0,0,0,32,32,64,0,0,0,0,248
    db 0,0,0,0

; ---- scroller message, 147 glyph indices into font_data ----
scroll_msg:
    db 19,2,5,16,27,24,10,0,30,0,19,2,5,16,17,8,14,21,0,32
    db 0,1,0,6,19,11,11,23,0,15,16,14,3,5,4,19,16,1,11,0
    db 4,14,17,0,20,7,1,0,4,5,12,14,0,32,0,4,19,1,11,0
    db 26,4,0,17,8,1,15,5,0,5,13,7,9,13,5,0,32,0,17,14
    db 19,13,4,0,2,11,1,17,18,5,16,0,6,12,0,12,19,17,9,3
    db 0,32,0,13,14,0,1,17,17,5,18,17,31,0,13,14,0,5,22,3
    db 19,17,5,17,0,32,0,15,16,5,17,17,0,5,17,3,0,18,14,0
    db 5,22,9,18,0,32,0
SCROLL_MSG_LEN equ 147

; ---- sin table: 256 entries, sin(a)*127 as signed byte; cos(a) = sin(a + quarter turn) ----
sintab:
    db 0,3,6,9,12,16,19,22,25,28,31,34,37,40,43,46,49,51,54,57
    db 60,63,65,68,71,73,76,78,81,83,85,88,90,92,94,96,98,100,102,104
    db 106,107,109,111,112,113,115,116,117,118,120,121,122,122,123,124,125,125,126,126
    db 126,127,127,127,127,127,127,127,126,126,126,125,125,124,123,122,122,121,120,118
    db 117,116,115,113,112,111,109,107,106,104,102,100,98,96,94,92,90,88,85,83
    db 81,78,76,73,71,68,65,63,60,57,54,51,49,46,43,40,37,34,31,28
    db 25,22,19,16,12,9,6,3,0,253,250,247,244,240,237,234,231,228,225,222
    db 219,216,213,210,207,205,202,199,196,193,191,188,185,183,180,178,175,173,171,168
    db 166,164,162,160,158,156,154,152,150,149,147,145,144,143,141,140,139,138,136,135
    db 134,134,133,132,131,131,130,130,130,129,129,129,129,129,129,129,130,130,130,131
    db 131,132,133,134,134,135,136,138,139,140,141,143,144,145,147,149,150,152,154,156
    db 158,160,162,164,166,168,171,173,175,178,180,183,185,188,191,193,196,199,202,205
    db 207,210,213,216,219,222,225,228,231,234,237,240,244,247,250,253
