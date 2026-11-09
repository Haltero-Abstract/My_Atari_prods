;==============================================================
;  3DREAMS - ROTATING 3D OBJECTS + MUSICS MENU (formerly CUBEDSP)
;  ATARI FALCON 030 - based on CUBEMENU.S
;  VGA 320x200 16 colours (60 Hz) / True Color 320x240, triple buffering, XBIOS only
;  Transparent faces in planes 1-3 (additive colours), edges in plane 0
;
;  MUSIC : Amiga DSP replay of the MegaPlayer
;            by Simplet / FATAL DESIGN (Stephane Lesage)
;            files AMIGADSP.S + AMIGADSP.P56, included unchanged.
;            The DSP 56001 mixes the voices ; the 030 only handles
;            the score (Timer A) and sends the samples to the DSP.
;
;  On-screen menu (system 8x8 font via Line-A) :
;      + / -  volume          P  pause / resume
;      M      next module (ZIK\*.MOD and ZIK\*.ORG, alphabetical order) ;
;             .ORG = COSO player + music block by Jochen Hippel taken
;             from memory (e.g. PWRBOAT.ORG) : played on the YM2149 by
;             Timer A at 50 Hz, patched for the Falcon when loaded
;             at the end of a module, the next one starts by itself
;      O      next object among OBJ\*.OBJ (one file per object)
;      T      automatic object change : 10/20/30/60 s / off
;             auto mode : all objects in 16 colours, transparent
;             objects in True Color, solid objects in Gouraud,
;             Cel, Phong, Chrome, then Mapping (textured solids), and
;             again
;      V      16 colours <-> True Color 320x240
;  3D : computed by the DSP (3DREAMS.P56, loaded with the replay) :
;       rotation, projection and lighting of the vertices (all modes),
;       filling of the Gouraud / cel faces in True Color. The 030 only
;       takes these computations back if the DSP does not answer.
;      ESC    greetings page, 2nd ESC = quit (SPACE = back)
;  + saves / restores the video mode, the Falcon palette
;    and the sound system
;==============================================================

SCRSIZE     equ     32000

; DSP replay frequency (clock divider) :
;   1 = 49170 Hz  2 = 32780 Hz  3 = 24585 Hz  4 = 19668 Hz
; lower = fewer bytes to send to the DSP = more free CPU time
REPFREQ     equ     2

; Falcon VGA mode : STMODES | VERTFLAG | VGA | COL40 | BPS4
;   = 320x200, 4 interleaved planes like the ST, 60 Hz
VGAMODE     equ     $0080|$0100|$0010|$0000|$0002

TEXTCOL     equ     $777                ; menu white (colour 15)
AUTODEF     equ     10                  ; default object change (s)

WORKSZ      equ     20832               ; MegaPlayer work area (31*672)
MAXMODS     equ     64                  ; max modules in ZIK
NAMESZ      equ     14                  ; 8.3 name + 0 (rounded to even)
SIGN        equ     14                  ; words of the menu state
NSLOTS      equ     7                   ; cached text bands
COLS        equ     53                  ; text columns (6 pixels)
LINESZ      equ     56                  ; text of one line (multiple of 4)
BANDH       equ     6                   ; height of a band (6x6 font)
BANDB       equ     BANDH*160           ; bytes of a band
S_VALID     equ     2+LINESZ            ; "already in buf1/buf2/buf3" flags
S_IMG       equ     S_VALID+4           ; image of the band
BANDTC      equ     BANDH*640           ; bytes of a band in True Color
SLOTSZ      equ     S_IMG+BANDTC        ; y + text + valid + image (TC size)
BANDY0      equ     1                   ; screen lines of the bands
BANDY1      equ     8
BANDY2      equ     179
BANDY3      equ     186
BANDY4      equ     193

; rotation macro :  a' = a*cos - b*sin ;  b' = a*sin + b*cos
; \1 = register a, \2 = register b, \3 = sin variable, \4 = cos variable
rot         MACRO
            move.w  \1,d3
            muls    \4,d3
            move.w  \2,d4
            muls    \3,d4
            sub.l   d4,d3
            asl.l   #2,d3
            swap    d3              ; d3.w = (a*cos - b*sin) >> 14
            move.w  \1,d4
            muls    \3,d4
            move.w  \2,d5
            muls    \4,d5
            add.l   d5,d4
            asl.l   #2,d4
            swap    d4              ; d4.w = (a*sin + b*cos) >> 14
            move.w  d3,\1
            move.w  d4,\2
            ENDM

            section text

start:
            move.l  4(sp),a5            ; base page of the program
            lea     stackend,sp         ; our own stack

            ; --- give unused memory back to the system (Mshrink) ---
            move.l  12(a5),d0           ; TEXT length
            add.l   20(a5),d0           ; + DATA
            add.l   28(a5),d0           ; + BSS
            add.l   #$100,d0            ; + base page
            move.l  d0,-(sp)
            move.l  a5,-(sp)
            clr.w   -(sp)
            move.w  #$4a,-(sp)
            trap    #1
            lea     12(sp),sp

            ; --- welcome page : contents, credits, keys ---
            bsr     infopage
            tst.w   d0
            bpl.s   .demo
            bsr     hatquit             ; (in Hatari : closes it)
            clr.w   -(sp)               ; ESC : Pterm0
            trap    #1
.demo:
            ; --- the whole program runs in supervisor mode (DSP host port,
            ;     interrupts masked during the exchanges) ---
            clr.l   -(sp)               ; Super(0)
            move.w  #$20,-(sp)
            trap    #1
            addq.l  #6,sp
            move.l  d0,oldssp

            ; --- TOS 8x8 system font (Line-A) ---
            dc.w    $a000               ; Line-A init : a1 = font table
            move.l  (a1),a1             ; 1st font = 6x6
            move.w  36(a1),fontfirst    ; 1st character
            move.l  72(a1),fontoff      ; off_table (x of each character)
            move.l  76(a1),fontdat      ; dat_table
            move.w  80(a1),fontw        ; form_width (bytes per line)
            dc.w    $a00a               ; Line-A : hide the mouse

            ; --- list of the ZIK\*.MOD modules ---
            bsr     scanmods
            move.w  #-1,curmod
            move.w  #36,mastervol       ; master volume : 0 (mute) to 64 ; 36 at start
            move.w  #AUTODEF,autosec    ; next object every 10 s

            ; --- DSP : Simplet's replay program ---
            bsr     dspinit

            ; --- save the video state ---
            move.w  #-1,-(sp)           ; VsetMode(-1) : current Falcon mode
            move.w  #88,-(sp)
            trap    #14
            addq.l  #4,sp
            move.w  d0,oldmode

            move.w  #3,-(sp)            ; Logbase
            trap    #14
            addq.l  #2,sp
            move.l  d0,oldlog

            move.w  #2,-(sp)            ; Physbase
            trap    #14
            addq.l  #2,sp
            move.l  d0,oldphys

            ; --- save the Falcon palette (256 entries) ---
            pea     oldfpal             ; VgetRGB(0,256,buffer)
            move.w  #256,-(sp)
            clr.w   -(sp)
            move.w  #94,-(sp)
            trap    #14
            lea     10(sp),sp

            ; --- 3 screens in ST-RAM (triple buffer), True Color size ---
            clr.w   -(sp)               ; Mxalloc(3 screens, ST-RAM)
            move.l  #3*TCSCR+256,-(sp)
            move.w  #$44,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            bgt.s   .mem
            clr.w   -(sp)               ; not enough memory : exit
            trap    #1
.mem:       add.l   #255,d0             ; aligned on 256 bytes
            clr.b   d0
            move.l  d0,buf1
            add.l   #TCSCR,d0           ; 153600 = 600*256 -> stays aligned
            move.l  d0,buf2
            add.l   #TCSCR,d0
            move.l  d0,buf3

            ; --- video mode : VGA 320x200 16 colours at start ---
            move.w  #89,-(sp)           ; VgetMonitor : 2 = VGA
            trap    #14
            addq.l  #2,sp
            clr.w   vgamon
            cmp.w   #2,d0
            bne.s   .rgb
            move.w  #1,vgamon           ; True Color possible (V key)
.rgb:       clr.w   tcmode
            bsr     gentc
            bsr     setvideo

            ; --- objects OBJ\*.OBJ : the 1st one (and its palette) ---
            bsr     scanobjs
            clr.w   curobj
            bsr     loadobj
            bsr     d3dverts            ; vertices to the DSP
            bsr     marktex
            clr.w   autostage           ; auto mode : 16 colours first

            move.l  front,a0            ; empty screen during the 1st loading
            bsr     fullclear

            bsr     gensin
            bsr     genytab
            bsr     genmask


            clr.w   tframe

            bsr     nextmod             ; first module (alphabetical order)
            bsr     getclk
            move.l  d0,objclk           ; start of the object change timer

            bsr     getclk              ; start of the frames/s counter
            move.l  d0,fpsclk
            clr.w   fpscnt
            clr.w   fps

;--------------------------------------------------------------
mainloop:
            ; --- rectangle to clear = previous drawing of this buffer ---
            lea     box1,a2
            move.l  back,d0
            cmp.l   buf1,d0
            beq.s   .b1
            lea     box2,a2
            cmp.l   buf2,d0
            beq.s   .b1
            lea     box3,a2
.b1:        move.l  a2,curbox
            move.w  (a2),dirty0         ; touched area : old rectangle...
            move.w  2(a2),dirty1
            move.l  back,a0
            tst.w   fullclr             ; full clear requested ?
            beq.s   .bc
            subq.w  #1,fullclr
            clr.w   trn                 ; (trail : no history left)
            bsr     fullclear
            clr.w   dirty0
            move.w  scrhm1,dirty1
            bsr     invbands
            bra.s   .tr
.bc:        tst.w   tcmode              ; True Color + trail : the previous
            beq.s   .bx                 ; frame faded instead of the clearing
            tst.w   trail
            beq.s   .bx
            bsr     trailcopy
            bra.s   .tr
.bx:        bsr     anyboxclear

.tr:        addq.w  #1,tframe           ; time (angles)

            move.l  back,a0
            bsr     transform
            move.l  curbox,a2           ; ... + new rectangle
            bsr     bbox
            move.l  curbox,a2
            bsr     trailbox            ; (trail : area of the last frames)
            move.l  curbox,a2
            move.w  (a2),d0
            cmp.w   dirty0,d0
            bge.s   .d0
            move.w  d0,dirty0
.d0:        move.w  2(a2),d0
            cmp.w   dirty1,d0
            ble.s   .d1
            move.w  d0,dirty1
.d1:
            move.l  back,a0
            bsr     drawobj             ; current object (mode T or S)
            move.l  back,a0
            bsr     drawmenu            ; Musics menu on top

            ; triple buffer : we no longer wait for the VBL every frame. We
            ; only wait if the previous frame has not been displayed yet
            ; (no VBL since it was queued) : at most one frame per VBL, and
            ; the screen we are about to redraw (disp) is no longer displayed.
            bsr     getfrc
            cmp.l   vqprev,d0           ; a VBL since the previous swap ?
            bne.s   .novs
            move.w  #37,-(sp)           ; no : Vsync
            trap    #14
            addq.l  #2,sp
.novs:
            ; display the buffer we just drew (at the next VBL)
            move.w  #-1,-(sp)           ; resolution unchanged
            move.l  back,-(sp)          ; physical
            move.l  #-1,-(sp)           ; logical unchanged
            move.w  #5,-(sp)
            trap    #14
            lea     12(sp),sp
            bsr     getfrc
            move.l  d0,vqprev           ; time of this swap
            move.l  disp,d0             ; rotate the 3 screens
            move.l  front,disp
            move.l  back,front
            move.l  d0,back

            bsr     countfps

            ; --- end of the module : next module ---
            tst.b   MGTK_Restart_Done
            beq.s   .nend
            sf      MGTK_Restart_Done
            bsr     nextmod
.nend:
            ; --- automatic object change ---
            tst.w   autosec
            beq.s   .nauto
            move.l  clkval,d0           ; clock read by countfps
            sub.l   objclk,d0
            moveq   #0,d1
            move.w  autosec,d1
            mulu    #200,d1             ; in 200 Hz ticks
            cmp.l   d1,d0
            blo.s   .nauto
            bsr     autonext            ; next object / next mode
.nauto:

            move.w  #11,-(sp)           ; Cconis : key pressed ?
            trap    #1
            addq.l  #2,sp
            tst.w   d0
            beq     mainloop

            move.w  #7,-(sp)            ; Crawcin : read the key without echo
            trap    #1
            addq.l  #2,sp
            and.w   #$00FF,d0
            cmp.b   #'+',d0
            beq     .volup
            cmp.b   #'-',d0
            beq     .voldn
            cmp.b   #'p',d0
            beq     .pause
            cmp.b   #'P',d0
            beq     .pause
            cmp.b   #'m',d0
            beq     .next
            cmp.b   #'M',d0
            beq     .next
            cmp.b   #'o',d0
            beq     .obj
            cmp.b   #'O',d0
            beq     .obj
            cmp.b   #'v',d0
            beq     .video
            cmp.b   #'V',d0
            beq     .video
            cmp.b   #'s',d0
            beq     .shade
            cmp.b   #'S',d0
            beq     .shade
            cmp.b   #'r',d0
            beq     .trail
            cmp.b   #'R',d0
            beq     .trail
            cmp.b   #'t',d0
            beq     .auto
            cmp.b   #'T',d0
            beq     .auto
            cmp.b   #' ',d0             ; SPACE : back to the menu
            beq     .back
            cmp.b   #27,d0              ; ESC : greetings, then exit
            bne     mainloop
            tst.w   gpage
            bne     .exit
            move.w  #1,gpage
            move.w  #3,fullclr          ; page change : clear everything
            bra     mainloop
.back:      clr.w   gpage
            move.w  #3,fullclr
            bra     mainloop
.next:      bsr     nextmod             ; next module
            bra     mainloop
.obj:       bsr     nextobj             ; next object
            bra     mainloop
.shade:     addq.w  #1,shade            ; Gouraud, Phong, cel, chrome, mapping
            cmp.w   #5,shade
            blo     mainloop
            clr.w   shade
            bra     mainloop
.trail:     not.w   trail               ; True Color trail on / off
            clr.w   trn
            move.w  #3,fullclr
            bra     mainloop
.video:     bsr     togglevideo         ; 16 colours <-> True Color
            bra     mainloop
.auto:      lea     autotab,a0          ; next duration : 10/20/30/60/off
            move.w  autosec,d0
.at:        move.w  (a0)+,d1
            bmi.s   .at0
            cmp.w   d1,d0
            bne.s   .at
            move.w  (a0),d1             ; following value
            bpl.s   .at1
.at0:       move.w  autotab,d1          ; end of table : back to the start
.at1:       move.w  d1,autosec
            bsr     getclk
            move.l  d0,objclk
            bra     mainloop
.pause:     bsr     togglepause
            bra     mainloop
.volup:     move.w  mastervol,d0
            cmp.w   #64,d0
            blo.s   .incvol
            bra     mainloop
.incvol:
            addq.w  #4,d0
            cmp.w   #64,d0
            bls.s   .sv
            moveq   #64,d0
            bra.s   .sv
.voldn:     move.w  mastervol,d0
            bne.s   .decvol
            bra     mainloop
.decvol:
            subq.w  #4,d0
            bpl.s   .sv
            moveq   #0,d0
.sv:        move.w  d0,mastervol
            bsr     setvol
            bra     mainloop

            ; --- exit ---
.exit:
            bsr     stopmus             ; stop the music
            bsr     freemod
            bsr     dspexit             ; original sound system

            ; --- restore the original Falcon video mode ---
            move.w  oldmode,-(sp)       ; Setscreen(log,phys,3,modecode)
            move.w  #3,-(sp)
            move.l  oldphys,-(sp)
            move.l  oldlog,-(sp)
            move.w  #5,-(sp)
            trap    #14
            lea     14(sp),sp

            ; --- restore the original Falcon palette ---
            pea     oldfpal             ; VsetRGB(0,256,buffer)
            move.w  #256,-(sp)
            clr.w   -(sp)
            move.w  #93,-(sp)
            trap    #14
            lea     10(sp),sp

            dc.w    $a009               ; Line-A : show the mouse again
            move.l  oldssp,-(sp)        ; back to user mode
            move.w  #$20,-(sp)
            trap    #1
            addq.l  #6,sp
            bsr     hatquit             ; (in Hatari : closes it)
            clr.w   -(sp)               ; Pterm0
            trap    #1

;--------------------------------------------------------------
; hatquit : leaving 3Dreams also closes Hatari when it was started
;   with --natfeats on (3Dreams.bat) : NatFeats NF_EXIT. On a real
;   Falcon (or natfeats off) the NatFeats opcode $7300 is an illegal
;   instruction : it is caught and nothing happens.
;--------------------------------------------------------------
hatquit:
            movem.l d0-d2/a0-a2,-(sp)
            pea     hqsup(pc)
            move.w  #38,-(sp)           ; Supexec
            trap    #14
            addq.l  #6,sp
            movem.l (sp)+,d0-d2/a0-a2
            rts
hqsup:      move.l  $10.w,-(sp)         ; illegal instruction vector
            move.l  sp,hqsp
            move.l  #hqill,$10.w
            pea     hqname              ; NF_ID("NF_EXIT")
            subq.l  #4,sp               ; (slot of a return address)
            dc.w    $7300
            addq.l  #8,sp
            tst.l   d0
            beq.s   hqno
            clr.l   -(sp)               ; NF_EXIT(0) : Hatari quits
            move.l  d0,-(sp)
            subq.l  #4,sp
            dc.w    $7301
            lea     12(sp),sp
hqno:       move.l  (sp)+,$10.w
            rts
hqill:      move.l  hqsp,sp             ; no NatFeats : drop the frame
            bra.s   hqno

;--------------------------------------------------------------
; getclk : d0 = _hz_200 (system 200 Hz counter)
; countfps : frames displayed per second -> fps
;--------------------------------------------------------------
; getfrc : d0 = VBL counter (_frclock)
getfrc:
            pea     .rd
            move.w  #38,-(sp)           ; Supexec
            trap    #14
            addq.l  #6,sp
            move.l  frcval,d0
            rts
.rd:        move.l  $466.w,frcval
            rts

getclk:
            pea     .rd
            move.w  #38,-(sp)           ; Supexec
            trap    #14
            addq.l  #6,sp
            move.l  clkval,d0
            rts
.rd:        move.l  $4ba.w,clkval
            rts

countfps:
            addq.w  #1,fpscnt
            bsr     getclk
            move.l  d0,d1
            sub.l   fpsclk,d1
            cmp.l   #200,d1             ; one second elapsed ?
            blo.s   .out
            move.l  d0,fpsclk
            move.w  fpscnt,fps
            clr.w   fpscnt
.out:       rts

;==============================================================
; INTERFACE WITH SIMPLET'S DSP REPLAY (AMIGADSP.S)
;   all MGTK_ routines are called here, registers saved
;==============================================================

;--------------------------------------------------------------
; dspinit : loads the DSP program, saves and prepares the sound
;--------------------------------------------------------------
dspinit:
            movem.l d0-d7/a0-a6,-(sp)
            clr.w   dspok
            bsr     d3dinit             ; Simplet's replay + 3DREAMS (Dsp_ExecProg)
            tst.l   d0
            bmi.s   .ko
            move.w  #1,dspok
            jsr     MGTK_Save_Sound
            jsr     MGTK_Init_Sound     ; matrix : DSP -> DAC
            moveq   #REPFREQ,d0
            bsr     MGTK_Set_Replay_Frequency
            sf      MGTK_Restart_Loop   ; end of the module : go to the next one
            bsr     d3dload             ; 3DREAMS answers ? + 1/w table
.ko:        movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; dspexit : restores the original sound system
;--------------------------------------------------------------
dspexit:
            tst.w   dspok
            beq.s   .out
            movem.l d0-d7/a0-a6,-(sp)
            jsr     MGTK_Restore_Sound
            movem.l (sp)+,d0-d7/a0-a6
.out:       rts

;--------------------------------------------------------------
; startmus : starts the loaded module (musok = 1)
;--------------------------------------------------------------
startmus:
            tst.w   musok
            beq.s   .out
            tst.w   ymmode
            bne     ymstart
            movem.l d0-d7/a0-a6,-(sp)
            sf      MGTK_Restart_Done
            bsr     MGTK_Play_Music     ; installs Timer A
            movem.l (sp)+,d0-d7/a0-a6
            move.w  #1,playing
            bsr     setvol
.out:       rts

;--------------------------------------------------------------
; stopmus : stops the replay (Timer A off, DSP disconnected)
;--------------------------------------------------------------
stopmus:
            tst.w   playing
            beq.s   .out
            tst.w   ymmode
            bne     ymstop
            movem.l d0-d7/a0-a6,-(sp)
            bsr     MGTK_Stop_Music
            movem.l (sp)+,d0-d7/a0-a6
            clr.w   playing
            clr.w   paused
.out:       rts

;--------------------------------------------------------------
; setvol : master volume 0..64 -> DSP master volumes (0..$ffc0)
;--------------------------------------------------------------
setvol:
            tst.w   ymmode
            bne     ymvol
            move.w  mastervol,d0
            mulu    #1023,d0
            move.w  d0,MGTK_Master_Volume_Left
            move.w  d0,MGTK_Master_Volume_Right
            rts

;--------------------------------------------------------------
; togglepause : P -> pause / resume (MGTK_Pause_Music)
;--------------------------------------------------------------
togglepause:
            tst.w   playing
            beq.s   .out
            tst.w   ymmode
            beq.s   .dsp
            not.w   paused              ; YM : Timer A mutes the sound
            bra     ymvol
.dsp:       movem.l d0-d7/a0-a6,-(sp)
            bsr     MGTK_Pause_Music
            movem.l (sp)+,d0-d7/a0-a6
            not.w   paused
.out:       rts

;--------------------------------------------------------------
; scanmods : fills modnames with the ZIK\*.MOD files
;            (Fsfirst / Fsnext) -> nmods
;--------------------------------------------------------------
scanmods:
            clr.w   nmods
            pea     dta                 ; Fsetdta
            move.w  #$1a,-(sp)
            trap    #1
            addq.l  #6,sp
            lea     modmask,a3          ; Amiga modules (DSP)
            bsr.s   .scan
            lea     ymmask,a3           ; YM tunes (COSO player)
            bsr.s   .scan
            lea     modnames,a0         ; alphabetical order
            move.w  nmods,d0
            bra     sortnames

.scan:      clr.w   -(sp)               ; Fsfirst(mask, normal files)
            move.l  a3,-(sp)
            move.w  #$4e,-(sp)
            trap    #1
            addq.l  #8,sp
.lp:        tst.l   d0
            bne.s   .out                ; no more file (a3 kept by GEMDOS)
            move.w  nmods,d0
            cmp.w   #MAXMODS,d0
            bhs.s   .out
            mulu    #NAMESZ,d0
            lea     modnames,a0
            adda.l  d0,a0
            lea     dta+30,a1           ; file name in the DTA
            moveq   #NAMESZ-2,d1
.cp:        move.b  (a1)+,(a0)+
            dbeq    d1,.cp
            clr.b   (a0)
            addq.w  #1,nmods
            move.w  #$4f,-(sp)          ; Fsnext
            trap    #1
            addq.l  #2,sp
            bra.s   .lp
.out:       rts

;--------------------------------------------------------------
; nextmod : next module in alphabetical order (wraps around)
;--------------------------------------------------------------
nextmod:
            move.w  nmods,d1
            beq.s   .none
            move.w  curmod,d0
            addq.w  #1,d0               ; (-1 at start -> 0)
            cmp.w   d1,d0
            blo.s   .go
            moveq   #0,d0
.go:        bra     switchmod
.none:      move.w  #9,muserr           ; no .MOD in ZIK
            clr.w   musok
            rts

;--------------------------------------------------------------
; switchmod : d0 = index ; stops the music, frees the old
;             module, loads the new one and restarts the replay
;--------------------------------------------------------------
switchmod:
            move.w  d0,curmod
            move.w  #1,loading
            clr.w   dirty0              ; "LOADING" on the visible screen
            move.w  scrhm1,dirty1
            move.l  front,a0
            bsr     drawmenu
            bsr     stopmus
            bsr     freemod
            bsr     loadmod
            bsr     startmus
            clr.w   loading
            rts

;--------------------------------------------------------------
; freemod : gives the module memory back (Mfree)
;--------------------------------------------------------------
freemod:
            clr.w   musok
            move.l  modbase,d0
            beq.s   .out
            move.l  d0,-(sp)
            move.w  #$49,-(sp)
            trap    #1
            addq.l  #6,sp
            clr.l   modbase
.out:       rts

;--------------------------------------------------------------
; loadmod : loads ZIK\<modnames[curmod]>, then prepares it with
;           MGTK_Init_Module_Samples (module + work area
;           contiguous). musok = 0 on failure : the cube spins alone.
;--------------------------------------------------------------
loadmod:
            clr.w   musok
            clr.w   ymmode
            lea     pathbuf,a0          ; path = "ZIK\" + name
            lea     modmask,a1
            moveq   #3,d1
.p1:        move.b  (a1)+,(a0)+
            dbra    d1,.p1
            bsr     curname
.p2:        move.b  (a1)+,(a0)+
            bne.s   .p2
            cmpi.b  #'G',-2(a0)         ; .ORG extension : YM music
            bne.s   .dsp
            cmpi.b  #'R',-3(a0)
            bne.s   .dsp
            cmpi.b  #'O',-4(a0)
            bne.s   .dsp
            cmpi.b  #'.',-5(a0)
            beq     loadym
.dsp:       move.w  #10,muserr          ; DSP missing ?
            tst.w   dspok
            beq     .out

            move.w  #1,muserr           ; step 1 : open the file
            clr.w   -(sp)               ; Fopen(name, read)
            pea     pathbuf
            move.w  #$3d,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            bmi     .out
            move.w  d0,sndh
            move.w  #2,muserr           ; step 2 : file size

            move.w  #2,-(sp)            ; Fseek(0,h,end) -> size
            move.w  sndh,-(sp)
            clr.l   -(sp)
            move.w  #$42,-(sp)
            trap    #1
            lea     10(sp),sp
            move.l  d0,modlen

            clr.w   -(sp)               ; Fseek(0,h,start)
            move.w  sndh,-(sp)
            clr.l   -(sp)
            move.w  #$42,-(sp)
            trap    #1
            lea     10(sp),sp

            cmpi.l  #2048,modlen        ; too small to be a module
            blo     .close
            move.w  #3,muserr           ; step 3 : memory

            move.w  #3,-(sp)            ; Mxalloc(module+work, ST or TT)
            move.l  modlen,d0
            add.l   #WORKSZ+16,d0
            move.l  d0,-(sp)
            move.w  #$44,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            ble     .close
            move.l  d0,modbase
            move.w  #4,muserr           ; step 4 : read the file

            move.l  modbase,-(sp)       ; Fread(h,size,buffer)
            move.l  modlen,-(sp)
            move.w  sndh,-(sp)
            move.w  #$3f,-(sp)
            trap    #1
            lea     12(sp),sp
            cmp.l   modlen,d0
            bne     .close

            move.w  #6,muserr           ; step 5 : MegaPlayer preparation
            movem.l d0-d7/a0-a6,-(sp)
            move.l  modbase,a0          ; a0 = module
            move.l  modlen,d0
            addq.l  #1,d0
            and.b   #$fe,d0             ; (even end)
            add.l   #WORKSZ,d0
            move.l  a0,a1
            adda.l  d0,a1               ; a1 = END of the work area
            bsr     MGTK_Init_Module_Samples
            ext.l   d0                  ; 0 = ok, -3 = area too small
            move.l  d0,initres
            movem.l (sp)+,d0-d7/a0-a6
            tst.l   initres
            bmi     .close
            clr.w   muserr
            move.w  #1,musok

.close:     move.w  sndh,-(sp)          ; Fclose
            move.w  #$3e,-(sp)
            trap    #1
            addq.l  #4,sp
            tst.w   musok
            bne.s   .out
            bsr     freemod             ; failure : give the memory back
.out:       rts

;--------------------------------------------------------------
; curname : a1 = name of the current module
;--------------------------------------------------------------
curname:
            move.w  curmod,d1
            mulu    #NAMESZ,d1
            lea     modnames,a1
            adda.l  d1,a1
            rts


;==============================================================
; YM MUSICS : ZIK\*.ORG files
;   "COSO player + music" block by Jochen Hippel as taken from
;   memory (PWRBOAT.ORG : Power Boat intro, Mad Max music).
;   Fully PC-relative code :
;     +0 init (d0 = 1 : tune 1, d0 = 0 : stop)   +8 play at 50 Hz
;   The player writes the YM with movem.l to $FFFF8840 / $FFFF8800 :
;   the Falcon has no YM mirror -> bus error. When loading,
;   each movem.l <regs>,$88xx.w is replaced by bsr.w + nop to
;   a small routine added after the block (move.l Rn,$FFFF8800.w
;   register by register) : same sound, the file is not modified.
;==============================================================
YMEXTRA     equ     8*68+16             ; room for 8 patch routines

;--------------------------------------------------------------
; loadym : loads pathbuf (.ORG), patches it -> musok / ymmode
;--------------------------------------------------------------
loadym:
            move.w  #1,muserr
            clr.w   -(sp)               ; Fopen(name, read)
            pea     pathbuf
            move.w  #$3d,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            bmi     .out
            move.w  d0,sndh
            move.w  #2,-(sp)            ; Fseek(0,h,end) -> size
            move.w  sndh,-(sp)
            clr.l   -(sp)
            move.w  #$42,-(sp)
            trap    #1
            lea     10(sp),sp
            move.l  d0,modlen
            clr.w   -(sp)               ; Fseek(0,h,start)
            move.w  sndh,-(sp)
            clr.l   -(sp)
            move.w  #$42,-(sp)
            trap    #1
            lea     10(sp),sp
            move.w  #12,muserr          ; block not recognised
            cmpi.l  #64,modlen
            blo     .close
            cmpi.l  #200000,modlen
            bhi     .close
            move.w  #3,muserr
            move.w  #3,-(sp)            ; Mxalloc(block + patches, ST or TT)
            move.l  modlen,d0
            add.l   #YMEXTRA,d0
            move.l  d0,-(sp)
            move.w  #$44,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            ble     .close
            move.l  d0,modbase
            move.w  #4,muserr
            move.l  modbase,-(sp)       ; Fread(h,size,buffer)
            move.l  modlen,-(sp)
            move.w  sndh,-(sp)
            move.w  #$3f,-(sp)
            trap    #1
            lea     12(sp),sp
            cmp.l   modlen,d0
            bne     .close

            ; --- entries +0, +4, +8 : bra.w ---
            move.w  #12,muserr
            move.l  modbase,a0
            moveq   #2,d1
.ent:       cmpi.w  #$6000,(a0)
            bne     .close
            addq.l  #4,a0
            dbra    d1,.ent

            ; --- Falcon patch : movem.l regs,$88xx.w ---
            move.l  modbase,a0          ; a0 = scan pointer
            move.l  modlen,d0
            addq.l  #1,d0
            and.b   #$fe,d0
            lea     (a0,d0.l),a2        ; a2 = added routines (end of the block)
            lea     -6(a2),a3           ; a3 = last word to test
            moveq   #8,d6               ; max patches
.scan:      cmpa.l  a3,a0
            bhi.s   .done
            cmpi.w  #$48f8,(a0)         ; movem.l <list>,address.w
            bne.s   .nx
            move.w  4(a0),d0
            and.w   #$ff00,d0
            cmp.w   #$8800,d0           ; to the YM ($FFFF88xx)
            bne.s   .nx
            subq.w  #1,d6
            bmi.s   .done
            move.w  2(a0),d2            ; register mask
            move.w  #$6100,(a0)         ; bsr.w routine
            move.l  a2,d0
            sub.l   a0,d0
            subq.l  #2,d0
            move.w  d0,2(a0)
            move.w  #$4e71,4(a0)        ; nop
            moveq   #0,d1               ; bit 0 = D0 ... bit 15 = A7
.bit:       btst    d1,d2
            beq.s   .nb
            move.w  #$21c0,d0           ; move.l Rn,$ffff8800.w
            add.w   d1,d0               ; ($21c0+n = Dn, $21c8+n = An)
            move.w  d0,(a2)+
            move.w  #$8800,(a2)+
.nb:        addq.w  #1,d1
            cmp.w   #16,d1
            blo.s   .bit
            move.w  #$4e75,(a2)+        ; rts
            addq.l  #6,a0
            bra.s   .scan
.nx:        addq.l  #2,a0
            bra.s   .scan
.done:      pea     flushc              ; modified code : flush the 030 caches
            move.w  #38,-(sp)
            trap    #14
            addq.l  #6,sp
            clr.w   muserr
            move.w  #1,musok
            move.w  #1,ymmode
.close:     move.w  sndh,-(sp)          ; Fclose
            move.w  #$3e,-(sp)
            trap    #1
            addq.l  #4,sp
            tst.w   musok
            bne.s   .out
            bsr     freemod
            clr.w   ymmode
.out:       rts

flushc:     movec   cacr,d0             ; (supervisor) CI + CD
            or.w    #$0808,d0
            movec   d0,cacr
            rts

;--------------------------------------------------------------
; ymstart : YM to the Falcon output, init, Timer A 50 Hz
;--------------------------------------------------------------
ymstart:
            movem.l d0-d7/a0-a6,-(sp)
            clr.w   paused
            pea     .sup
            move.w  #38,-(sp)
            trap    #14
            addq.l  #6,sp
            pea     ymtimer             ; Xbtimer(A, /200, 246) : 49.95 Hz
            move.w  #246,-(sp)
            move.w  #7,-(sp)
            clr.w   -(sp)
            move.w  #31,-(sp)
            trap    #14
            lea     12(sp),sp
            movem.l (sp)+,d0-d7/a0-a6
            move.w  #1,playing
            bra     ymvol
.sup:       move.b  $ffff8937.w,ysv8937 ; codec state (restored when stopping)
            move.b  $ffff8938.w,ysv8938
            move.w  $ffff893a.w,ysv893a
            move.b  #%01,$ffff8937.w    ; adder : ADC input only
            move.b  #%11,$ffff8938.w    ; ADC left + right = YM2149
            moveq   #1,d0               ; tune 1
            move.l  modbase,a0
            jmp     (a0)

;--------------------------------------------------------------
; ymstop : Timer A off, player stopped, codec restored
;--------------------------------------------------------------
ymstop:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  #13,-(sp)           ; Jdisint(13) : Timer A
            move.w  #26,-(sp)
            trap    #14
            addq.l  #4,sp
            pea     .sup
            move.w  #38,-(sp)
            trap    #14
            addq.l  #6,sp
            movem.l (sp)+,d0-d7/a0-a6
            clr.w   playing
            clr.w   paused
            rts
.sup:       moveq   #0,d0               ; stop the player
            move.l  modbase,a0
            jsr     (a0)
            bsr.s   ymsilence
            move.b  ysv8937,$ffff8937.w
            move.b  ysv8938,$ffff8938.w
            move.w  ysv893a,$ffff893a.w
            rts

; ymsilence : volumes of the 3 voices at 0 (supervisor)
ymsilence:
            move.b  #8,$ffff8800.w
            move.b  #0,$ffff8802.w
            move.b  #9,$ffff8800.w
            move.b  #0,$ffff8802.w
            move.b  #10,$ffff8800.w
            move.b  #0,$ffff8802.w
            rts

;--------------------------------------------------------------
; ymvol : master volume (+/-) -> codec attenuation
;         0 or pause : Timer A mutes the YM
;--------------------------------------------------------------
ymvol:
            movem.l d0-d2/a0-a2,-(sp)
            move.w  mastervol,d0
            tst.w   paused
            sne     d1
            tst.w   d0
            seq     d2
            or.b    d2,d1
            move.b  d1,ymmute
            moveq   #64,d1              ; 64 -> 0 dB ... 4 -> -22.5 dB
            sub.w   d0,d1
            lsr.w   #2,d1
            cmp.w   #15,d1
            bls.s   .a
            moveq   #15,d1
.a:         move.w  d1,d0
            lsl.w   #4,d0               ; right : bits 7-4
            lsl.w   #8,d1               ; left : bits 11-8
            or.w    d1,d0
            move.w  d0,ymatt
            pea     .sup
            move.w  #38,-(sp)
            trap    #14
            addq.l  #6,sp
            movem.l (sp)+,d0-d2/a0-a2
            rts
.sup:       move.w  $ffff893a.w,d0
            and.w   #$f00f,d0
            or.w    ymatt,d0
            move.w  d0,$ffff893a.w
            rts

;--------------------------------------------------------------
; ymtimer : Timer A (50 Hz) -> player
;--------------------------------------------------------------
ymtimer:
            movem.l d0-d7/a0-a6,-(sp)
            tst.b   ymmute
            bne.s   .mute
            move.l  modbase,a0
            jsr     8(a0)
            bra.s   .out
.mute:      bsr     ymsilence
.out:       movem.l (sp)+,d0-d7/a0-a6
            bclr    #5,$fffffa0f.w      ; end of interrupt (ISRA)
            rte

            section data
hqname:     dc.b    'NF_EXIT',0
            even
            section bss
hqsp:       ds.l    1
            section text
;==============================================================
; MUSICS MENU
;   5 bands of 6x6 text (system font) : 2 at the top, 3 at the bottom
;   53 columns of 6 pixels
;   text colour 15 on background colour 0 (all 4 planes)
;==============================================================

;--------------------------------------------------------------
; drawmenu : builds and displays the menu in screen a0
;--------------------------------------------------------------
drawmenu:
            movem.l d0-d7/a0-a6,-(sp)
            move.l  a0,a6               ; a6 = screen
            ; --- nothing changed since the previous frame ? ---
            lea     cursig,a1
            move.w  fps,(a1)+
            move.w  paused,(a1)+
            move.w  curmod,(a1)+
            move.w  loading,(a1)+
            move.w  musok,(a1)+
            move.w  muserr,(a1)+
            move.w  curobj,(a1)+
            move.w  autosec,(a1)+
            move.w  mastervol,(a1)+
            move.w  tcmode,(a1)+
            move.w  gpage,(a1)+
            move.w  shade,(a1)+
            move.w  trail,(a1)+
            moveq   #0,d0
            move.b  MGTK_Replay_Problem,d0
            move.w  d0,(a1)+
            tst.w   sigok
            beq.s   .full
            lea     cursig,a1
            lea     lastsig,a2
            moveq   #SIGN-1,d0
.sg:        cmpm.w  (a1)+,(a2)+
            dbne    d0,.sg
            bne.s   .full
            ; same text : only copy the bands back if needed
            move.w  lastslots,d7
            subq.w  #1,d7
            bmi.s   .fq
            lea     bandcache,a4
.fl:        move.w  (a4),d1
            movem.l d7/a4,-(sp)
            bsr     bandblit
            movem.l (sp)+,d7/a4
            lea     SLOTSZ(a4),a4
            dbra    d7,.fl
.fq:        movem.l (sp)+,d0-d7/a0-a6
            rts
.full:      lea     cursig,a1           ; text to rebuild
            lea     lastsig,a2
            moveq   #SIGN-1,d0
.sc:        move.w  (a1)+,(a2)+
            dbra    d0,.sc
            move.w  #1,sigok
            clr.w   slotidx             ; band cache : 1st slot
            tst.w   gpage                ; greetings page ?
            bne     drawgreet

            ; --- line 0 : title / pause / quit ---
            lea     mline,a2
            bsr     blank
            lea     t_title,a1
            moveq   #1,d0
            bsr     place
            tst.w   paused
            beq.s   .l0
            lea     t_pause,a1
            moveq   #8,d0
            bsr     place
.l0:        lea     t_m16,a1            ; video mode
            move.w  tcmode,d0
            beq.s   .l0m
            tst.w   objmode             ; solid object : chosen rendering (S)
            bne.s   .l0s
            lea     t_mtc,a1
            cmp.w   #2,d0
            bne.s   .l0m
            lea     t_mtf,a1
            bra.s   .l0m
.l0s:       subq.w  #1,d0
            mulu    #5,d0               ; 5 renderings per mode
            add.w   shade,d0
            lsl.w   #2,d0
            lea     shdtab,a1
            move.l  (a1,d0.w),a1
.l0m:       moveq   #21,d0
            bsr     place
        lea     t_fps,a1            ; frames / second
            moveq   #34,d0
            bsr     place
            move.w  fps,d0
            bsr     fmtnum
            bsr     place2
            lea     t_esc,a1
            moveq   #43,d0
            bsr     place
            move.w  bandy,d1
            bsr     drawline

            ; --- line 1 : current module ---
            lea     mline,a2
            bsr     blank
            tst.w   loading
            beq.s   .l1a
            lea     t_load,a1           ; "LOADING ZIK\NAME..."
            moveq   #1,d0
            bsr     place
            bsr     curname
            moveq   #13,d0
            bsr     place
            bra     .l1d
.l1a:       tst.w   musok
            beq.s   .l1e
            tst.w   ymmode              ; YM : no DSP
            bne.s   .l1ok
            tst.b   MGTK_Replay_Problem ; the DSP no longer answers ?
            beq.s   .l1ok
            move.w  #11,d0
            bra.s   .l1f
.l1ok:
            moveq   #0,d0               ; "n/N > NAME"
            move.w  curmod,d0
            addq.w  #1,d0
            bsr     fmtnum
            moveq   #1,d0
            bsr     place
            lea     t_slash,a1
            bsr     place2
            move.w  nmods,d0
            bsr     fmtnum
            bsr     place2
            lea     t_sep,a1            ; " > "
            bsr     place2
            bsr     curname
            bsr     place2
            bra.s   .l1d
.l1e:       move.w  muserr,d0           ; "! error message"
            cmp.w   #12,d0
            bls.s   .l1f
            moveq   #0,d0
.l1f:       lsl.w   #2,d0
            lea     errtab,a1
            move.l  (a1,d0.w),a1
            moveq   #1,d0
            bsr     place
.l1d:       move.w  nv,d0               ; points and faces of the object
            bsr     fmtnum
            moveq   #25,d0
            bsr     place
            lea     t_pts,a1
            bsr     place2
            move.w  nf,d0
            bsr     fmtnum
            bsr     place2
            lea     t_fcs,a1
            bsr     place2
            tst.w   tcmode              ; True Color trail
            beq.s   .l1t
            tst.w   trail
            beq.s   .l1t
            lea     t_trail,a1
            moveq   #47,d0
            bsr     place
.l1t:       move.w  bandy+2,d1
            bsr     drawline

            ; --- line 2 : current object ---
            lea     mline,a2
            bsr     blank
            lea     t_obj,a1
            moveq   #1,d0
            bsr     place
            lea     objtitle,a1
            bsr     place2
            lea     t_auto,a1           ; automatic change
            moveq   #33,d0
            bsr     place
            move.w  autosec,d0
            beq.s   .aoff
            bsr     fmtnum
            bsr     place2
            lea     t_sec,a1
            bsr     place2
            bra.s   .aon
.aoff:      lea     t_off,a1
            bsr     place2
.aon:       tst.w   nobjs
            beq.s   .l2n
            moveq   #0,d0
            move.w  curobj,d0
            addq.w  #1,d0
            bsr     fmtnum
            moveq   #46,d0
            bsr     place
            lea     t_slash,a1
            bsr     place2
            move.w  nobjs,d0
            bsr     fmtnum
            bsr     place2
.l2n:       move.w  bandy+8,d1
            bsr     drawline

            ; --- line 3 : volume ---
            lea     mline,a2
            bsr     blank
            lea     t_vol,a1
            moveq   #1,d0
            bsr     place
            move.b  #'[',8(a2)
            move.b  #']',25(a2)
            move.w  mastervol,d2        ; 16 boxes : full if vol > 4*i
            lea     9(a2),a3
            moveq   #0,d3
            moveq   #15,d4
.vb:        move.b  #2,(a3)             ; empty box
            cmp.w   d3,d2
            bls.s   .ve
            move.b  #1,(a3)             ; full box
.ve:        addq.l  #1,a3
            addq.w  #4,d3
            dbra    d4,.vb
            moveq   #0,d0
            move.w  mastervol,d0
            bsr     fmtnum
            moveq   #27,d0
            bsr     place
            lea     t_pm,a1
            moveq   #31,d0
            bsr     place
            move.w  bandy+10,d1
            bsr     drawline

            ; --- line 4 : help ---
            lea     mline,a2
            bsr     blank
            lea     t_help,a1
            moveq   #0,d0
            bsr     place
            move.w  bandy+12,d1
            bsr     drawline

            move.w  slotidx,lastslots
            movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; drawgreet : greetings page (after the 1st ESC)
;             centred lines, table gtab (y, text), end = -1
;--------------------------------------------------------------
drawgreet:
            lea     gtab,a5
.lp:        tst.w   (a5)                ; end of table ?
            bmi.s   .end
            lea     mline,a2
            bsr     blank               ; (destroys d1)
            move.w  (a5)+,d1            ; band number -> screen line
            add.w   d1,d1
            lea     bandy,a1
            move.w  (a1,d1.w),d1
            move.l  (a5)+,a1            ; text
            move.l  a1,a3               ; text length
.ln:        tst.b   (a3)+
            bne.s   .ln
            suba.l  a1,a3
            subq.l  #1,a3
            moveq   #COLS,d0            ; column = (COLS - length) / 2
            sub.w   a3,d0
            bpl.s   .c
            moveq   #0,d0
.c:         lsr.w   #1,d0
            move.w  d1,-(sp)
            bsr     place
            move.w  (sp)+,d1
            move.l  a5,-(sp)
            bsr     drawline
            move.l  (sp)+,a5
            bra.s   .lp
.end:       move.w  slotidx,lastslots
            movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; blank : fills line a2 with 40 spaces
;--------------------------------------------------------------
blank:
            move.l  a2,a3
            moveq   #LINESZ-1,d1
.b:         move.b  #' ',(a3)+
            dbra    d1,.b
            rts

;--------------------------------------------------------------
; place : copies string a1 into line a2 at column d0
;         (a3 = next position, for place2) ; cut at 40
; place2 : continues where place stopped
;--------------------------------------------------------------
place:
            lea     (a2,d0.w),a3
place2:
            lea     COLS(a2),a4
.c:         cmpa.l  a4,a3
            bhs.s   .out
            move.b  (a1)+,d1
            beq.s   .out
            move.b  d1,(a3)+
            bra.s   .c
.out:       rts

;--------------------------------------------------------------
; fmtnum : d0.w (0-65535) -> a1 = decimal string
;--------------------------------------------------------------
fmtnum:
            lea     numbuf+8,a1
            clr.b   (a1)
            and.l   #$FFFF,d0
.d:         divu    #10,d0
            swap    d0
            add.b   #'0',d0
            move.b  d0,-(a1)
            clr.w   d0
            swap    d0
            tst.w   d0
            bne.s   .d
            rts

;--------------------------------------------------------------
; drawline : displays the COLS characters of "mline" at line d1
;            of screen a6. Codes 1 and 2 = boxes of the bar.
;            6x6 font : each character is placed to the pixel
;            (shift) in the image of the band (6 lines = 960
;            bytes), kept in a cache : it is only redrawn when the
;            text changes, otherwise a simple movem copy.
;--------------------------------------------------------------
drawline:
            move.w  slotidx,d0          ; next cache slot
            addq.w  #1,slotidx
            mulu    #SLOTSZ,d0
            lea     bandcache,a4
            adda.l  d0,a4               ; a4 = slot
            lea     mline,a2

            cmp.w   (a4),d1             ; same screen line ...
            bne.s   .redraw
            lea     2(a4),a0            ; ... and same text ?
            moveq   #LINESZ/4-1,d0
.cmp:       cmpm.l  (a0)+,(a2)+
            dbne    d0,.cmp
            beq     .blit

.redraw:    move.w  d1,-(sp)
            move.w  d1,(a4)             ; remember y and text
            clr.l   S_VALID(a4)         ; image to copy into the 3 screens
            lea     mline,a2
            lea     2(a4),a0
            moveq   #LINESZ/4-1,d0
.cpt:       move.l  (a2)+,(a0)+
            dbra    d0,.cpt
            tst.w   tcmode              ; True Color : other rendering
            beq.s   .r16
            lea     S_IMG(a4),a0
            bsr     tcband
            move.w  (sp)+,d1
            bra     .blit
.r16:       lea     S_IMG(a4),a0        ; clear the image
            move.w  #BANDB/4-1,d0
.clr:       clr.l   (a0)+
            dbra    d0,.clr

            lea     mline,a2
            moveq   #0,d7               ; column
            moveq   #0,d6               ; pixel x = 6 * column
.ch:        moveq   #0,d0
            move.b  (a2)+,d0
            cmp.w   #' ',d0
            beq     .nc                 ; space : nothing to draw
            move.w  d6,d1               ; 16-pixel word (4 planes)
            lsr.w   #4,d1
            lsl.w   #3,d1
            lea     S_IMG(a4),a3
            adda.w  d1,a3
            move.w  d6,d5
            and.w   #15,d5              ; shift inside the word
            moveq   #BANDH-1,d4         ; lines of the character
            cmp.w   #32,d0
            bhs.s   .font
            mulu    #BANDH,d0           ; internal glyph (volume bar)
            lea     blk6,a1
            adda.w  d0,a1
.bl:        moveq   #0,d2
            move.b  (a1)+,d2
            lsl.w   #8,d2
            bsr     .put
            dbra    d4,.bl
            bra     .nc
.font:      sub.w   fontfirst,d0        ; glyph of the 6x6 font
            add.w   d0,d0
            move.l  fontoff,a1
            move.w  (a1,d0.w),d3        ; x of the character in the font image
            move.w  d3,d0
            lsr.w   #3,d0
            move.l  fontdat,a1
            adda.w  d0,a1               ; 1st byte of the character
            and.w   #7,d3               ; shift inside the byte
.fl:        move.b  (a1),d2             ; 16 bits from that byte
            lsl.w   #8,d2
            move.b  1(a1),d2
            lsl.w   d3,d2
            and.w   #$fc00,d2           ; 6 pixels
            bsr     .put
            adda.w  fontw,a1
            dbra    d4,.fl
.nc:        addq.w  #6,d6
            addq.w  #1,d7
            cmp.w   #COLS,d7
            blo     .ch
            move.w  (sp)+,d1
            bra     .blit

            ; .put : d2.w = 6 pixels (bits 15..10) -> current line,
            ;        shifted by d5 ; a3 = word, moves down one line
.put:       moveq   #0,d0
            move.w  d2,d0
            swap    d0
            lsr.l   d5,d0               ; left word : right word
            swap    d0
            or.w    d0,(a3)             ; colour 15 : all 4 planes
            or.w    d0,2(a3)
            or.w    d0,4(a3)
            or.w    d0,6(a3)
            swap    d0
            tst.w   d0
            beq.s   .p1
            or.w    d0,8(a3)
            or.w    d0,10(a3)
            or.w    d0,12(a3)
            or.w    d0,14(a3)
.p1:        lea     160(a3),a3
            rts

.blit:
bandblit:   lea     S_VALID(a4),a2      ; "already in this screen" flag
            cmpa.l  buf1,a6
            beq.s   .f1
            addq.l  #1,a2
            cmpa.l  buf2,a6
            beq.s   .f1
            addq.l  #1,a2
.f1:        tst.b   (a2)
            beq.s   .copy
            move.w  d1,d0               ; does the cube touch this band ?
            addq.w  #BANDH-1,d0
            cmp.w   dirty0,d0
            blt.s   .skip
            cmp.w   dirty1,d1
            bgt.s   .skip
.copy:      st      (a2)
            moveq   #BANDB/40-1,d7
            tst.w   tcmode
            beq.s   .c16
            mulu    #TCLINE,d1          ; True Color : 640 bytes per line
            moveq   #BANDTC/40-1,d7
            bra.s   .cp
.c16:       mulu    #160,d1             ; copy the image to the screen
.cp:        lea     (a6,d1.l),a3
            lea     S_IMG(a4),a2
.cb:        movem.l (a2)+,d0-d6/a0/a1/a5
            movem.l d0-d6/a0/a1/a5,(a3)
            lea     40(a3),a3
            dbra    d7,.cb
.skip:      rts

;--------------------------------------------------------------
; invbands : after a full clear, the bands must be
;            copied again into the screens
;--------------------------------------------------------------
invbands:
            lea     bandcache+S_VALID,a1
            moveq   #NSLOTS-1,d0
.i:         clr.l   (a1)
            lea     SLOTSZ(a1),a1
            dbra    d0,.i
            rts

;--------------------------------------------------------------
; gensin : 256-entry sine table (scale 2^14) built by recurrence
;          s += c*k ; c -= s*k   (k = 201/8192 ~ 2*pi/256)
;--------------------------------------------------------------
gensin:
            lea     sintab,a6
            moveq   #0,d0               ; s
            move.w  #16384,d1           ; c
            moveq   #13,d3
            move.w  #255,d7
.g:         move.w  d0,(a6)+
            move.w  d1,d2
            muls    #201,d2
            asr.l   d3,d2
            add.w   d2,d0
            move.w  d0,d2
            muls    #201,d2
            asr.l   d3,d2
            sub.w   d2,d1
            dbra    d7,.g
            lea     sintab,a6           ; a6 = table (stays fixed afterwards)
            rts

;--------------------------------------------------------------
; getsc : d0 = angle -> d1 = sin, d2 = cos
;--------------------------------------------------------------
getsc:
            and.w   #255,d0
            add.w   d0,d0
            move.w  (a6,d0.w),d1
            add.w   #128,d0             ; +90 degrees (64 entries * 2 bytes)
            and.w   #511,d0
            move.w  (a6,d0.w),d2
            rts

;--------------------------------------------------------------
; clear : clears the screen pointed to by a0 (a0 preserved)
;--------------------------------------------------------------
clear:
            move.l  a0,-(sp)
            lea     SCRSIZE(a0),a0
            moveq   #0,d0
            moveq   #0,d1
            moveq   #0,d2
            moveq   #0,d3
            moveq   #0,d4
            moveq   #0,d5
            moveq   #0,d6
            suba.l  a1,a1
            suba.l  a2,a2
            suba.l  a3,a3
            suba.l  a4,a4
            suba.l  a5,a5
            move.w  #665,d7             ; 666 * 48 bytes
.cl:        movem.l d0-d6/a1-a5,-(a0)
            dbra    d7,.cl
            movem.l d0-d6/a1,-(a0)      ; 32 bytes left
            movea.l (sp)+,a0
            rts

;--------------------------------------------------------------
; genmask : ltab[x] / rtab[x] = mask.w : word offset.w
;--------------------------------------------------------------
genmask:
            lea     ltab,a0
            lea     rtab,a1
            moveq   #0,d0               ; x
.g:         move.w  d0,d1
            and.w   #15,d1
            moveq   #-1,d2
            lsr.w   d1,d2               ; left mask
            moveq   #15,d3
            sub.w   d1,d3
            moveq   #-1,d4
            lsl.w   d3,d4               ; right mask
            move.w  d0,d5
            lsr.w   #4,d5
            lsl.w   #3,d5               ; word offset
            move.w  d2,(a0)+
            move.w  d5,(a0)+
            move.w  d4,(a1)+
            move.w  d5,(a1)+
            addq.w  #1,d0
            cmp.w   #320,d0
            blo.s   .g
            rts

;==============================================================
; FAST ROUTINES (optimised for the real Falcon)
;==============================================================

;--------------------------------------------------------------
; genytab : ytab[y] = y*160 (avoids mulu)
;--------------------------------------------------------------
genytab:
            lea     ytab,a0
            moveq   #0,d0
            move.w  #199,d1
.g:         move.w  d0,(a0)+
            add.w   #160,d0
            dbra    d1,.g
            rts

;--------------------------------------------------------------
; boxclear : clears the rectangle in screen a0 (bx0..bx1 words,
;            by0..by1 lines) ; does nothing if by0 > by1
;            a2 = rectangle (by0,by1,bx0,bx1 in words)
;--------------------------------------------------------------
boxclear:
            move.w  (a2),d4             ; by0
            move.w  2(a2),d5            ; by1
            sub.w   d4,d5
            bmi     .out
            move.w  6(a2),d3            ; x in pixels -> 16-pixel words
            lsr.w   #4,d3
            move.w  4(a2),d0
            lsr.w   #4,d0
            sub.w   d0,d3
            addq.w  #1,d3               ; number of 16-pixel words
            add.w   d3,d3
            add.w   d3,d3               ; 2 move.l (2 bytes each) per word
            neg.w   d3
            add.w   d4,d4
            lea     ytab,a3
            move.w  (a3,d4.w),d4
            lea     (a0,d4.w),a3
            move.w  4(a2),d4
            lsr.w   #4,d4
            lsl.w   #3,d4
            adda.w  d4,a3               ; a3 = top left corner
            moveq   #0,d0
.row:       move.l  a3,a1
            jmp     .end(pc,d3.w)
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
.end:       lea     160(a3),a3
            dbra    d5,.row
.out:       rts

;--------------------------------------------------------------
; bbox : bounding rectangle of the projected vertices -> (a2)
;        (by0,by1 in lines ; bx0,bx1 in 16-pixel words)
;--------------------------------------------------------------
bbox:
            lea     proj,a1
            move.w  #32767,d0           ; xmin
            move.w  #-32768,d1          ; xmax
            move.w  d0,d2               ; ymin
            move.w  d1,d3               ; ymax
            move.w  nv,d7               ; all vertices
            tst.w   mdraw               ; (morphing : the points of the cloud)
            beq.s   .nv
            move.w  #MPTS,d7
.nv:        subq.w  #1,d7
.v:         move.w  (a1)+,d4
            cmp.w   d0,d4
            bge.s   .a
            move.w  d4,d0
.a:         cmp.w   d1,d4
            ble.s   .b
            move.w  d4,d1
.b:         move.w  (a1)+,d4
            cmp.w   d2,d4
            bge.s   .c
            move.w  d4,d2
.c:         cmp.w   d3,d4
            ble.s   .d
            move.w  d4,d3
.d:         dbra    d7,.v
            tst.w   mdraw               ; 2x2 points : one more pixel
            beq.s   .m
            addq.w  #1,d1
            addq.w  #1,d3
.m:         tst.w   d2                  ; screen limits
            bpl.s   .e
            moveq   #0,d2
.e:         cmp.w   scrhm1,d3
            ble.s   .f
            move.w  scrhm1,d3
.f:         tst.w   d0
            bpl.s   .g
            moveq   #0,d0
.g:         cmp.w   #319,d1
            ble.s   .h
            move.w  #319,d1
.h:         move.w  d2,(a2)+            ; x in pixels
            move.w  d3,(a2)+
            move.w  d0,(a2)+
            move.w  d1,(a2)+
            rts

;--------------------------------------------------------------
; line : Bresenham (d0,d1)->(d2,d3) in screen a0, plane 0
;        pointer + bit advanced step by step (no multiplication)
;--------------------------------------------------------------
line:
            cmp.w   d0,d2               ; always from left to right
            bge.s   .lr
            exg     d0,d2
            exg     d1,d3
.lr:        sub.w   d0,d2               ; dx >= 0
            move.w  #160,a1             ; vertical step
            sub.w   d1,d3               ; dy
            bge.s   .dn
            neg.w   d3
            move.w  #-160,a1
.dn:        move.w  d1,d4               ; address of the first point
            add.w   d4,d4
            lea     ytab,a4
            move.w  (a4,d4.w),d4
            lea     (a0,d4.w),a4
            move.w  d0,d4
            lsr.w   #4,d4
            lsl.w   #3,d4
            adda.w  d4,a4
            btst    #3,d0
            beq.s   .lb
            addq.l  #1,a4               ; right byte of the word
.lb:        move.w  d0,d5
            not.w   d5
            and.w   #7,d5               ; bit = 7 - (x & 7)
            move.w  d0,d4               ; d4 = x (for the byte change)

            cmp.w   d3,d2
            blt.s   .ymaj

            ; --- shallow slope : one pixel per x ---
            move.w  d2,d7               ; dx+1 points
            move.w  d2,d6
            asr.w   #1,d6               ; error
.xl:        bset    d5,(a4)
            sub.w   d3,d6
            bpl.s   .xn
            add.w   d2,d6
            adda.w  a1,a4               ; next line
.xn:        addq.w  #1,d4               ; next x
            subq.w  #1,d5
            bpl.s   .xc
            moveq   #7,d5
            btst    #3,d4
            bne.s   .x1
            addq.l  #6,a4               ; right byte -> next word (+7)
.x1:        addq.l  #1,a4               ; left byte -> right byte (+1)
.xc:        dbra    d7,.xl
            rts

            ; --- steep slope : one pixel per y ---
.ymaj:      move.w  d3,d7               ; dy+1 points
            move.w  d3,d6
            asr.w   #1,d6
.yl:        bset    d5,(a4)
            adda.w  a1,a4
            sub.w   d2,d6
            bpl.s   .yc
            add.w   d3,d6
            addq.w  #1,d4
            subq.w  #1,d5
            bpl.s   .yc
            moveq   #7,d5
            btst    #3,d4
            bne.s   .y1
            addq.l  #6,a4
.y1:        addq.l  #1,a4
.yc:        dbra    d7,.yl
            rts

;==============================================================
; 3D OBJECTS : one text file per object in OBJ\*.OBJ
;
;  Format (one command per line, ';' = comment) :
;    N name           name shown in the menu (20 characters max)
;    M T | M S        rendering : T = transparent (faces ORed into
;                     planes 1-3 + white edges), S = shaded solid
;                     (hidden faces removed, sorting, lighting)
;    P delay          new part : same rotation, but with
;                     <delay> frames of delay (60 = 1 s in VGA)
;    B h a T Tx       the current part bounces like a ball
;                     (screen frame) : parabola arcs from -h to +h
;                     every T frames, and horizontal back-and-forth from
;                     -a to +a in Tx frames. To stay inside an object
;                     that rotates : radius of the part + sqrt(h2+a2)
;                     <= inner radius of the object
;    V x y z          vertex (integers, about -70..70)
;    F c a b c [d..]  convex face of 3 to 8 vertices (indices 0..),
;                     c = plane 1..3 in mode T ; in mode S, c = 3 :
;                     face always dark (colour 1), otherwise lit
;                     Mode S : vertices counter-clockwise seen from
;                     the outside.
;    E a b            extra edge (mode T) ; the edges
;                     of the faces are added automatically
;    L i r g b        colour i (0-14) of the palette, r g b = 0..15
;                     (colour 15 stays the white of the menu)
;    X m NAME.TEX     texture of the object : OBJ\NAME.TEX, 128x128 pixels
;                     RGB565 (32768 bytes). In MAPPING rendering, all the
;                     faces with a W line are textured, whatever
;                     their material (colour of the other renderings)
;    W u0 v0 u1 v1..  texture coordinates (0..255) of the vertices of the
;                     previous face (the texture repeats every 128 ;
;                     a face must cover less than 128 in each direction)
;    C m r g b        material m (1..4) of colour r g b (0..15), mode S :
;                     the faces "F m ..." take this colour, with
;                     their own shading in all renderings. As soon as a
;                     C line exists, the 16-colour palette is computed
;                     (14 shades shared between the materials) and
;                     "F 3" is no longer the dark flat face of the old format.
;    T f n fr bk      BSP tree node (mode S, single part only) :
;                     faces f..f+n-1 in the plane of face f, children
;                     front / back (-1 = none), node 0 = root.
;                     Written by OUTILS\BSPOBJ.PY : exact drawing order
;                     whatever the angle (no more flickering faces)
;==============================================================

MAXV        equ     256                 ; max vertices
MAXF        equ     200                 ; max faces
MAXE        equ     400                 ; max edges
MAXP        equ     8                   ; max parts
MAXMAT      equ     4                   ; max materials (colours) per object
MAXT        equ     MAXF                ; max BSP nodes
TSZ         equ     24                  ; node : w face, w count, w front,
                                        ; w back, l nx,ny,nz, l d
MAXOBJ      equ     32                  ; max object files
OBJTXT      equ     16384               ; max size of an object file
TITLESZ     equ     22

FACESZ      equ     16                  ; face record
F_N         equ     0                   ; w number of vertices
F_COL       equ     2                   ; w plane (T)
F_IDX       equ     4                   ; 8 bytes : indices
F_LEN       equ     12                  ; w length of the normal (S)

PARTSZ      equ     14
P_FIRST     equ     0                   ; w 1st vertex
P_COUNT     equ     2                   ; w number of vertices
P_DELAY     equ     4                   ; w delay in frames
P_BR        equ     6                   ; w bounce : height h (0 = none)
P_BS        equ     8                   ; w a, w T, w Tx (see command B)

;--------------------------------------------------------------
; scanobjs : lists OBJ\*.OBJ (sorted by name) -> objnames, nobjs
;--------------------------------------------------------------
scanobjs:
            clr.w   nobjs
            pea     dta                 ; Fsetdta
            move.w  #$1a,-(sp)
            trap    #1
            addq.l  #6,sp
            clr.w   -(sp)               ; Fsfirst
            pea     objmask
            move.w  #$4e,-(sp)
            trap    #1
            addq.l  #8,sp
.lp:        tst.l   d0
            bne.s   .sort
            move.w  nobjs,d0
            cmp.w   #MAXOBJ,d0
            bhs.s   .sort
            mulu    #NAMESZ,d0
            lea     objnames,a0
            adda.l  d0,a0
            lea     dta+30,a1
            moveq   #NAMESZ-2,d1
.cp:        move.b  (a1)+,(a0)+
            dbeq    d1,.cp
            clr.b   (a0)
            addq.w  #1,nobjs
            move.w  #$4f,-(sp)          ; Fsnext
            trap    #1
            addq.l  #2,sp
            bra.s   .lp

.sort:      lea     objnames,a0         ; alphabetical order
            move.w  nobjs,d0
            bra     sortnames

;--------------------------------------------------------------
; sortnames : bubble sort of d0 names (NAMESZ bytes) at a0
;--------------------------------------------------------------
sortnames:
            move.l  a0,a4
            move.w  d0,d7
            subq.w  #2,d7
            bmi.s   .out
.pass:      moveq   #0,d6               ; swap done ?
            move.l  a4,a0
            move.w  d7,d5
.cmp:       lea     NAMESZ(a0),a1
            move.l  a0,a2
            move.l  a1,a3
.c1:        move.b  (a2)+,d0
            move.b  (a3)+,d1
            cmp.b   d1,d0
            bhi.s   .swap
            blo.s   .next
            tst.b   d0
            bne.s   .c1
            bra.s   .next
.swap:      moveq   #NAMESZ-1,d1
            move.l  a0,a2
            move.l  a1,a3
.s1:        move.b  (a2),d0
            move.b  (a3),(a2)+
            move.b  d0,(a3)+
            dbra    d1,.s1
            moveq   #1,d6
.next:      move.l  a1,a0
            dbra    d5,.cmp
            tst.w   d6
            bne.s   .pass
.out:       rts

;--------------------------------------------------------------
; nextobj : O key -> next object
;--------------------------------------------------------------
; marktex : remembers the kind of the current object for the auto mode
;   objtex : bit 7 = known, bit 1 = solid, bit 0 = texture
marktex:
            move.w  curobj,d0
            bmi.s   .out
            cmp.w   #MAXOBJ,d0
            bhs.s   .out
            moveq   #-128,d1            ; $80 : known
            tst.w   objmode
            beq.s   .t
            or.b    #2,d1               ; solid
            tst.w   texmat
            bmi.s   .t
            or.b    #1,d1               ; texture (and solid)
.t:         lea     objtex,a0
            move.b  d1,(a0,d0.w)
.out:       rts

;--------------------------------------------------------------
; autonext : automatic change. Next object ; after the
;   last one, next mode :
;     0 = 16 colours      : all objects
;     1 = True Color      : transparent / wireframe objects
;     2 = TC Gouraud  3 = TC Cel  4 = TC Phong  5 = TC Chrome :
;                           solid objects
;     6 = TC Mapping      : textured solid objects
;   a step without objects is skipped ; without VGA : 16 colours only
;--------------------------------------------------------------
AUTOSHD:    dc.w    0,0,0,2,1,3,4       ; rendering (shade) of each step
AUTOMSK:    dc.b    0,2,2,2,2,2,3       ; bits of objtex to test
AUTOVAL:    dc.b    0,0,2,2,2,2,3       ; expected value
NSTAGE      equ     7

autonext:
            movem.l d0-d5/a0,-(sp)
            move.w  nobjs,d1
            beq     .nx
            move.w  curobj,d0
            addq.w  #1,d0
            moveq   #0,d3               ; 1 = the step has changed
            moveq   #NSTAGE,d4          ; guard : one round of steps at most
.lp:        cmp.w   d1,d0
            blo.s   .chk
            moveq   #0,d0               ; last object passed : next step
            tst.w   vgamon
            beq.s   .chk                ; no True Color : 16 colours
            moveq   #1,d3
            move.w  autostage,d2
            addq.w  #1,d2
            subq.w  #1,d4
            bpl.s   .s1
            moveq   #0,d2               ; no object anywhere : 16 colours
.s1:        cmp.w   #NSTAGE,d2
            blo.s   .st
            moveq   #0,d2
.st:        move.w  d2,autostage
.chk:       cmp.w   #MAXOBJ,d0
            bhs.s   .go
            lea     objtex,a0
            move.b  (a0,d0.w),d5
            bpl.s   .go                 ; not loaded yet : show it
            move.w  autostage,d2
            and.b   AUTOMSK(pc,d2.w),d5
            cmp.b   AUTOVAL(pc,d2.w),d5
            beq.s   .go
            addq.w  #1,d0               ; not for this step
            bra     .lp
.go:        tst.w   d3
            beq.s   .obj
            move.w  autostage,d2        ; new step : rendering + video
            add.w   d2,d2
            lea     AUTOSHD(pc),a0
            move.w  (a0,d2.w),shade
            moveq   #0,d2
            tst.w   autostage
            sne     d2
            and.w   #1,d2               ; 0 = 16 colours, 1 = True Color
            cmp.w   tcmode,d2
            beq.s   .obj
            move.w  d2,tcmode
            movem.l d0-d1,-(sp)
            bsr     setvideo
            movem.l (sp)+,d0-d1
.obj:       subq.w  #1,d0
            move.w  d0,curobj           ; nextobj takes the next one
.nx:        movem.l (sp)+,d0-d5/a0
            bra     nextobj

nextobj:
            move.w  nobjs,d1
            beq.s   .out
            move.w  curobj,d0
            addq.w  #1,d0
            cmp.w   d1,d0
            blo.s   .ok
            moveq   #0,d0
.ok:        move.w  d0,curobj
            move.w  mvalid,d2           ; was an object displayed ?
            beq.s   .nm
            bsr     mstart              ; morphing source
.nm:        bsr     loadobj
            bsr     d3dverts            ; vertices to the DSP
            bsr     marktex
            tst.w   d2
            beq.s   .nm2
            move.w  #MORPHN,morph
            bsr     d3dmorphup          ; the two clouds to the DSP
.nm2:
            bsr     getclk              ; restart for a full duration
            move.l  d0,objclk
.out:       rts

;--------------------------------------------------------------
; loadobj : loads OBJ\<objnames[curobj]> (or the built-in object
;           if there is no file) then parses it
;--------------------------------------------------------------
loadobj:
            movem.l d0-d7/a0-a6,-(sp)
            clr.w   objerr
            tst.w   nobjs
            beq     .builtin

            lea     objpath,a0          ; path = "OBJ\" + name
            lea     objmask,a1
            moveq   #3,d1
.p1:        move.b  (a1)+,(a0)+
            dbra    d1,.p1
            move.w  curobj,d1
            mulu    #NAMESZ,d1
            lea     objnames,a1
            adda.l  d1,a1
.p2:        move.b  (a1)+,(a0)+
            bne.s   .p2

            clr.w   -(sp)               ; Fopen
            pea     objpath
            move.w  #$3d,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            bmi.s   .builtin
            move.w  d0,d7
            pea     objtext             ; Fread(h,OBJTXT-1,buffer)
            move.l  #OBJTXT-1,-(sp)
            move.w  d7,-(sp)
            move.w  #$3f,-(sp)
            trap    #1
            lea     12(sp),sp
            move.l  d0,d6
            move.w  d7,-(sp)            ; Fclose
            move.w  #$3e,-(sp)
            trap    #1
            addq.l  #4,sp
            tst.l   d6
            ble.s   .builtin
            lea     objtext,a4
            lea     (a4,d6.l),a5
            ; default name = file name
            move.w  curobj,d1
            mulu    #NAMESZ,d1
            lea     objnames,a1
            adda.l  d1,a1
            lea     objtitle,a0
.p3:        move.b  (a1)+,(a0)+
            bne.s   .p3
            bsr     parseobj
            tst.w   objerr
            beq.s   .pal

.builtin:   lea     defobj,a4           ; built-in object : the cube
            lea     defobjend,a5
            lea     objtitle,a0
            lea     t_defobj,a1
.p4:        move.b  (a1)+,(a0)+
            bne.s   .p4
            bsr     parseobj

.pal:       bsr     uvaffine            ; planar textures : faces in one piece
            bsr     loadtex             ; textures of the materials (X)
            bsr     msample             ; point cloud (morphing)
            bsr     objradius           ; radius on screen (path)
            tst.w   custpal             ; palette : the file's one or
            bne.s   .setp               ; the mode's one
            lea     palT,a0
            tst.w   objmode
            beq.s   .cpp
            lea     palS,a0
.cpp:       lea     objpal,a1
            moveq   #15,d0
.cp:        move.w  (a0)+,(a1)+
            dbra    d0,.cp
.setp:      bsr     matpal              ; materials : computed palette
            move.w  #TEXTCOL,objpal+30  ; colour 15 = menu white, always
            bsr     mkramp              ; shades of the True Color mode
            bsr     d3dramps            ; ramps to the DSP as well
            pea     objpal              ; Setpalette
            move.w  #6,-(sp)
            trap    #14
            addq.l  #6,sp
            movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; parseobj : parses the text a4..a5 -> vertices, faces, edges
;            objerr = 1 if the file is incorrect
;--------------------------------------------------------------
parseobj:
            lea     fseen,a0            ; smoothing of the shades : restart from zero
            move.w  #MAXF-1,d0
.zs:        move.w  #$8000,(a0)+
            dbra    d0,.zs
            clr.w   nv
            clr.w   nf
            clr.w   ne
            clr.w   nt
            lea     mattexn,a0          ; no texture
            moveq   #MAXMAT-1,d0
.ztn:       clr.b   (a0)
            lea     14(a0),a0
            dbra    d0,.ztn
            lea     fuv,a0
            move.w  #MAXF*16/4-1,d0
.zuv:       clr.l   (a0)+
            dbra    d0,.zuv
            lea     fhasw,a0
            move.w  #MAXF/2-1,d0
.zhw:       clr.w   (a0)+
            dbra    d0,.zhw
            clr.w   matmode
            lea     matdef,a0
            clr.l   (a0)+
            clr.l   (a0)+
            move.w  #1,nmat
            clr.w   lflat
            clr.w   objmode
            clr.w   custpal
            move.w  #1,np
            lea     parts,a0
            clr.w   P_FIRST(a0)
            clr.w   P_DELAY(a0)
            clr.w   P_BR(a0)

.line:      cmpa.l  a5,a4
            bhs     .done
            bsr     skipsp
            cmpa.l  a5,a4
            bhs     .done
            move.b  (a4)+,d0
            cmp.b   #'a',d0             ; lower case -> upper case
            blo.s   .up
            cmp.b   #'z',d0
            bhi.s   .up
            sub.b   #32,d0
.up:        cmp.b   #'V',d0
            beq     .vert
            cmp.b   #'F',d0
            beq     .face
            cmp.b   #'E',d0
            beq     .edge
            cmp.b   #'P',d0
            beq     .part
            cmp.b   #'M',d0
            beq     .mode
            cmp.b   #'N',d0
            beq     .name
            cmp.b   #'L',d0
            beq     .pal
            cmp.b   #'B',d0
            beq     .bounce
            cmp.b   #'T',d0
            beq     .tree
            cmp.b   #'C',d0
            beq     .matc
            cmp.b   #'X',d0
            beq     .tex
            cmp.b   #'W',d0
            beq     .uv
.skip:      bsr     skipline            ; comment / empty line
            bra     .line

            ; --- V x y z ---
.vert:      move.w  nv,d7
            cmp.w   #MAXV,d7
            bhs     .err
            mulu    #6,d7
            lea     objv,a3
            adda.l  d7,a3
            bsr     readint
            bcs     .err
            move.w  d0,(a3)+
            bsr     readint
            bcs     .err
            move.w  d0,(a3)+
            bsr     readint
            bcs     .err
            move.w  d0,(a3)+
            addq.w  #1,nv
            bra.s   .skip

            ; --- F c a b c ... ---
.face:      move.w  nf,d7
            cmp.w   #MAXF,d7
            bhs     .err
            mulu    #FACESZ,d7
            lea     objf,a3
            adda.l  d7,a3
            bsr     readint
            bcs     .err
            cmp.w   #1,d0               ; plane 1..3 (T) / material 1..4 (S)
            bge.s   .c1
            moveq   #1,d0
.c1:        cmp.w   #MAXMAT,d0
            ble.s   .c2
            moveq   #MAXMAT,d0
.c2:        move.w  d0,F_COL(a3)
            moveq   #0,d6               ; number of vertices
            lea     F_IDX(a3),a2
.fi:        bsr     readint
            bcs.s   .fe
            cmp.w   #8,d6
            bhs.s   .fe
            move.b  d0,(a2)+
            addq.w  #1,d6
            bra.s   .fi
.fe:        cmp.w   #3,d6
            blo     .err
            move.w  d6,F_N(a3)
            addq.w  #1,nf
            bra     .skip

            ; --- E a b ---
.edge:      move.w  ne,d7
            cmp.w   #MAXE,d7
            bhs     .err
            add.w   d7,d7
            lea     obje,a3
            adda.w  d7,a3
            bsr     readint
            bcs     .err
            move.b  d0,(a3)+
            bsr     readint
            bcs     .err
            move.b  d0,(a3)+
            addq.w  #1,ne
            bra     .skip

            ; --- P delay ---
.part:      move.w  np,d7
            cmp.w   #MAXP,d7
            bhs     .err
            bsr     readint
            bcs     .err
            mulu    #PARTSZ,d7
            lea     parts,a3
            adda.l  d7,a3
            move.w  nv,P_FIRST(a3)
            move.w  d0,P_DELAY(a3)
            clr.w   P_BR(a3)
            addq.w  #1,np
            bra     .skip

            ; --- B h a T Tx : bounce of the current part ---
.bounce:    move.w  np,d7
            subq.w  #1,d7
            mulu    #PARTSZ,d7
            lea     parts,a3
            adda.l  d7,a3
            bsr     readint             ; h
            bcs     .err
            tst.w   d0
            ble     .err
            cmp.w   #70,d0
            bhi     .err
            move.w  d0,P_BR(a3)
            bsr     readint             ; a
            bcs     .err
            tst.w   d0
            bmi     .err
            cmp.w   #70,d0
            bhi     .err
            move.w  d0,P_BS(a3)
            bsr     readint             ; T
            bcs     .err
            cmp.w   #2,d0
            blt     .err
            cmp.w   #1000,d0
            bhi     .err
            move.w  d0,P_BS+2(a3)
            bsr     readint             ; Tx
            bcs     .err
            cmp.w   #2,d0
            blt     .err
            cmp.w   #1000,d0
            bhi     .err
            move.w  d0,P_BS+4(a3)
            bra     .skip

            ; --- T f n front back : BSP node ---
.tree:      move.w  nt,d7
            cmp.w   #MAXT,d7
            bhs     .err
            mulu    #TSZ,d7
            lea     objt,a3
            adda.l  d7,a3
            moveq   #3,d6
.tl:        bsr     readint
            bcs     .err
            move.w  d0,(a3)+
            dbra    d6,.tl
            addq.w  #1,nt
            bra     .skip

            ; --- C m r g b : material ---
.matc:      bsr     readint
            bcs     .err
            subq.w  #1,d0
            bmi     .err
            cmp.w   #MAXMAT,d0
            bhs     .err
            move.w  d0,d7
            add.w   d0,d0
            lea     matdef,a3
            move.w  #1,(a3,d0.w)
            move.w  d7,d0
            mulu    #6,d0
            lea     matrgb,a3
            adda.l  d0,a3
            moveq   #2,d6
.mc:        bsr     readint
            bcs     .err
            and.w   #15,d0
            move.w  d0,(a3)+
            dbra    d6,.mc
            move.w  #1,matmode
            bra     .skip

            ; --- X m NAME.TEX : texture of material m ---
.tex:       bsr     readint
            bcs     .err
            subq.w  #1,d0
            bmi     .err
            cmp.w   #MAXMAT,d0
            bhs     .err
            mulu    #14,d0
            lea     mattexn,a3
            adda.l  d0,a3
            bsr     skipsp
            moveq   #12,d7
.tn:        cmpa.l  a5,a4
            bhs.s   .te
            move.b  (a4),d0
            cmp.b   #' ',d0
            bls.s   .te
            move.b  d0,(a3)+
            addq.l  #1,a4
            dbra    d7,.tn
.te:        clr.b   (a3)
            bra     .skip

            ; --- W u v ... : texture of the last face ---
.uv:        move.w  nf,d7
            beq     .skip
            subq.w  #1,d7
            lea     fhasw,a3            ; this face has a texture
            st      (a3,d7.w)
            lsl.w   #4,d7
            lea     fuv,a3
            adda.w  d7,a3
            moveq   #15,d6
.uvl:       bsr     readint
            bcs     .skip
            move.b  d0,(a3)+
            dbra    d6,.uvl
            bra     .skip

            ; --- M T / M S ---
.mode:      bsr     skipsp
            clr.w   objmode
            move.b  (a4),d0
            and.b   #$df,d0
            cmp.b   #'S',d0
            bne     .skip
            move.w  #1,objmode
            bra     .skip

            ; --- N name ---
.name:      bsr     skipsp
            lea     objtitle,a3
            moveq   #TITLESZ-2,d7
.nl:        cmpa.l  a5,a4
            bhs.s   .ne
            move.b  (a4),d0
            cmp.b   #13,d0
            beq.s   .ne
            cmp.b   #10,d0
            beq.s   .ne
            move.b  d0,(a3)+
            addq.l  #1,a4
            dbra    d7,.nl
.ne:        clr.b   (a3)
            bra     .skip

            ; --- L i r g b ---
.pal:       bsr     readint
            bcs     .err
            and.w   #15,d0
            add.w   d0,d0
            lea     objpal,a3
            adda.w  d0,a3
            moveq   #0,d5
            moveq   #2,d7
.pc:        bsr     readint
            bcs     .err
            and.w   #15,d0
            lsr.w   #1,d0               ; STE : bit 0 in position 3
            bcc.s   .pb
            addq.w  #8,d0
.pb:        lsl.w   #4,d5
            or.w    d0,d5
            dbra    d7,.pc
            move.w  d5,(a3)
            move.w  #1,custpal
            bra     .skip

.err:       move.w  #1,objerr
            rts

            ; --- end : lengths of the parts, checks ---
.done:      lea     parts,a3
            move.w  np,d7
            subq.w  #1,d7
.pl:        move.w  nv,d0               ; end = start of the next part
            tst.w   d7
            beq.s   .pz
            move.w  PARTSZ+P_FIRST(a3),d0
.pz:        sub.w   P_FIRST(a3),d0
            move.w  d0,P_COUNT(a3)
            lea     PARTSZ(a3),a3
            dbra    d7,.pl

            move.w  nv,d1               ; indices < nv ?
            beq.s   .err
            move.w  nf,d7
            beq.s   .chke
            subq.w  #1,d7
            lea     objf,a3
.cf:        move.w  F_N(a3),d6
            subq.w  #1,d6
            lea     F_IDX(a3),a2
.cfi:       moveq   #0,d0
            move.b  (a2)+,d0
            cmp.w   d1,d0
            bhs.s   .err
            dbra    d6,.cfi
            lea     FACESZ(a3),a3
            dbra    d7,.cf
.chke:      move.w  ne,d7
            beq     .tb
            subq.w  #1,d7
            lea     obje,a3
.ce:        moveq   #0,d0
            move.b  (a3)+,d0
            cmp.w   d1,d0
            bhs     .err
            dbra    d7,.ce

            ; BSP tree : only mode S and a single part
.tb:        tst.w   objmode
            beq.s   .tno
            cmp.w   #2,np
            blo.s   .tv
.tno:       clr.w   nt
.tv:        move.w  nt,d7
            beq.s   .ok
            lea     objt,a3
            moveq   #0,d6               ; node number
.tc:        move.w  (a3),d0             ; 1st face
            bmi     .err
            move.w  2(a3),d1            ; number of faces
            ble     .err
            add.w   d0,d1
            cmp.w   nf,d1
            bhi     .err
            move.w  4(a3),d0            ; children : -1 or after this node
            bsr     .tchk
            bcs     .err
            move.w  6(a3),d0
            bsr     .tchk
            bcs     .err
            lea     TSZ(a3),a3
            addq.w  #1,d6
            cmp.w   d7,d6
            blo.s   .tc
            bra     .ok
.tchk:      cmp.w   #-1,d0              ; C = 1 if invalid child
            beq.s   .tk
            cmp.w   d6,d0
            ble.s   .tbad
            cmp.w   d7,d0
            bge.s   .tbad
.tk:        and.b   #$fe,ccr
            rts
.tbad:      or.b    #1,ccr
            rts

.ok:        bsr     normmat             ; materials of the faces
            tst.w   objmode
            beq     autoedges           ; mode T : edges of the faces
            bsr     bestcorner          ; mode S : 3 first safe vertices,
            bsr     bspplanes           ;   planes of the BSP tree,
            bsr     facelens            ;   face normals,
            bsr     buildadj            ;   neighbours (cel outlines)
            bra     vertnorms           ;          and of the vertices

;--------------------------------------------------------------
; autoedges : adds the edges of the faces (no duplicates)
;--------------------------------------------------------------
autoedges:
            move.w  nf,d7
            beq     .out
            subq.w  #1,d7
            lea     objf,a3
.f:         move.w  F_N(a3),d6
            subq.w  #1,d6
            lea     F_IDX(a3),a2
            moveq   #0,d5               ; current / next vertex
.s:         move.b  (a2,d5.w),d0
            move.w  d5,d4
            addq.w  #1,d4
            cmp.w   F_N(a3),d4
            blo.s   .s1
            moveq   #0,d4
.s1:        move.b  (a2,d4.w),d1
            cmp.b   d1,d0               ; edge (min,max)
            bls.s   .s2
            exg     d0,d1
.s2:        lea     obje,a1             ; already there ?
            move.w  ne,d3
            beq.s   .add
            subq.w  #1,d3
.sr:        cmp.b   (a1),d0
            bne.s   .sn
            cmp.b   1(a1),d1
            beq.s   .nx
.sn:        addq.l  #2,a1
            dbra    d3,.sr
.add:       cmp.w   #MAXE,ne
            bhs.s   .nx
            move.w  ne,d3
            add.w   d3,d3
            lea     obje,a1
            move.b  d0,(a1,d3.w)
            move.b  d1,1(a1,d3.w)
            addq.w  #1,ne
.nx:        addq.w  #1,d5
            dbra    d6,.s
            lea     FACESZ(a3),a3
            dbra    d7,.f
.out:       rts

;--------------------------------------------------------------
; uvaffine : a textured face of more than 3 vertices whose u,v are an
;   affine function of the position in its plane (planar mapping, the
;   usual case : logo from an image) is drawn in one piece (fhasw = 1)
;   instead of a fan of triangles (fhasw = -1) : the same picture, but
;   much less work (fewer edges to trace, longer lines). Test : for
;   each vertex k from the 4th one, in the 2 axes of the plane,
;   P(k)-P0 = a (P1-P0) + b (P2-P0) ; its u,v must be
;   uv0 + a (uv1-uv0) + b (uv2-uv0) within 2 texels.
;--------------------------------------------------------------
uvaffine:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  nf,d7
            beq     .out
            subq.w  #1,d7
            lea     objf,a3
            lea     fhasw,a4
            lea     fuv,a5
.f:         tst.b   (a4)
            beq     .nx
            cmp.w   #3,F_N(a3)
            bls     .nx
            move.w  d7,-(sp)
            ; --- axes of the plane : the 2 others than the largest
            ;     component of the normal (offsets d5, d6 in a vertex) ---
            lea     F_IDX(a3),a2
            lea     objv,a1
            bsr     cross3              ; d0,d1,d2 = nx,ny,nz
            tst.l   d0
            bpl.s   .x0
            neg.l   d0
.x0:        tst.l   d1
            bpl.s   .x1
            neg.l   d1
.x1:        tst.l   d2
            bpl.s   .x2
            neg.l   d2
.x2:        moveq   #2,d5               ; |nx| largest : y, z
            moveq   #4,d6
            cmp.l   d0,d1
            bgt.s   .ny
            cmp.l   d0,d2
            bgt.s   .nz
            bra.s   .ax
.ny:        cmp.l   d1,d2
            bgt.s   .nz
            moveq   #0,d5               ; |ny| largest : x, z
            moveq   #4,d6
            bra.s   .ax
.nz:        moveq   #0,d5               ; |nz| largest : x, y
            moveq   #2,d6
            ; --- vertices on these 2 axes, relative to P0 -> uapb ---
.ax:        lea     objv,a6
            lea     uapb,a0
            lea     F_IDX(a3),a2
            moveq   #0,d0
            move.b  (a2),d0
            mulu    #6,d0
            lea     (a6,d0.l),a1
            move.w  (a1,d5.w),d2        ; P0
            move.w  (a1,d6.w),d3
            move.w  F_N(a3),d4
            subq.w  #1,d4
.cp:        moveq   #0,d0
            move.b  (a2)+,d0
            mulu    #6,d0
            lea     (a6,d0.l),a1
            move.w  (a1,d5.w),d1
            sub.w   d2,d1
            move.w  d1,(a0)+
            move.w  (a1,d6.w),d1
            sub.w   d3,d1
            move.w  d1,(a0)+
            dbra    d4,.cp
            ; --- det = e1i e2j - e1j e2i ---
            lea     uapb,a0
            movem.w 4(a0),d0-d3         ; e1i e1j e2i e2j
            move.l  d0,d4
            muls.l  d3,d4
            move.l  d1,d5
            muls.l  d2,d5
            sub.l   d5,d4               ; det
            beq     .bad
            move.l  d4,uadet
            ; --- vertices k = 3 .. n-1 ---
            moveq   #3,d7
.k:         movem.w (a0,d7.w*4),d5-d6   ; eki ekj
            ; an = eki e2j - ekj e2i
            move.l  d5,d4
            muls.l  d3,d4
            move.l  d6,d0               ; (ekj)
            muls.l  d2,d0
            sub.l   d0,d4
            move.l  d4,uaan
            ; bn = e1i ekj - e1j eki
            movem.w 4(a0),d0-d1         ; (e1i e1j back)
            move.l  d0,d4
            muls.l  d6,d4
            move.l  d1,d0
            muls.l  d5,d0
            sub.l   d0,d4
            move.l  d4,uabn
            ; --- u (offset 0) then v (offset 1) ---
            moveq   #0,d6
.c:         moveq   #0,d0               ; uc0
            move.b  (a5,d6.w),d0
            moveq   #0,d1               ; uc1 - uc0
            move.b  2(a5,d6.w),d1
            sub.l   d0,d1
            moveq   #0,d4               ; uc2 - uc0
            move.b  4(a5,d6.w),d4
            sub.l   d0,d4
            move.w  d7,d5               ; ukc - uc0
            add.w   d5,d5
            add.w   d6,d5
            moveq   #0,d2
            move.b  (a5,d5.w),d2
            sub.l   d0,d2
            muls.l  uadet,d2            ; (ukc-uc0) det
            muls.l  uaan,d1
            sub.l   d1,d2               ; - an (uc1-uc0)
            muls.l  uabn,d4
            sub.l   d4,d2               ; - bn (uc2-uc0)
            bpl.s   .p
            neg.l   d2
.p:         move.l  uadet,d0            ; |diff| <= 2 |det| ?
            bpl.s   .p2
            neg.l   d0
.p2:        add.l   d0,d0
            cmp.l   d0,d2
            bhi.s   .bad
            addq.w  #1,d6
            cmp.w   #2,d6
            blo.s   .c
            movem.w 8(a0),d2-d3         ; (e2i e2j back)
            addq.w  #1,d7
            cmp.w   F_N(a3),d7
            blo     .k
            move.b  #1,(a4)             ; planar : in one piece
            bra.s   .ok
.bad:       st      (a4)                ; as triangles
.ok:        move.w  (sp)+,d7
.nx:        lea     FACESZ(a3),a3
            addq.l  #1,a4
            lea     16(a5),a5
            dbra    d7,.f
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; facelens : length of the normal of each face (mode S)
;            |(v1-v0) x (v2-v0)|, rotation invariant
;--------------------------------------------------------------
facelens:
            move.w  nf,d7
            beq.s   .out
            subq.w  #1,d7
            lea     objf,a3
.f:         lea     F_IDX(a3),a2
            lea     objv,a1
            bsr     cross3              ; d0,d1,d2 = normal (long)
            muls.l  d0,d0               ; sum of the squares
            muls.l  d1,d1
            muls.l  d2,d2
            add.l   d1,d0
            add.l   d2,d0
            bsr     isqrt
            tst.w   d0
            bne.s   .nz
            moveq   #1,d0
.nz:        move.w  d0,F_LEN(a3)
            lea     FACESZ(a3),a3
            dbra    d7,.f
.out:       rts

;--------------------------------------------------------------
; cross3 : a1 = vertices (x,y,z words), a2 = 3 indices (bytes)
;          -> d0,d1,d2 = (v1-v0) x (v2-v0)
;--------------------------------------------------------------
cross3:
            movem.l d3-d7/a4,-(sp)
            moveq   #0,d0
            move.b  (a2),d0
            mulu    #6,d0
            lea     (a1,d0.l),a4        ; v0
            moveq   #0,d0
            move.b  1(a2),d0
            mulu    #6,d0
            move.w  (a1,d0.l),d3        ; v1 - v0
            sub.w   (a4),d3
            move.w  2(a1,d0.l),d4
            sub.w   2(a4),d4
            move.w  4(a1,d0.l),d5
            sub.w   4(a4),d5
            moveq   #0,d0
            move.b  2(a2),d0
            mulu    #6,d0
            move.w  (a1,d0.l),d6        ; v2 - v0
            sub.w   (a4),d6
            move.w  2(a1,d0.l),d7
            sub.w   2(a4),d7
            move.w  4(a1,d0.l),d2
            sub.w   4(a4),d2
            ; nx = ay*bz - az*by
            move.w  d4,d0
            muls    d2,d0
            move.w  d5,d1
            muls    d7,d1
            sub.l   d1,d0
            move.l  d0,-(sp)
            ; ny = az*bx - ax*bz
            move.w  d5,d0
            muls    d6,d0
            move.w  d3,d1
            muls    d2,d1
            sub.l   d1,d0
            move.l  d0,-(sp)
            ; nz = ax*by - ay*bx
            move.w  d3,d2
            muls    d7,d2
            move.w  d4,d1
            muls    d6,d1
            sub.l   d1,d2
            move.l  (sp)+,d1
            move.l  (sp)+,d0
            movem.l (sp)+,d3-d7/a4
            rts

;--------------------------------------------------------------
; isqrt : d0.l -> d0.w = integer square root
;--------------------------------------------------------------
isqrt:
            movem.l d1-d3,-(sp)
            moveq   #0,d1               ; result
            move.l  #$40000000,d2       ; bit
.b:         cmp.l   d0,d2
            bls.s   .l
            lsr.l   #2,d2
            bne.s   .b
            bra.s   .e
.l:         move.l  d1,d3
            add.l   d2,d3
            cmp.l   d3,d0
            blo.s   .n
            sub.l   d3,d0
            lsr.l   #1,d1
            add.l   d2,d1
            bra.s   .m
.n:         lsr.l   #1,d1
.m:         lsr.l   #2,d2
            bne.s   .l
.e:         move.l  d1,d0
            movem.l (sp)+,d1-d3
            rts

;--------------------------------------------------------------
; skipsp / skipline / readint : reading the text (a4 -> a5)
;--------------------------------------------------------------
skipsp:
.s:         cmpa.l  a5,a4
            bhs.s   .out
            move.b  (a4),d0
            cmp.b   #' ',d0
            beq.s   .n
            cmp.b   #9,d0
            bne.s   .out
.n:         addq.l  #1,a4
            bra.s   .s
.out:       rts

skipline:
.s:         cmpa.l  a5,a4
            bhs.s   .out
            cmp.b   #10,(a4)+
            bne.s   .s
.out:       rts

; readint : d0.l = next integer of the line ; C = 1 if none
readint:
            movem.l d1-d3,-(sp)
.s:         cmpa.l  a5,a4
            bhs.s   .none
            move.b  (a4),d1
            cmp.b   #' ',d1
            beq.s   .sk
            cmp.b   #9,d1
            beq.s   .sk
            cmp.b   #',',d1
            beq.s   .sk
            moveq   #0,d2               ; sign
            cmp.b   #'-',d1
            bne.s   .d
            moveq   #1,d2
            addq.l  #1,a4
.d:         moveq   #0,d0
            moveq   #0,d3               ; digits read
.dl:        cmpa.l  a5,a4
            bhs.s   .end
            moveq   #0,d1
            move.b  (a4),d1
            sub.b   #'0',d1
            cmp.b   #9,d1
            bhi.s   .end
            mulu    #10,d0
            add.l   d1,d0
            addq.l  #1,a4
            addq.w  #1,d3
            bra.s   .dl
.sk:        addq.l  #1,a4
            bra.s   .s
.end:       tst.w   d3
            beq.s   .none
            tst.w   d2
            beq.s   .pos
            neg.l   d0
.pos:       movem.l (sp)+,d1-d3
            andi    #$fe,ccr
            rts
.none:      movem.l (sp)+,d1-d3
            ori     #1,ccr
            rts

;==============================================================
; RENDERING
;==============================================================

;--------------------------------------------------------------
; transform : rotation + projection of all the vertices
;             each part has its delay (angles = t - delay)
;             -> rv (rotated x,y,z) and proj (screen x,y)
;--------------------------------------------------------------
transform:
            bsr     mpath               ; position of the object on screen
            tst.w   morph               ; morphing in progress
            bne     mtransform
            clr.w   mdraw
            move.l  a0,-(sp)
            lea     vnorm,a4            ; normals (Gouraud)
            lea     vint,a0             ; intensities per vertex
            clr.w   gour
            tst.w   tcmode
            beq.s   .ng
            move.w  objmode,gour        ; True Color + solid object
.ng:        clr.w   phong               ; rendering of solid objects in TC :
            clr.w   cel                 ; Gouraud / fake Phong / cel
            move.l  #ramp,curramp
            move.l  #ramp2,curramp2
            tst.w   gour
            beq     .ns
            move.l  #phtex,curtex
            cmp.w   #1,shade
            beq.s   .pk
            cmp.w   #3,shade
            bne.s   .nc
.pk:        tst.w   phok                ; first use : compute the maps
            bne.s   .pk2                ; (once, ~1/2 s)
            bsr     genph
            move.w  #1,phok
            bsr     mkramp
            bsr     d3dramps            ; ramps to the DSP as well
.pk2:       cmp.w   #1,shade
            beq.s   .ph
            cmp.w   #3,shade            ; chrome : same rendering, other map
            bne.s   .nc
            move.l  #phchr,curtex
.ph:        move.w  #1,phong
            bra.s   .ns
.nc:        cmp.w   #2,shade
            bne.s   .ns
            move.w  #1,cel
            move.l  #rampc,curramp
            move.l  #ramp2c,curramp2
.ns:        move.w  phong,uvmode        ; (per face : setmat)
            lea     objv,a1
            lea     rv,a3
            lea     proj,a2
            lea     parts,a5
            move.w  np,d6
            subq.w  #1,d6
.p:         move.w  tframe,d0           ; angle of this part
            sub.w   P_DELAY(a5),d0
            move.w  d0,-(sp)
            bsr     getsc               ; ax = az = t
            move.w  d1,sinx
            move.w  d2,cosx
            move.w  d1,sinz
            move.w  d2,cosz
            move.w  (sp)+,d0
            add.w   d0,d0               ; ay = 2t
            bsr     getsc
            move.w  d1,siny
            move.w  d2,cosy
            bsr     mkmat               ; matrix + light of this part
            cmpa.l  #parts,a5           ; rotation of the 1st part :
            bne.s   .nb0                ; frame of the bounces
            move.l  sinx,s0x
            move.l  siny,s0y
            move.l  sinz,s0z
.nb0:       clr.l   offx                ; displacement of the part
            clr.w   offz
            tst.w   P_BR(a5)
            beq.s   .nob
            bsr     bounce
.nob:       tst.w   d3don               ; vertices by the DSP (3DREAMS)
            beq.s   .cpuv
            bsr     d3dxform
            bra     .np
.cpuv:      move.w  P_COUNT(a5),d7
            subq.w  #1,d7
            bmi     .np
.v:         movem.w (a1)+,d0-d2         ; x y z
            ; rotation by the matrix of the part (computed once per
            ; frame : 9 muls per vertex instead of 3 successive rotations)
            move.w  d0,d3               ; x' = mxx x + mxy y + mxz z
            muls    mxx,d3
            move.w  d1,d4
            muls    mxy,d4
            add.l   d4,d3
            move.w  d2,d4
            muls    mxz,d4
            add.l   d4,d3
            asl.l   #2,d3
            swap    d3
            move.w  d0,d5               ; y'
            muls    myx,d5
            move.w  d1,d4
            muls    myy,d4
            add.l   d4,d5
            move.w  d2,d4
            muls    myz,d4
            add.l   d4,d5
            asl.l   #2,d5
            swap    d5
            muls    mzx,d0              ; z'
            muls    mzy,d1
            add.l   d1,d0
            muls    mzz,d2
            add.l   d2,d0
            asl.l   #2,d0
            swap    d0
            move.w  d0,d2
            move.w  d3,d0
            move.w  d5,d1
            add.w   offx,d0             ; + bounce
            add.w   offy,d1
            add.w   offz,d2
            move.w  d0,(a3)+
            move.w  d1,(a3)+
            move.w  d2,(a3)+
            add.w   #300,d2             ; distance to the viewer
            move.w  d0,d3               ; screen X = 160 + x*256/z
            ext.l   d3
            asl.l   #8,d3
            divs    d2,d3
            add.w   pathx,d3            ; + path
            bpl.s   .x0                 ; safety : stays on screen
            moveq   #0,d3
.x0:        cmp.w   #319,d3
            ble.s   .x1
            move.w  #319,d3
.x1:        move.w  d3,(a2)+
            move.w  d1,d3               ; screen Y = 100 + y*256/z
            ext.l   d3
            asl.l   #8,d3
            divs    d2,d3
            add.w   pathy,d3
            bpl.s   .y0
            moveq   #0,d3
.y0:        cmp.w   scrhm1,d3
            ble.s   .y1
            move.w  scrhm1,d3
.y1:        move.w  d3,(a2)+
            dbra    d7,.v
            ; 2nd loop (short, fits in the cache) : vertex lighting
            tst.w   gour
            beq     .np
            move.w  P_COUNT(a5),d7
            subq.w  #1,d7
            bmi     .np
.n:
            tst.w   phong               ; fake Phong : (u,v) = 64 + rotated
            beq.s   .nph                ; normal (x, y)
            movem.w (a4),d3-d5
            muls    mxx,d3
            muls    mxy,d4
            add.l   d4,d3
            muls    mxz,d5
            add.l   d5,d3
            asl.l   #2,d3
            swap    d3
            muls    #63,d3
            asr.l   #6,d3
            add.w   #16384,d3
            move.w  d3,2*MAXV(a0)       ; vu
            movem.w (a4),d3-d5
            muls    myx,d3
            muls    myy,d4
            add.l   d4,d3
            muls    myz,d5
            add.l   d5,d3
            asl.l   #2,d3
            swap    d3
            muls    #63,d3
            asr.l   #6,d3
            add.w   #16384,d3
            move.w  d3,4*MAXV(a0)       ; vv
.nph:       movem.w (a4)+,d3-d5         ; Gouraud : normal . light, the
            muls    lox,d3              ; light being brought into the
            muls    loy,d4              ; object's frame (no need to
            add.l   d4,d3               ; rotate the normals)
            muls    loz,d5
            add.l   d5,d3
            asr.l   #8,d3
            asr.l   #6,d3               ; dot product (x 2^14)
            bpl.s   .lp0
            moveq   #0,d3               ; facing away from the light : ambient
.lp0:       mulu    #(127-AMB)*128/64,d3
            lsr.l   #8,d3
            add.w   #AMB*128,d3         ; shade 0..127 (x 128)
            cmp.w   #127*128,d3
            bls.s   .lp1
            move.w  #127*128,d3
.lp1:       move.w  d3,(a0)+
            dbra    d7,.n
.np:        lea     PARTSZ(a5),a5
            dbra    d6,.p
            move.l  (sp)+,a0
            rts

;--------------------------------------------------------------
; mkmat : rotation matrix (Y then X then Z, like rot) in x 2^14 :
;   columns = rotated x, y, z axes ; and light in the frame of
;   the object : lo = transpose(matrix) . L  (n_rotated . L = n . lo)
;--------------------------------------------------------------
mkmat:
            movem.l d0-d5/a0-a1,-(sp)
            move.w  #16384,d0           ; x axis
            moveq   #0,d1
            moveq   #0,d2
            rot     d2,d0,siny,cosy
            rot     d1,d2,sinx,cosx
            rot     d0,d1,sinz,cosz
            move.w  d0,mxx
            move.w  d1,myx
            move.w  d2,mzx
            moveq   #0,d0               ; y axis
            move.w  #16384,d1
            moveq   #0,d2
            rot     d2,d0,siny,cosy
            rot     d1,d2,sinx,cosx
            rot     d0,d1,sinz,cosz
            move.w  d0,mxy
            move.w  d1,myy
            move.w  d2,mzy
            moveq   #0,d0               ; z axis
            moveq   #0,d1
            move.w  #16384,d2
            rot     d2,d0,siny,cosy
            rot     d1,d2,sinx,cosx
            rot     d0,d1,sinz,cosz
            move.w  d0,mxz
            move.w  d1,myz
            move.w  d2,mzz
            lea     mxx,a0              ; lo_j = column j . L
            lea     lox,a1
            moveq   #2,d5
.l:         move.w  (a0),d0
            muls    #LX,d0
            move.w  6(a0),d1
            muls    #LY,d1
            add.l   d1,d0
            move.w  12(a0),d1
            muls    #LZ,d1
            add.l   d1,d0
            asl.l   #2,d0
            swap    d0
            move.w  d0,(a1)+
            addq.l  #2,a0
            dbra    d5,.l
            movem.l (sp)+,d0-d5/a0-a1
            rts

;--------------------------------------------------------------
; bounce : part a5 -> offx/offy (screen frame)
;          vertical : parabola arcs (ball bouncing on the floor),
;            y = h - 2h * 4p(T-p)/T^2   with p = t mod T
;          horizontal : back and forth from -a to +a in Tx frames
;--------------------------------------------------------------
bounce:
            movem.l d0-d7/a0-a1,-(sp)
            moveq   #0,d0
            move.w  tframe,d0
            move.w  P_BS+2(a5),d1       ; T
            divu    d1,d0
            swap    d0                  ; p = t mod T
            moveq   #0,d2
            move.w  d1,d2
            sub.w   d0,d2               ; T - p
            mulu    d0,d2               ; p (T-p)
            lsl.l   #2,d2               ; 4 p (T-p)  (0 .. T^2)
            move.w  P_BR(a5),d3         ; h
            move.w  d3,d4
            add.w   d4,d4               ; 2h
            mulu    d4,d2               ; 2h * 4p(T-p)
            mulu    d1,d1               ; T^2
            divu.l  d1,d2               ; 0 .. 2h
            sub.w   d2,d3               ; y = h - ...  (h = floor, at the bottom)
            move.w  d3,offy

            moveq   #0,d0
            move.w  tframe,d0
            move.w  P_BS+4(a5),d1       ; Tx
            divu    d1,d0
            swap    d0                  ; u = t mod Tx
            move.w  d1,d2
            lsr.w   #1,d2               ; Tx/2
            cmp.w   d2,d0
            blo.s   .fw
            neg.w   d0                  ; way back : Tx - u
            add.w   d1,d0
.fw:        move.w  P_BS(a5),d3         ; a
            move.w  d3,d4
            lsl.w   #2,d4               ; 4a
            mulu    d4,d0
            divu    d1,d0               ; 4a u / Tx : 0 .. 2a
            sub.w   d3,d0               ; -a .. +a
            move.w  d0,offx
            clr.w   offz
            movem.l (sp)+,d0-d7/a0-a1
            rts

;--------------------------------------------------------------
; bestcorner : rotates the vertex list of each face so that
;   the first 3 form the widest angle. Visibility and lighting
;   are computed on these 3 vertices : when nearly aligned
;   (centre faces joined to a single point), screen rounding
;   flipped the sign -> face wrongly hidden (black hole) or dark.
;--------------------------------------------------------------
bestcorner:
            move.w  nf,d7
            beq     .out
            subq.w  #1,d7
            lea     objf,a3
.f:         move.w  F_N(a3),d5
            subq.w  #1,d5               ; n - 1
            lea     F_IDX(a3),a0        ; indices copied twice
            lea     cbuf,a1
            move.w  d5,d6
.c1:        move.b  (a0)+,(a1)+
            dbra    d6,.c1
            lea     F_IDX(a3),a0
            move.w  d5,d6
.c2:        move.b  (a0)+,(a1)+
            dbra    d6,.c2
            moveq   #0,d3               ; best |normal|
            moveq   #0,d4               ; best start
            moveq   #0,d6
.s:         lea     cbuf,a2
            adda.w  d6,a2
            lea     objv,a1
            bsr     cross3
            tst.l   d0
            bpl.s   .p0
            neg.l   d0
.p0:        tst.l   d1
            bpl.s   .p1
            neg.l   d1
.p1:        tst.l   d2
            bpl.s   .p2
            neg.l   d2
.p2:        add.l   d1,d0
            add.l   d2,d0
            cmp.l   d3,d0
            bls.s   .nb
            move.l  d0,d3
            move.w  d6,d4
.nb:        addq.w  #1,d6
            cmp.w   F_N(a3),d6
            blo.s   .s
            lea     cbuf,a2
            adda.w  d4,a2
            lea     F_IDX(a3),a0
            move.w  d5,d6
.c3:        move.b  (a2)+,(a0)+
            dbra    d6,.c3
            ; the texture u,v (W) rotate with the vertices
            tst.w   d4
            beq.s   .nr
            move.l  a3,d0
            sub.l   #objf,d0
            lea     fuv,a0
            adda.l  d0,a0               ; u,v of the face (one word per vertex)
            lea     cuv,a1              ; doubled copy
            move.w  d5,d6
.u1:        move.w  (a0)+,(a1)+
            dbra    d6,.u1
            suba.w  d5,a0
            suba.w  d5,a0
            subq.l  #2,a0
            lea     cuv,a2
            move.w  d5,d6
.u2:        move.w  (a2)+,(a1)+
            dbra    d6,.u2
            lea     cuv,a2
            adda.w  d4,a2
            adda.w  d4,a2
            move.w  d5,d6
.u3:        move.w  (a2)+,(a0)+
            dbra    d6,.u3
.nr:        lea     FACESZ(a3),a3
            dbra    d7,.f
.out:       rts

;--------------------------------------------------------------
; buildadj : for each edge of each face, the neighbouring face
;   (same edge in the opposite direction) -> fadj (8 words per face) :
;   bits 0-14 = neighbour ($7fff = none), bit 15 = sharp edge
;   (angle between the faces > 55 degrees). Unit normals -> fnrm.
;--------------------------------------------------------------
CREASE      equ     9400                ; cos 55 degrees x 2^14

buildadj:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  nf,d7
            beq     .out
            ; unit normals of the faces
            subq.w  #1,d7
            lea     objf,a3
            lea     fnrm,a4
.n:         lea     F_IDX(a3),a2
            lea     objv,a1
            bsr     cross3
            move.w  F_LEN(a3),d3
            ext.l   d3
            asl.l   #8,d0
            asl.l   #6,d0
            divs.l  d3,d0
            move.w  d0,(a4)+
            asl.l   #8,d1
            asl.l   #6,d1
            divs.l  d3,d1
            move.w  d1,(a4)+
            asl.l   #8,d2
            asl.l   #6,d2
            divs.l  d3,d2
            move.w  d2,(a4)+
            lea     FACESZ(a3),a3
            dbra    d7,.n
            ; neighbours
            lea     objf,a3             ; face f
            lea     fadj,a4
            moveq   #0,d6               ; number of f
.f:         moveq   #0,d5               ; edge k
.k:         moveq   #0,d0               ; a = idx[k], b = idx[k+1]
            move.b  F_IDX(a3,d5.w),d0
            move.w  d5,d1
            addq.w  #1,d1
            cmp.w   F_N(a3),d1
            blo.s   .k1
            moveq   #0,d1
.k1:        moveq   #0,d2
            move.b  F_IDX(a3,d1.w),d2
            ; look for g != f containing the edge b -> a
            lea     objf,a5
            moveq   #0,d4               ; number of g
.g:         cmp.w   d6,d4
            beq.s   .gn
            move.w  F_N(a5),d3
            subq.w  #1,d3
            moveq   #0,d1
.m:         cmp.b   F_IDX(a5,d1.w),d2
            bne.s   .mn
            move.w  d1,d7               ; next of m
            addq.w  #1,d7
            cmp.w   F_N(a5),d7
            blo.s   .m1
            moveq   #0,d7
.m1:        cmp.b   F_IDX(a5,d7.w),d0
            beq.s   .found
.mn:        addq.w  #1,d1
            dbra    d3,.m
.gn:        lea     FACESZ(a5),a5
            addq.w  #1,d4
            cmp.w   nf,d4
            blo.s   .g
            move.w  #$7fff,d4           ; no neighbour
            bra.s   .put
.found:     ; sharp edge ?  nf . ng < cos(55)
            lea     fnrm,a0
            move.w  d6,d1
            mulu    #6,d1
            lea     (a0,d1.l),a1
            move.w  d4,d1
            mulu    #6,d1
            lea     (a0,d1.l),a0
            move.w  (a1)+,d1
            muls    (a0)+,d1
            move.w  (a1)+,d3
            muls    (a0)+,d3
            add.l   d3,d1
            move.w  (a1)+,d3
            muls    (a0)+,d3
            add.l   d3,d1
            asr.l   #8,d1
            asr.l   #6,d1
            cmp.l   #CREASE,d1
            bge.s   .put
            or.w    #$8000,d4
.put:       move.w  d4,(a4,d5.w*2)
            addq.w  #1,d5
            cmp.w   F_N(a3),d5
            blo     .k
            lea     16(a4),a4
            lea     FACESZ(a3),a3
            addq.w  #1,d6
            cmp.w   nf,d6
            blo     .f
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; celedges : black outlines of face a3 (cel shading), drawn
;   right after it is filled (the BSP order then hides what
;   must be hidden) : sharp edges, edges without a neighbour, and
;   silhouette (neighbour not visible in this frame).
;--------------------------------------------------------------
celedges:
            movem.l d0-d7/a0-a6,-(sp)
            clr.l   tclcol
            move.l  a3,d0
            sub.l   #objf,d0
            lea     fadj,a4
            adda.l  d0,a4               ; FACESZ = 16 = 8 words of fadj
            lea     F_IDX(a3),a5
            move.w  F_N(a3),d7
            subq.w  #1,d7
            moveq   #0,d5
.e:         move.w  (a4)+,d0
            move.w  d0,d1
            and.w   #$7fff,d1
            cmp.w   #$7fff,d1
            beq.s   .dr
            tst.w   d0
            bmi.s   .dr                 ; sharp edge
            move.w  d1,d2               ; neighbour of another material :
            lsl.w   #4,d2               ; outline
            lea     objf,a1
            move.w  F_COL(a1,d2.w),d2
            cmp.w   F_COL(a3),d2
            bne.s   .dr
            add.w   d1,d1
            lea     fseen,a1
            move.w  (a1,d1.w),d1
            cmp.w   tframe,d1
            beq.s   .sk                 ; visible neighbour : nothing
.dr:        moveq   #0,d0
            move.b  (a5,d5.w),d0
            move.w  d5,d1
            addq.w  #1,d1
            cmp.w   F_N(a3),d1
            blo.s   .w
            moveq   #0,d1
.w:         moveq   #0,d2
            move.b  (a5,d1.w),d2
            lsl.w   #2,d0
            lsl.w   #2,d2
            lea     proj,a1
            movem.l d5/d7/a3-a5,-(sp)
            move.w  2(a1,d2.w),d3
            move.w  (a1,d2.w),d2
            move.w  2(a1,d0.w),d1
            move.w  (a1,d0.w),d0
            bsr     dline
            movem.l (sp)+,d5/d7/a3-a5
.sk:        addq.w  #1,d5
            dbra    d7,.e
            move.l  #-1,tclcol
            movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; normmat : material of each face (F_COL), after parsing
;   mode T : plane 1..3 ; mode S + C lines : material 0..3 ;
;   mode S old format : F 3 -> material 1 = flat colour 1
;--------------------------------------------------------------
normmat:
            movem.l d0-d2/d7/a3,-(sp)
            move.w  #1,nmat
            move.w  nf,d7
            beq     .ns
            subq.w  #1,d7
            lea     objf,a3
            tst.w   objmode
            bne.s   .s
.t:         cmp.w   #3,F_COL(a3)        ; transparent : plane 1..3
            bls.s   .t1
            move.w  #3,F_COL(a3)
.t1:        lea     FACESZ(a3),a3
            dbra    d7,.t
            bra.s   .ns
.s:         tst.w   matmode
            beq.s   .l
            moveq   #1,d2               ; materials : F m -> m-1
.m:         move.w  F_COL(a3),d0
            subq.w  #1,d0
            move.w  d0,F_COL(a3)
            addq.w  #1,d0
            cmp.w   d2,d0
            bls.s   .m1
            move.w  d0,d2
.m1:        lea     FACESZ(a3),a3
            dbra    d7,.m
            lea     matdef+2*MAXMAT,a3  ; + materials defined by C
            moveq   #MAXMAT,d0
.m2:        tst.w   -(a3)
            bne.s   .m3
            subq.w  #1,d0
            bne.s   .m2
.m3:        cmp.w   d2,d0
            bls.s   .m4
            move.w  d0,d2
.m4:        move.w  d2,nmat
            bra.s   .ns
.l:         clr.w   d2                  ; old format
.lf:        cmp.w   #3,F_COL(a3)
            bne.s   .l0
            move.w  #1,F_COL(a3)
            moveq   #1,d2
            bra.s   .l1
.l0:        clr.w   F_COL(a3)
.l1:        lea     FACESZ(a3),a3
            dbra    d7,.lf
            move.w  d2,lflat
            beq.s   .ns
            move.w  #2,nmat
.ns:        moveq   #14,d0              ; shades per material (16 colours)
            divu    nmat,d0
            move.w  d0,nshade
            movem.l (sp)+,d0-d2/d7/a3
            rts

;--------------------------------------------------------------
; fantex : textured face a3 of 4..8 vertices -> drawn as triangles
;   (fan from vertex 0). Interpolating the texture along
;   the edges then the lines is only exact on a triangle :
;   on a polygon seen in perspective, the pattern twisted inside the
;   face and no longer matched its neighbours.
;   The triangle is a temporary face (objf + MAXF) with its u,v.
;--------------------------------------------------------------
fantex:
            movem.l d0-d7/a1-a6,-(sp)
            move.l  a3,a4               ; original face
            move.l  a3,d0
            sub.l   #objf,d0
            lea     fuv,a5
            adda.l  d0,a5               ; its u,v (16 bytes)
            lea     objf+MAXF*FACESZ,a3 ; temporary triangle
            lea     fuv+MAXF*16,a6
            move.w  F_COL(a4),F_COL(a3)
            move.w  #3,F_N(a3)
            move.b  F_IDX(a4),F_IDX(a3)
            move.w  (a5),(a6)
            moveq   #1,d7               ; k = 1 .. n-2
.t:         move.b  F_IDX(a4,d7.w),F_IDX+1(a3)
            move.b  F_IDX+1(a4,d7.w),F_IDX+2(a3)
            move.w  (a5,d7.w*2),2(a6)
            move.w  2(a5,d7.w*2),4(a6)
            movem.l d7/a4-a6,-(sp)
            cmp.w   #1,tcmode           ; True Color : by the DSP
            bne.s   .c
            bsr     dspfaceuv
            tst.w   d0
            beq.s   .d
.c:         bsr     tpoly
            bsr     fillS
.d:         movem.l (sp)+,d7/a4-a6
            addq.w  #1,d7
            move.w  F_N(a4),d0
            subq.w  #1,d0
            cmp.w   d0,d7
            blo.s   .t
            move.l  a4,a3
            movem.l (sp)+,d0-d7/a1-a6
            rts

;--------------------------------------------------------------
; setmat : ramps and Phong map of the material of face a3
;--------------------------------------------------------------
setmat:
            movem.l d0-d1/a0,-(sp)
            move.w  F_COL(a3),d0
            move.w  d0,d1
            mulu    #448,d1             ; ramp of words (224)
            tst.w   cel
            bne.s   .c
            add.l   #ramp,d1
            move.l  d1,curramp
            move.w  d0,d1
            mulu    #896,d1             ; ramp of longs
            add.l   #ramp2,d1
            move.l  d1,curramp2
            bra.s   .p
.c:         add.l   #rampc,d1
            move.l  d1,curramp
            move.w  d0,d1
            mulu    #896,d1
            add.l   #ramp2c,d1
            move.l  d1,curramp2
.p:         move.w  phong,uvmode        ; (u,v) of the vertices or intensity
            cmp.w   #4,shade            ; MAPPING : face with W coordinates
            bne.s   .p1                 ; (its colour does not matter)
            move.l  a3,d1
            sub.l   #objf,d1
            lsr.l   #4,d1
            lea     fhasw,a0
            tst.b   (a0,d1.w)
            beq.s   .x
            move.w  texmat,d0           ; the object's texture
            bmi.s   .x
            move.w  #2,uvmode           ; u,v of the face, map = texture
            moveq   #0,d1
            move.w  d0,d1
            swap    d1
            add.l   d1,d1               ; 128 KB per texture
            add.l   #textab,d1
            move.l  d1,curtex
            bra.s   .x
.p1:        tst.w   phong               ; fake Phong (not chrome)
            beq.s   .x
            cmp.w   #1,shade
            bne.s   .x
            moveq   #0,d1
            move.w  d0,d1
            swap    d1                  ; 64 KB per map
            add.l   #phtex,d1
            move.l  d1,curtex
.x:         movem.l (sp)+,d0-d1/a0
            rts

;--------------------------------------------------------------
; loadtex : loads OBJ\<name> of each material with an X line
;   128 lines of 128 RGB565 pixels, stored as 256x256 (copied to
;   the right and below : u and v repeat every 128 without a test)
;--------------------------------------------------------------
loadtex:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  #-1,texmat          ; no texture
            moveq   #0,d7               ; material
.m:         lea     mattex,a0
            clr.w   (a0,d7.w*2)
            move.w  d7,d0
            mulu    #14,d0
            lea     mattexn,a1
            adda.l  d0,a1
            tst.b   (a1)
            beq     .nx
            lea     texpath,a0          ; "OBJ\" + name
            lea     objmask,a2
            moveq   #3,d0
.p1:        move.b  (a2)+,(a0)+
            dbra    d0,.p1
.p2:        move.b  (a1)+,(a0)+
            bne.s   .p2
            clr.w   -(sp)               ; Fopen
            pea     texpath
            move.w  #$3d,-(sp)
            trap    #1
            addq.l  #8,sp
            tst.l   d0
            bmi.s   .nx
            move.w  d0,d6
            moveq   #0,d0               ; textab + m * 128 KB
            move.w  d7,d0
            swap    d0
            add.l   d0,d0
            add.l   #textab,d0
            move.l  d0,a4
            moveq   #127,d5
.r:         move.l  a4,-(sp)            ; Fread(h,256,line)
            move.l  #256,-(sp)
            move.w  d6,-(sp)
            move.w  #$3f,-(sp)
            trap    #1
            lea     12(sp),sp
            move.l  a4,a0               ; copy to the right (u + 128)
            lea     256(a4),a1
            moveq   #63,d0
.cp:        move.l  (a0)+,(a1)+
            dbra    d0,.cp
            lea     512(a4),a4
            dbra    d5,.r
            move.l  a4,a1               ; lines 0..127 -> 128..255 (v
            lea     -65536(a4),a0       ; also repeats every 128)
            move.w  #16384-1,d0
.cv:        move.l  (a0)+,(a1)+
            dbra    d0,.cv
            move.w  d6,-(sp)            ; Fclose
            move.w  #$3e,-(sp)
            trap    #1
            addq.l  #4,sp
            lea     mattex,a0
            move.w  #1,(a0,d7.w*2)
            tst.w   texmat              ; 1st texture loaded = the one of
            bpl.s   .nx                 ; the object
            move.w  d7,texmat
.nx:        addq.w  #1,d7
            cmp.w   #MAXMAT,d7
            blo     .m
            movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; matpal : 16-colour palette computed for the materials (C lines)
;   material m : colours 1+m*nshade .. (nshade shades, 32 % to 100 %)
;   material 1 without a C line : colour of shade 14 of the palette
;--------------------------------------------------------------
matpal:
            movem.l d0-d7/a0-a1,-(sp)
            tst.w   matmode
            beq     .out
            tst.w   matdef              ; material 1 by default
            bne.s   .d
            move.w  objpal+28,d6
            lea     matrgb,a1
            moveq   #8,d5
.dd:        move.w  d6,d0
            lsr.w   d5,d0
            bsr     stedec
            divu    #17,d0
            move.w  d0,(a1)+
            subq.w  #4,d5
            bpl.s   .dd
.d:         lea     objpal+2,a0         ; 1..14 : black by default
            moveq   #13,d0
.z:         clr.w   (a0)+
            dbra    d0,.z
            moveq   #0,d7               ; material
.m:         moveq   #0,d6               ; shade j
.j:         move.w  nshade,d0           ; level = j*13/(nshade-1)
            subq.w  #1,d0
            bne.s   .j1
            moveq   #13,d1
            bra.s   .j2
.j1:        move.w  d6,d1
            mulu    #13,d1
            divu    d0,d1
.j2:        mulu    #174,d1             ; factor 1066+174*level (/3328)
            add.w   #1066,d1
            move.w  d7,d0
            mulu    #6,d0
            lea     matrgb,a1
            adda.l  d0,a1
            moveq   #0,d4               ; STE word
            moveq   #2,d5
.c:         move.w  (a1)+,d0
            mulu    d1,d0
            add.l   #1664,d0
            divu    #3328,d0            ; 0..15
            lsr.w   #1,d0               ; STE : bit 0 in position 3
            bcc.s   .c1
            addq.w  #8,d0
.c1:        lsl.w   #4,d4
            or.w    d0,d4
            dbra    d5,.c
            move.w  d7,d0               ; index 1 + m*nshade + j
            mulu    nshade,d0
            add.w   d6,d0
            addq.w  #1,d0
            add.w   d0,d0
            lea     objpal,a0
            move.w  d4,(a0,d0.w)
            addq.w  #1,d6
            cmp.w   nshade,d6
            blo.s   .j
            addq.w  #1,d7
            cmp.w   nmat,d7
            blo.s   .m
.out:       movem.l (sp)+,d0-d7/a0-a1
            rts

;--------------------------------------------------------------
; vis3d : face a2 (indices) -> d0.l > 0 if visible, exact 3D test
;         (n . (eye - v0), eye = 0,0,-300) when the screen is doubtful
;--------------------------------------------------------------
vis3d:
            movem.l d1-d4/a1,-(sp)
            lea     rv,a1
            bsr     cross3
            moveq   #0,d3
            move.b  (a2),d3
            mulu    #6,d3
            move.w  (a1,d3.l),d4
            neg.w   d4
            ext.l   d4
            muls.l  d4,d0
            move.w  2(a1,d3.l),d4
            neg.w   d4
            ext.l   d4
            muls.l  d4,d1
            add.l   d1,d0
            move.w  4(a1,d3.l),d4
            neg.w   d4
            sub.w   #300,d4
            ext.l   d4
            muls.l  d4,d2
            add.l   d2,d0
            movem.l (sp)+,d1-d4/a1
            tst.l   d0
            rts

;--------------------------------------------------------------
; bspplanes : plane (n, d) of each BSP node, object frame
;             n = cross product of the 1st face, d = n . v0
;--------------------------------------------------------------
bspplanes:
            move.w  nt,d7
            beq.s   .out
            subq.w  #1,d7
            lea     objt,a3
.n:         move.w  (a3),d0
            mulu    #FACESZ,d0
            lea     objf,a2
            lea     F_IDX(a2,d0.l),a2
            lea     objv,a1
            bsr     cross3
            move.l  d0,8(a3)
            move.l  d1,12(a3)
            move.l  d2,16(a3)
            moveq   #0,d3
            move.b  (a2),d3
            mulu    #6,d3
            move.w  (a1,d3.l),d4
            ext.l   d4
            muls.l  d4,d0
            move.w  2(a1,d3.l),d4
            ext.l   d4
            muls.l  d4,d1
            add.l   d1,d0
            move.w  4(a1,d3.l),d4
            ext.l   d4
            muls.l  d4,d2
            add.l   d2,d0
            move.l  d0,20(a3)
            lea     TSZ(a3),a3
            dbra    d7,.n
.out:       rts

;--------------------------------------------------------------
; bsprank : walks the BSP tree from the eye -> frank[face] =
;           drawing rank (0 = the farthest, drawn first)
;--------------------------------------------------------------
bsprank:
            movem.l d0-d7/a0-a6,-(sp)
            ; eye (0,0,-300) brought into the object's frame :
            ; remove the bounce then inverse rotation (Z, X, Y)
            move.w  offx,d0
            neg.w   d0
            move.w  offy,d1
            neg.w   d1
            move.w  #-300,d2
            sub.w   offz,d2
            move.w  sinz,d6
            neg.w   d6
            move.w  d6,nsin
            rot     d0,d1,nsin,cosz
            move.w  sinx,d6
            neg.w   d6
            move.w  d6,nsin
            rot     d1,d2,nsin,cosx
            move.w  siny,d6
            neg.w   d6
            move.w  d6,nsin
            rot     d2,d0,nsin,cosy
            ext.l   d0
            ext.l   d1
            ext.l   d2
            movem.l d0-d2,bspeye
            clr.w   bspcnt
            moveq   #0,d0
            bsr.s   bspwalk
            movem.l (sp)+,d0-d7/a0-a6
            rts

bspwalk:    ; d0.w = node (-1 = none)
            tst.w   d0
            bmi.s   .out
            mulu    #TSZ,d0
            lea     objt,a0
            adda.l  d0,a0
            move.l  a0,-(sp)
            move.l  8(a0),d1            ; n . eye - d
            muls.l  bspeye,d1
            move.l  12(a0),d2
            muls.l  bspeye+4,d2
            add.l   d2,d1
            move.l  16(a0),d2
            muls.l  bspeye+8,d2
            add.l   d2,d1
            sub.l   20(a0),d1
            bgt.s   .dev
            move.w  4(a0),d0            ; eye behind the plane :
            bsr.s   bspwalk             ; front faces first
            move.l  (sp),a0
            bsr.s   .emit
            move.l  (sp),a0
            move.w  6(a0),d0
            bsr.s   bspwalk
            bra.s   .dn
.dev:       move.w  6(a0),d0            ; eye in front : back faces
            bsr.s   bspwalk             ; first
            move.l  (sp),a0
            bsr.s   .emit
            move.l  (sp),a0
            move.w  4(a0),d0
            bsr.s   bspwalk
.dn:        addq.l  #4,sp
.out:       rts
.emit:      move.w  (a0),d0             ; faces of the node : next ranks
            move.w  2(a0),d1
            subq.w  #1,d1
            lea     frank,a1
            add.w   d0,d0
            adda.w  d0,a1
            move.w  bspcnt,d2
.el:        move.w  d2,(a1)+
            addq.w  #1,d2
            dbra    d1,.el
            move.w  d2,bspcnt
            rts

;==============================================================
; MORPHING between two objects (change by O or automatic)
;   each object is sampled when loaded into MPTS points
;   spread over its faces (in proportion to their area), sorted by
;   height slice then by angle around the vertical axis :
;   point i of the old object slides to point i of the new one
;   (smooth curve + slight swelling half way), for MORPHN
;   frames, with the same rotation ; then the new object appears.
;==============================================================
MPTS        equ     256                 ; points of the cloud
MORPHN      equ     45                  ; transition frames

;--------------------------------------------------------------
; msample : point cloud of the object that has just been loaded
;--------------------------------------------------------------
msample:
            movem.l d0-d7/a0-a6,-(sp)
            move.l  #$2545f491,mseed    ; same random draw at each loading
            lea     mcloud,a4
            moveq   #0,d6               ; points emitted
            tst.w   nf
            beq     .verts
            clr.l   mtot
            moveq   #0,d5               ; pass 0 : total area, 1 : points
.pass:      clr.l   macc
            lea     objf,a3
            move.w  nf,d7
            subq.w  #1,d7
.f:         move.w  F_N(a3),d4
            subq.w  #3,d4               ; fan triangles - 1
            moveq   #1,d3
.t:         lea     mtri,a2
            move.b  F_IDX(a3),(a2)
            move.b  F_IDX(a3,d3.w),1(a2)
            move.b  F_IDX+1(a3,d3.w),2(a2)
            lea     objv,a1
            bsr     cross3
            asr.l   #2,d0               ; area ~ |normal|
            asr.l   #2,d1
            asr.l   #2,d2
            muls.l  d0,d0
            muls.l  d1,d1
            muls.l  d2,d2
            add.l   d1,d0
            add.l   d2,d0
            bsr     isqrt
            and.l   #$ffff,d0
            tst.w   d5
            bne.s   .em
            add.l   d0,mtot
            bra.s   .tn
.em:        lsl.l   #8,d0               ; x MPTS
            add.l   d0,macc
.e2:        move.l  macc,d1
            cmp.l   mtot,d1
            blo.s   .tn
            sub.l   mtot,d1
            move.l  d1,macc
            cmp.w   #MPTS,d6
            bhs.s   .tn
            bsr     mpoint
            bra.s   .e2
.tn:        addq.w  #1,d3
            dbra    d4,.t
            lea     FACESZ(a3),a3
            dbra    d7,.f
            tst.l   mtot
            beq.s   .verts
            addq.w  #1,d5
            cmp.w   #2,d5
            blo     .pass
            tst.w   d6
            bne.s   .pad
.verts:     lea     mcloud,a4           ; no faces : the vertices
            moveq   #0,d6
            move.w  nv,d5
            beq.s   .zero
            moveq   #0,d4
.vl:        move.w  d4,d0
            mulu    #6,d0
            lea     objv,a1
            move.w  (a1,d0.l),(a4)+
            move.w  2(a1,d0.l),(a4)+
            move.w  4(a1,d0.l),(a4)+
            addq.w  #1,d4
            cmp.w   d5,d4
            blo.s   .vn
            moveq   #0,d4
.vn:        addq.w  #1,d6
            cmp.w   #MPTS,d6
            blo.s   .vl
            bra.s   .sort
.zero:      clr.w   (a4)+
            clr.l   (a4)+
            addq.w  #1,d6
            cmp.w   #MPTS,d6
            blo.s   .zero
            bra.s   .sort
.pad:       lea     mcloud,a5           ; completed by copying
.pl:        cmp.w   #MPTS,d6
            bhs.s   .sort
            move.w  (a5)+,(a4)+
            move.w  (a5)+,(a4)+
            move.w  (a5)+,(a4)+
            addq.w  #1,d6
            bra.s   .pl
            ; --- keys : height slice * 1024 + angle around Y ---
.sort:      lea     mcloud,a0
            lea     mkey,a1
            move.w  #MPTS-1,d7
.k:         movem.w (a0)+,d0-d2         ; x y z
            add.w   #128,d1
            bpl.s   .k1
            moveq   #0,d1
.k1:        lsr.w   #4,d1
            cmp.w   #15,d1
            bls.s   .k2
            moveq   #15,d1
.k2:        lsl.w   #8,d1
            lsl.w   #2,d1               ; slice * 1024
            move.w  d0,d3               ; |x| + |z|
            bpl.s   .k3
            neg.w   d3
.k3:        move.w  d2,d4
            bpl.s   .k4
            neg.w   d4
.k4:        add.w   d4,d3
            beq.s   .k6
            ext.l   d0
            asl.l   #8,d0
            divs    d3,d0               ; x / (|x|+|z|) * 256
            tst.w   d2
            bmi.s   .k5
            add.w   #768,d0             ; z >= 0 : 512..1024
            bra.s   .k7
.k5:        neg.w   d0                  ; z < 0 : 0..512
            add.w   #256,d0
            bra.s   .k7
.k6:        moveq   #0,d0
.k7:        add.w   d1,d0
            move.w  d0,(a1)+
            dbra    d7,.k
            ; insertion sort (key + point)
            moveq   #1,d7
.is:        lea     mkey,a1
            move.w  d7,d0
            add.w   d0,d0
            move.w  (a1,d0.w),d1        ; key to insert
            move.w  d7,d0
            mulu    #6,d0
            lea     mcloud,a0
            movem.w (a0,d0.l),d2-d4     ; point to insert
            move.w  d7,d6               ; position
.ib:        tst.w   d6
            beq.s   .ip
            move.w  d6,d0
            add.w   d0,d0
            cmp.w   -2(a1,d0.w),d1
            bge.s   .ip
            move.w  -2(a1,d0.w),(a1,d0.w)
            move.w  d6,d0
            mulu    #6,d0
            move.w  -6(a0,d0.l),(a0,d0.l)
            move.w  -4(a0,d0.l),2(a0,d0.l)
            move.w  -2(a0,d0.l),4(a0,d0.l)
            subq.w  #1,d6
            bra.s   .ib
.ip:        move.w  d6,d0
            add.w   d0,d0
            move.w  d1,(a1,d0.w)
            move.w  d6,d0
            mulu    #6,d0
            move.w  d2,(a0,d0.l)
            move.w  d3,2(a0,d0.l)
            move.w  d4,4(a0,d0.l)
            addq.w  #1,d7
            cmp.w   #MPTS,d7
            blo.s   .is
            move.w  #1,mvalid
            movem.l (sp)+,d0-d7/a0-a6
            rts

; mpoint : random point in triangle mtri -> (a4)+, d6 + 1
mpoint:
            movem.l d0-d5/a0-a2,-(sp)
            move.l  mseed,d0
            mulu.l  #69069,d0
            addq.l  #1,d0
            move.l  d0,d1
            rol.l   #8,d1
            and.w   #255,d1             ; r1
            mulu.l  #69069,d0
            addq.l  #1,d0
            move.l  d0,mseed
            move.l  d0,d2
            rol.l   #8,d2
            and.w   #255,d2             ; r2
            move.w  d1,d3
            add.w   d2,d3
            cmp.w   #255,d3
            bls.s   .in
            neg.w   d1                  ; folded back into the triangle
            add.w   #255,d1
            neg.w   d2
            add.w   #255,d2
.in:        lea     mtri,a2
            lea     objv,a1
            moveq   #0,d0
            move.b  (a2),d0
            mulu    #6,d0
            lea     (a1,d0.l),a0        ; v0
            moveq   #0,d0
            move.b  1(a2),d0
            mulu    #6,d0
            lea     (a1,d0.l),a2        ; v1
            moveq   #0,d0
            move.b  mtri+2,d0
            mulu    #6,d0
            lea     (a1,d0.l),a1        ; v2
            moveq   #2,d5
.c:         move.w  (a2)+,d3            ; (v1-v0)*r1 + (v2-v0)*r2
            sub.w   (a0),d3
            muls    d1,d3
            move.w  (a1)+,d4
            sub.w   (a0),d4
            muls    d2,d4
            add.l   d4,d3
            asr.l   #8,d3
            add.w   (a0)+,d3
            move.w  d3,(a4)+
            dbra    d5,.c
            addq.w  #1,d6
            movem.l (sp)+,d0-d5/a0-a2
            rts

;--------------------------------------------------------------
; mstart : before loading the next object -> morphing source
;          (the cloud of the displayed object, or the current position
;          if a morphing is already running)
;--------------------------------------------------------------
mstart:
            movem.l d0/a0-a1,-(sp)
            move.w  objrad,mrad0        ; radius of the old object
            lea     mcloud,a0
            tst.w   mdraw
            beq.s   .s
            bsr     mcurcalc            ; (the DSP does not give it)
            lea     mcur,a0
.s:         lea     mfrom,a1
            move.w  #3*MPTS/2-1,d0
.c:         move.l  (a0)+,(a1)+
            dbra    d0,.c
            movem.l (sp)+,d0/a0-a1
            rts

;--------------------------------------------------------------
; mtransform : (instead of transform during the morphing)
;   interpolated points -> rv (rotated) and proj (screen)
;--------------------------------------------------------------
mtransform:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  #1,mdraw
            lea     sintab,a6
            move.w  tframe,d0           ; same rotation as the object
            bsr     getsc
            move.w  d1,sinx
            move.w  d2,cosx
            move.w  d1,sinz
            move.w  d2,cosz
            move.w  tframe,d0
            add.w   d0,d0
            bsr     getsc
            move.w  d1,siny
            move.w  d2,cosy
            move.w  #MORPHN+1,d0        ; progress x = 0..256
            sub.w   morph,d0
            mulu    #256,d0
            divu    #MORPHN,d0
            cmp.w   #256,d0
            bls.s   .x
            move.w  #256,d0
.x:         move.w  d0,d1               ; s = x2 (768 - 2x) / 65536
            mulu    d0,d1
            move.l  #768,d2             ; (32 bits : mulu.l)
            sub.w   d0,d2
            sub.w   d0,d2
            mulu.l  d2,d1
            clr.w   d1
            swap    d1
            move.w  d1,ms
            move.w  #256,d2             ; swelling 1 + x(1-x) in the middle
            sub.w   d0,d2
            mulu    d0,d2
            lsr.l   #8,d2
            add.w   #256,d2
            move.w  d2,mf
            subq.w  #1,morph
            tst.w   d3don               ; DSP : the whole cloud there
            beq.s   .cpu
            bsr     mkmat               ; (same rotation as below)
            bsr     d3dmorph
            tst.w   d0
            beq     .out
.cpu:       lea     mfrom,a1
            lea     mcloud,a2
            lea     mcur,a4
            lea     rv,a3
            lea     proj,a5
            move.w  #MPTS-1,d7
.p:         moveq   #2,d6               ; 3 coordinates -> mcur
.c:         move.w  (a1)+,d0
            move.w  (a2)+,d3
            sub.w   d0,d3
            muls    ms,d3
            asr.l   #8,d3
            add.w   d3,d0
            muls    mf,d0
            asr.l   #8,d0
            move.w  d0,(a4)+
            dbra    d6,.c
            movem.w -6(a4),d0-d2
            rot     d2,d0,siny,cosy
            rot     d1,d2,sinx,cosx
            rot     d0,d1,sinz,cosz
            move.w  d0,(a3)+
            move.w  d1,(a3)+
            move.w  d2,(a3)+
            add.w   #300,d2
            move.w  d0,d3               ; X = 160 + x*256/z
            ext.l   d3
            asl.l   #8,d3
            divs    d2,d3
            add.w   pathx,d3            ; + path
            bpl.s   .x0
            moveq   #0,d3
.x0:        cmp.w   #318,d3             ; 2x2 points
            ble.s   .x1
            move.w  #318,d3
.x1:        and.w   #$fffe,d3
            move.w  d3,(a5)+
            move.w  d1,d3
            ext.l   d3
            asl.l   #8,d3
            divs    d2,d3
            add.w   pathy,d3
            bpl.s   .y0
            moveq   #0,d3
.y0:        move.w  scrhm1,d4
            subq.w  #1,d4
            cmp.w   d4,d3
            ble.s   .y1
            move.w  d4,d3
.y1:        move.w  d3,(a5)+
            dbra    d7,.p
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

; mcurcalc : current position of the cloud -> mcur (as mtransform)
mcurcalc:
            movem.l d0/d3/d6-d7/a1-a2/a4,-(sp)
            lea     mfrom,a1
            lea     mcloud,a2
            lea     mcur,a4
            move.w  #3*MPTS-1,d7
.c:         move.w  (a1)+,d0
            move.w  (a2)+,d3
            sub.w   d0,d3
            muls    ms,d3
            asr.l   #8,d3
            add.w   d3,d0
            muls    mf,d0
            asr.l   #8,d0
            move.w  d0,(a4)+
            dbra    d7,.c
            movem.l (sp)+,d0/d3/d6-d7/a1-a2/a4
            rts

;--------------------------------------------------------------
; mdots : draws the cloud (2x2 points) into screen a0
;   shade from the depth (solid object) or white (transparent)
;--------------------------------------------------------------
mdots:
            movem.l d0-d7/a0-a6,-(sp)
            lea     proj,a1
            lea     rv,a2
            move.w  #MPTS-1,d7
            tst.w   tcmode
            bne     .tc
            lea     ytab,a5
.p16:       move.w  (a1)+,d0
            move.w  (a1)+,d1
            move.w  4(a2),d2
            addq.l  #6,a2
            moveq   #15,d3              ; colour
            tst.w   objmode
            beq.s   .c16
            ext.l   d2
            divs    #14,d2
            moveq   #8,d3
            sub.w   d2,d3
            cmp.w   #2,d3
            bge.s   .c1
            moveq   #2,d3
.c1:        cmp.w   #14,d3
            ble.s   .c16
            moveq   #14,d3
.c16:       move.w  d1,d4
            add.w   d4,d4
            move.w  (a5,d4.w),d4
            lea     (a0,d4.w),a4
            move.w  d0,d4
            lsr.w   #4,d4
            lsl.w   #3,d4
            adda.w  d4,a4
            move.w  d0,d4
            and.w   #14,d4
            move.w  #$c000,d5
            lsr.w   d4,d5               ; 2 pixels
            move.w  d5,d6
            not.w   d6
            moveq   #3,d4               ; 4 planes
.pl:        lsr.w   #1,d3
            bcc.s   .pc
            or.w    d5,(a4)
            or.w    d5,160(a4)
            bra.s   .pn
.pc:        and.w   d6,(a4)
            and.w   d6,160(a4)
.pn:        addq.l  #2,a4
            dbra    d4,.pl
            dbra    d7,.p16
            bra.s   .out
.tc:        lea     ytc,a5
            lea     ramp,a6
.ptc:       move.w  (a1)+,d0
            move.w  (a1)+,d1
            move.w  4(a2),d2
            addq.l  #6,a2
            moveq   #-1,d3
            tst.w   objmode
            beq.s   .ctc
            asr.w   #1,d2               ; shade 66 - z/2
            moveq   #66,d4
            sub.w   d2,d4
            cmp.w   #20,d4
            bge.s   .t1
            moveq   #20,d4
.t1:        cmp.w   #124,d4
            ble.s   .t2
            moveq   #124,d4
.t2:        add.w   d4,d4
            move.w  (a6,d4.w),d3
            move.w  d3,d4
            swap    d3
            move.w  d4,d3
.ctc:       move.w  d1,d4
            lsl.w   #2,d4
            move.l  (a5,d4.w),d4
            lea     (a0,d4.l),a4
            adda.w  d0,a4
            adda.w  d0,a4
            move.l  d3,(a4)
            move.l  d3,TCLINE(a4)
            dbra    d7,.ptc
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; PATH : on top of its rotation, the object moves along a
;   Lissajous curve (x : 3 / y : 5) in the free area between the
;   texts at the top and bottom. Amplitudes = free room - radius of
;   the object on screen ; they follow the object smoothly (2 pixels
;   per frame) when it changes, during the morphing.
;--------------------------------------------------------------
; objradius : objrad = max radius of the projected object (pixels)
;   vertex at r from the centre : at most 256 r / sqrt(300^2 - r^2)
objradius:
            movem.l d0-d3/a0,-(sp)
            lea     objv,a0
            moveq   #0,d2               ; max r^2
            move.w  nv,d3
            subq.w  #1,d3
            bmi.s   .z
.v:         move.w  (a0)+,d0
            muls    d0,d0
            move.w  (a0)+,d1
            muls    d1,d1
            add.l   d1,d0
            move.w  (a0)+,d1
            muls    d1,d1
            add.l   d1,d0
            cmp.l   d2,d0
            bls.s   .n
            move.l  d0,d2
.n:         dbra    d3,.v
.z:         cmp.l   #200*200,d2         ; (objects of -70..70 : margin)
            bls.s   .k
            move.l  #200*200,d2
.k:         move.l  d2,d0
            bsr     isqrt               ; r
            move.w  d0,d3
            move.l  #90000,d0
            sub.l   d2,d0
            bsr     isqrt               ; sqrt(300^2 - r^2)
            move.w  d3,d1
            mulu    #256,d1
            divu    d0,d1
            addq.w  #2,d1               ; 2x2 points, rounded
            move.w  d1,objrad
            movem.l (sp)+,d0-d3/a0
            rts

; mpath : pathx, pathy = centre of the object on screen for this frame
mpath:
            movem.l d0-d3,-(sp)
            move.w  objrad,d0           ; radius (morphing : the larger
            tst.w   morph               ; of the two, + swelling 1/4)
            beq.s   .r
            cmp.w   mrad0,d0
            bge.s   .r1
            move.w  mrad0,d0
.r1:        move.w  d0,d1
            lsr.w   #2,d1
            add.w   d1,d0
.r:         move.w  bandy+6,d1          ; free area : below the 2nd line at
            sub.w   bandy+2,d1          ; the top, above the 1st at the bottom
            sub.w   #11,d1
            lsr.w   #1,d1               ; half free height
            sub.w   d0,d1
            bpl.s   .y
            moveq   #0,d1
.y:         move.w  #156,d2             ; half free width
            sub.w   d0,d2
            bpl.s   .x
            moveq   #0,d2
.x:         move.w  curax,d0            ; amplitudes : 2 pixels per frame
            sub.w   d2,d0
            beq.s   .ax
            bmi.s   .ax1
            subq.w  #2,curax
            cmp.w   #1,d0
            bne.s   .ax
            addq.w  #1,curax
            bra.s   .ax
.ax1:       addq.w  #2,curax
            cmp.w   #-1,d0
            bne.s   .ax
            subq.w  #1,curax
.ax:        move.w  curay,d0
            sub.w   d1,d0
            beq.s   .ay
            bmi.s   .ay1
            subq.w  #2,curay
            cmp.w   #1,d0
            bne.s   .ay
            addq.w  #1,curay
            bra.s   .ay
.ay1:       addq.w  #2,curay
            cmp.w   #-1,d0
            bne.s   .ay
            subq.w  #1,curay
.ay:        move.w  tframe,d0           ; x = ax sin(3t/4)
            mulu    #3,d0
            lsr.l   #2,d0
            bsr     getsc
            muls    curax,d1
            asr.l   #8,d1
            asr.l   #6,d1
            add.w   #160,d1
            move.w  d1,pathx
            move.w  tframe,d0           ; y = ay cos(5t/4)
            mulu    #5,d0
            lsr.l   #2,d0
            add.w   #64,d0
            bsr     getsc
            muls    curay,d1
            asr.l   #8,d1
            asr.l   #6,d1
            move.w  bandy+6,d0          ; centre of the free area
            add.w   bandy+2,d0
            addq.w  #5,d0
            lsr.w   #1,d0
            add.w   d0,d1
            move.w  d1,pathy
            movem.l (sp)+,d0-d3
            rts

;--------------------------------------------------------------
; drawobj : draws the object into screen a0 according to its mode
;--------------------------------------------------------------
drawobj:
            tst.w   mdraw               ; morphing : point cloud
            bne     mdots
            tst.w   tcmode              ; True Color : optimised black background
            bne     tcdrawobj
            tst.w   objmode
            bne     drawsolid

            ; --- mode T : faces ORed then white edges ---
            move.w  nf,d7
            beq.s   .edges
            subq.w  #1,d7
            lea     objf,a3
.f:         move.w  d7,-(sp)
            move.w  F_COL(a3),d0
            add.w   d0,d0
            move.w  d0,pofs             ; plane 1..3 -> offset 2,4,6
            bsr     tpoly
            bsr     fillT
            move.w  (sp)+,d7
            lea     FACESZ(a3),a3
            dbra    d7,.f
.edges:     move.w  ne,d7
            beq.s   .out
            subq.w  #1,d7
            lea     obje,a3
.e:         moveq   #0,d4
            move.b  (a3)+,d4
            lsl.w   #2,d4
            moveq   #0,d5
            move.b  (a3)+,d5
            lsl.w   #2,d5
            lea     proj,a2
            move.w  (a2,d4.w),d0
            move.w  2(a2,d4.w),d1
            move.w  (a2,d5.w),d2
            move.w  2(a2,d5.w),d3
            move.w  d7,-(sp)
            bsr     dline
            move.w  (sp)+,d7
            dbra    d7,.e
.out:       rts

;--------------------------------------------------------------
; drawsolid : mode S - visible faces, sorted from back to
;             front, colour 1..15 according to the orientation
;--------------------------------------------------------------
drawsolid:
            move.l  a0,-(sp)
            clr.w   nvis
            tst.w   nt                  ; BSP tree : exact order
            beq.s   .nob
            bsr     bsprank
            lea     rkbuf,a1            ; slots per rank : empty
            move.w  nf,d0
            subq.w  #1,d0
.rk:        clr.l   4(a1)
            addq.l  #8,a1
            dbra    d0,.rk
.nob:       move.w  nf,d7
            beq     .draw
            subq.w  #1,d7
            lea     objf,a3
            moveq   #0,d6               ; face number
.f:         lea     F_IDX(a3),a2
            ; 2D screen cross product : visible if < 0
            lea     proj,a1
            moveq   #0,d0
            move.b  (a2),d0
            lsl.w   #2,d0
            move.w  (a1,d0.w),d1        ; x0
            move.w  2(a1,d0.w),d2       ; y0
            moveq   #0,d0
            move.b  1(a2),d0
            lsl.w   #2,d0
            move.w  (a1,d0.w),d3
            sub.w   d1,d3               ; x1-x0
            move.w  2(a1,d0.w),d4
            sub.w   d2,d4               ; y1-y0
            moveq   #0,d0
            move.b  2(a2),d0
            lsl.w   #2,d0
            move.w  (a1,d0.w),d5
            sub.w   d1,d5               ; x2-x0
            move.w  2(a1,d0.w),d1
            sub.w   d2,d1               ; y2-y0
            ; error margin of the screen rounding : |dx1|+|dy1|+|dx2|+|dy2|+1
            move.w  d3,d0
            bpl.s   .a1
            neg.w   d0
.a1:        move.w  d4,d2
            bpl.s   .a2
            neg.w   d2
.a2:        add.w   d2,d0
            move.w  d5,d2
            bpl.s   .a3
            neg.w   d2
.a3:        add.w   d2,d0
            move.w  d1,d2
            bpl.s   .a4
            neg.w   d2
.a4:        add.w   d2,d0
            addq.w  #1,d0
            ext.l   d0
            muls    d1,d3               ; (x1-x0)(y2-y0)
            muls    d5,d4               ; (y1-y0)(x2-x0)
            sub.l   d4,d3
            bpl.s   .cp
            neg.l   d3                  ; < 0 : visible if clear-cut
            cmp.l   d0,d3
            bgt.s   .vis
            bra.s   .amb
.cp:        cmp.l   d0,d3               ; > 0 : back facing if clear-cut
            bgt     .nx
.amb:       bsr     vis3d               ; doubtful : exact 3D test
            ble     .nx
.vis:

            ; --- visible in this frame (fseen : smoothing, cel outlines) ---
            lea     fseen,a1
            move.w  d6,d1
            add.w   d1,d1
            move.w  tframe,d2
            move.w  (a1,d1.w),d4        ; last frame in which it was visible
            move.w  d2,(a1,d1.w)
            tst.w   tcmode              ; True Color : no shade per face
            bne     .tcx                ; (lighting at the vertices)
            subq.w  #1,d2
            sub.w   d4,d2               ; 0 = visible in the previous frame
            move.w  d2,-(sp)
            ; lighting : v = |nz| / length, in levels x16 (0..208)
            lea     rv,a1
            bsr     cross3              ; d2 = nz
            tst.l   d2
            bpl.s   .ab
            neg.l   d2
.ab:        move.l  d2,d0
            mulu.l  #208,d0
            divu.w  F_LEN(a3),d0
            bvc.s   .sh
            move.w  #208,d0
.sh:        cmp.w   #208,d0
            bls.s   .sh1
            move.w  #208,d0
.sh1:       lea     fshade,a1
            move.w  (sp)+,d2
            bne.s   .new
            ; hysteresis : the level only changes if the light clearly
            ; crosses the boundary (otherwise faces on the edge between two
            ; shades changed every frame : flickering)
            moveq   #0,d1
            move.b  (a1,d6.w),d1        ; displayed level 0..13
            move.w  d1,d3
            lsl.w   #4,d3
            add.w   #12,d3              ; level + 3/4
            cmp.w   d3,d0
            bls.s   .nup
            addq.w  #1,d1               ; one step lighter
            bra.s   .lv
.nup:       sub.w   #24,d3              ; level - 3/4
            cmp.w   d3,d0
            bge.s   .lv
            subq.w  #1,d1               ; one step darker
            bra.s   .lv
.new:       move.w  d0,d1               ; new face : rounded level
            addq.w  #8,d1
            lsr.w   #4,d1
.lv:        cmp.w   #13,d1
            bls.s   .lv2
            moveq   #13,d1
.lv2:       move.b  d1,(a1,d6.w)
            move.w  d1,d0               ; level 0..13 -> colour
            tst.w   matmode             ; materials : shades of the material
            beq.s   .leg                ; 1 + m*nshade + s*nshade/14
            mulu    nshade,d0
            divu    #14,d0
            move.w  F_COL(a3),d1
            mulu    nshade,d1
            add.w   d1,d0
            addq.w  #1,d0
            bra.s   .shd
.leg:       addq.w  #1,d0               ; target colour 1..14 (15 = text)
            cmp.w   #1,F_COL(a3)        ; old F 3 : flat colour 1
            bne.s   .lit
            moveq   #1,d0
            bra.s   .shd
.lit:       cmp.w   #2,d0               ; the others : 2..14 (1 reserved)
            bhs.s   .shd
            moveq   #2,d0
.shd:       move.w  d0,d5
.tcx:

            tst.w   nt                  ; BSP tree : the face goes directly
            beq.s   .zavg               ; into the slot of its rank (no sorting)
            lea     frank,a1
            move.w  d6,d3
            add.w   d3,d3
            move.w  (a1,d3.w),d0
            lsl.w   #3,d0
            lea     rkbuf,a1
            move.w  d5,2(a1,d0.w)
            move.l  a3,4(a1,d0.w)
            bra     .nx
.zavg:
            ; depth = AVERAGE z of the vertices (not the sum : with
            ; faces of 3 to 8 vertices, the sum spoilt the painter's sort
            ; and made objects with mixed face sizes flicker)
            lea     rv,a1
            move.w  F_N(a3),d4
            subq.w  #1,d4
            moveq   #0,d3
.z:         moveq   #0,d0
            move.b  (a2)+,d0
            mulu    #6,d0
            add.w   4(a1,d0.l),d3
            dbra    d4,.z
            move.w  F_N(a3),d4          ; average without division :
            add.w   d4,d4               ; sum * (840/n) / 64
            lea     avgmul,a1           ; (840 divisible by 3..8)
            muls    (a1,d4.w),d3
            asr.l   #6,d3

            ; sorted insertion (decreasing z) into vislist
.zins:      move.w  nvis,d4
            lea     vislist,a1
            lsl.w   #3,d4
            adda.w  d4,a1               ; end of list
.ins:       cmpa.l  #vislist,a1
            beq.s   .put
            cmp.w   -8(a1),d3           ; previous one closer ?
            ble.s   .put
            move.l  -8(a1),(a1)         ; shift towards the end
            move.l  -4(a1),4(a1)
            subq.l  #8,a1
            bra.s   .ins
.put:       move.w  d3,(a1)             ; z, colour, face address
            move.w  d5,2(a1)
            move.l  a3,4(a1)
            addq.w  #1,nvis
.nx:        addq.w  #1,d6
            lea     FACESZ(a3),a3
            dbra    d7,.f
            tst.w   nt                  ; BSP : filled slots -> vislist,
            beq.s   .draw               ; from rank 0 (the farthest) to the last
            lea     rkbuf,a1
            lea     vislist,a2
            moveq   #0,d1
            move.w  nf,d0
            subq.w  #1,d0
.cpk:       tst.l   4(a1)
            beq.s   .cpn
            move.l  (a1),(a2)+
            move.l  4(a1),(a2)+
            addq.w  #1,d1
.cpn:       addq.l  #8,a1
            dbra    d0,.cpk
            move.w  d1,nvis

.draw:      move.l  (sp),a0
            move.w  nvis,d7
            beq     .out
            subq.w  #1,d7
            lea     vislist,a2
.d:         move.w  d7,-(sp)
            move.l  a2,-(sp)
            move.w  2(a2),d0            ; colour -> 4 planes
            bsr     setcol
            move.l  4(a2),a3
            move.l  6(sp),a0
            tst.w   tcmode
            beq.s   .nmt
            bsr     setmat              ; ramp / map of the material
            cmp.w   #2,uvmode           ; texture on a face of 4 vertices
            bne.s   .nmt                ; or more : as triangles
            cmp.w   #3,F_N(a3)
            beq.s   .nmt
            move.l  a3,d0               ; planar u,v (uvaffine) : in one piece
            sub.l   #objf,d0
            lsr.l   #4,d0
            lea     fhasw,a1
            cmp.b   #1,(a1,d0.w)
            beq.s   .nmt
            bsr     fantex
            bra.s   .ncel
.nmt:       cmp.w   #1,tcmode           ; True Color Gouraud / cel :
            bne.s   .cpu                ; faces filled by the DSP
            tst.w   uvmode
            beq.s   .dgo
            bsr     dspfaceuv           ; Phong / chrome / mapping : DSP too
            bra.s   .dtt
.dgo:       bsr     dspface
.dtt:       tst.w   d0
            beq.s   .dsp
.cpu:       bsr     tpoly
            bsr     fillS
.dsp:       tst.w   cel
            beq.s   .ncel
            bsr     celedges            ; cel : black outlines
.ncel:      move.l  (sp)+,a2
            move.w  (sp)+,d7
            addq.l  #8,a2
            dbra    d7,.d
.out:       move.l  (sp)+,a0
            rts

;--------------------------------------------------------------
; setcol : d0 = colour 0..15 -> cw0..cw3 (planes) and cl1/cl2
;--------------------------------------------------------------
setcol:
            move.w  d0,curcol
            rts

;--------------------------------------------------------------
; tracepoly : convex polygon of face a3 -> two chains
;             xa[y] (descending edges) and xb[y] (ascending
;             edges), in 16.16 fixed point ; fymin/fymax
;             (a0, a3 preserved)
;--------------------------------------------------------------
tracepoly:
            lea     F_IDX(a3),a5
            lea     proj,a2
            lea     fv,a4
            move.w  F_N(a3),d7
            subq.w  #1,d7
            move.w  #32767,d5           ; ymin
            move.w  #-32768,d6          ; ymax
.cp:        moveq   #0,d4
            move.b  (a5)+,d4
            lsl.w   #2,d4
            move.l  (a2,d4.w),d0        ; x:y of the vertex
            move.l  d0,(a4)+
            cmp.w   d5,d0
            bge.s   .c1
            move.w  d0,d5
.c1:        cmp.w   d6,d0
            ble.s   .c2
            move.w  d0,d6
.c2:        dbra    d7,.cp
            move.l  fv,(a4)             ; wrap around
            move.w  d5,fymin
            cmp.w   d5,d6               ; face reduced to a line :
            bne.s   .h                  ; nothing to fill
            subq.w  #1,d6
.h:         move.w  d6,fymax

            lea     fv,a4
            move.w  F_N(a3),d7
            subq.w  #1,d7
.ed:        movem.w (a4),d0-d3          ; x0,y0,x1,y1
            addq.l  #4,a4
            lea     xa,a1
            cmp.w   d1,d3
            bgt.s   .go                 ; going down : chain A
            beq.s   .nx                 ; horizontal : ignored
            exg     d0,d2               ; going up : chain B, from top to bottom
            exg     d1,d3
            lea     xb,a1
.go:        add.w   d1,a1
            add.w   d1,a1               ; a1 = table[y0]
            sub.w   d1,d3               ; dy > 0
            sub.w   d0,d2               ; dx
            swap    d2
            clr.w   d2                  ; dx << 16
            ext.l   d3
            divs.l  d3,d2               ; step = dx/dy (16.16)
            swap    d0
            move.w  #$8000,d0           ; x0 + 0.5
.lp:        move.l  d0,d1
            swap    d1
            move.w  d1,(a1)+
            add.l   d2,d0
            dbra    d3,.lp              ; dy+1 lines
.nx:        dbra    d7,.ed
            rts

;--------------------------------------------------------------
; fillor : fills xl/xr ORed into plane pofs (mode T)
;--------------------------------------------------------------
fillor:
            move.l  a3,-(sp)
            move.l  a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4               ; number of lines - 1
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4        ; start of line
            adda.w  pofs,a4             ; + plane offset
            lea     ltab,a5
            lea     rtab,a6
            moveq   #-1,d5
.fy:        move.w  (a1)+,d0            ; the two chains
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1               ; d0 = left, d1 = right
.o:
            add.w   d0,d0
            add.w   d0,d0
            move.l  (a5,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3        ; 1st word
            move.w  d3,d6
            sub.w   d2,d6               ; distance in bytes
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            or.w    d2,(a3)
            bra     .nx
.mul:       or.w    d2,(a3)
            or.w    d3,(a3,d6.w)
            subq.w  #8,d6
            beq     .nx
            lsr.w   #1,d6               ; 4 bytes of code per full word
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.w  d5,152(a3)
            move.w  d5,144(a3)
            move.w  d5,136(a3)
            move.w  d5,128(a3)
            move.w  d5,120(a3)
            move.w  d5,112(a3)
            move.w  d5,104(a3)
            move.w  d5,96(a3)
            move.w  d5,88(a3)
            move.w  d5,80(a3)
            move.w  d5,72(a3)
            move.w  d5,64(a3)
            move.w  d5,56(a3)
            move.w  d5,48(a3)
            move.w  d5,40(a3)
            move.w  d5,32(a3)
            move.w  d5,24(a3)
            move.w  d5,16(a3)
            move.w  d5,8(a3)
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       move.l  (sp)+,a6
            move.l  (sp)+,a3
            rts

;--------------------------------------------------------------
; fillcol : fills xa/xb with the current colour (mode S)
;           one loop per colour (fillc0..fillc15) : the edge
;           words do OR (plane bit set) or AND (bit cleared) on
;           each plane, the full words 2 move.l
;--------------------------------------------------------------
fillcol:
            move.w  curcol,d0
            lsl.w   #2,d0
            lea     filltab,a1
            move.l  (a1,d0.w),a1
            jmp     (a1)

filltab:    dc.l    fillc0,fillc1,fillc2,fillc3,fillc4,fillc5,fillc6,fillc7
            dc.l    fillc8,fillc9,fillc10,fillc11,fillc12,fillc13,fillc14,fillc15

fillc0:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$00000000,d5
            move.l  #$00000000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc1:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffff0000,d5
            move.l  #$00000000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc2:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$0000ffff,d5
            move.l  #$00000000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc3:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffffffff,d5
            move.l  #$00000000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc4:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$00000000,d5
            move.l  #$ffff0000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc5:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffff0000,d5
            move.l  #$ffff0000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc6:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$0000ffff,d5
            move.l  #$ffff0000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc7:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffffffff,d5
            move.l  #$ffff0000,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            and.w   d0,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc8:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$00000000,d5
            move.l  #$0000ffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc9:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffff0000,d5
            move.l  #$0000ffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            and.w   d0,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc10:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$0000ffff,d5
            move.l  #$0000ffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc11:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffffffff,d5
            move.l  #$0000ffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            or.w    d2,2(a3)
            and.w   d0,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc12:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$00000000,d5
            move.l  #$ffffffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc13:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffff0000,d5
            move.l  #$ffffffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            and.w   d0,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc14:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$0000ffff,d5
            move.l  #$ffffffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            and.w   d0,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            and.w   d0,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

fillc15:
            movem.l a0/a3/a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi     .end
            add.w   d0,d0
            lea     xa,a1
            adda.w  d0,a1
            lea     xb,a2
            adda.w  d0,a2
            lea     ytab,a4
            move.w  (a4,d0.w),d0
            lea     (a0,d0.w),a4
            lea     ltab,a0
            lea     rtab,a6
            move.l  #$ffffffff,d5
            move.l  #$ffffffff,d7
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         add.w   d0,d0
            add.w   d0,d0
            move.l  (a0,d0.w),d2        ; left mask : offset
            add.w   d1,d1
            add.w   d1,d1
            move.l  (a6,d1.w),d3        ; right mask : offset
            lea     (a4,d2.w),a3
            move.w  d3,d6
            sub.w   d2,d6
            swap    d2
            swap    d3
            tst.w   d6
            bne.s   .mul
            and.w   d3,d2               ; a single word
            move.w  d2,d0
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            bra     .nx
.mul:       move.w  d2,d0               ; left word
            not.w   d0
            or.w    d2,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            move.w  d3,d2               ; right word
            move.w  d2,d0
            not.w   d0
            adda.w  d6,a3
            or.w    d2,(a3)
            or.w    d2,2(a3)
            or.w    d2,4(a3)
            or.w    d2,6(a3)
            suba.w  d6,a3
            subq.w  #8,d6
            beq     .nx
            addq.l  #8,a3
            lsr.w   #1,d6
            neg.w   d6
            jmp     .mend(pc,d6.w)
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
            move.l  d5,(a3)+
            move.l  d7,(a3)+
.mend:
.nx:        lea     160(a4),a4
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3/a6
            rts

;==============================================================
; TRUE COLOR MODE (V key) : VGA 320x240, 16 bits per pixel
;   V : 16 colours <-> True Color (the old fast pair mode is unused)
;   solid objects : Gouraud shading (vertex normals,
;                   light from the top left, ramp of 128 shades
;                   taken from the object's palette + white highlight)
;   transparent objects : faces blended at 50 %, white edges
;   background : plain black
;==============================================================

TCMODE      equ     $0100|$0010|$0000|$0004 ; VERTFLAG|VGA|COL40|BPS16 = 320x240
TCLINE      equ     640                 ; bytes per line
TCH         equ     240
TCW         equ     320                 ; width (pixels)
TCSCR       equ     TCLINE*TCH          ; 153600 bytes per screen
AMB         equ     26                  ; ambient light (0..127)
SPEC        equ     104                 ; start of the white highlight in the ramp
LX          equ     -6554               ; light direction (x2^14)
LY          equ     -9011               ;  (top left, in front)
LZ          equ     -11960

;--------------------------------------------------------------
; spanupd : extends the outline of the current line with d0..d1
;           (a1 = xa+2y+2 : curl/curr are at a fixed offset)
;--------------------------------------------------------------
SPANL       equ     4*480               ; curl - xa
SPANR       equ     5*480               ; curr - xa
spanupd     MACRO                       ; (outline unused : rectangle clearing)
            ENDM

;--------------------------------------------------------------
; 16 colours / True Color dispatch
;--------------------------------------------------------------
fullclear:  tst.w   tcmode
            bne     tcfullclear
            bra     clear
anyboxclear:
            tst.w   tcmode
            bne     tcboxclear          ; True Color : rectangle (black background)
            bra     boxclear
tpoly:      tst.w   tcmode
            bne     tctrace
            bra     tracepoly
fillT:      cmp.w   #1,tcmode           ; 0 = 16 colours, 1 = TC, 2 = fast TC
            blo     fillor
            beq     tcfillb
            bra     tcfillb2
fillS:      cmp.w   #1,tcmode
            blo     fillcol
            tst.w   uvmode              ; (u,v) : Phong, chrome, texture
            bne.s   .ph
            cmp.w   #1,tcmode
            beq     tcfillg
            bra     tcfillg2
.ph:        cmp.w   #1,tcmode
            beq     tcfillp
            bra     tcfillp2
dline:      cmp.w   #1,tcmode
            blo     line
            beq     tcline
            bra     tcline2

;--------------------------------------------------------------
; setvideo : programs the mode (tcmode) and restarts cleanly
;--------------------------------------------------------------
setvideo:
            movem.l d0-d7/a0-a6,-(sp)
            tst.w   tcmode
            beq.s   .m16
            move.w  #TCMODE,d0          ; True Color (VGA)
            move.w  #TCH,scrh
            move.w  #120,scrcy
            bra.s   .set
.m16:       move.w  #200,scrh
            move.w  #100,scrcy
            tst.w   vgamon
            beq.s   .rgb
            move.w  #VGAMODE,d0         ; VGA 16 colours
.set:       move.w  d0,-(sp)            ; Setscreen(log,phys,3,mode)
            move.w  #3,-(sp)
            move.l  buf1,-(sp)
            move.l  buf1,-(sp)
            move.w  #5,-(sp)
            trap    #14
            lea     14(sp),sp
            bra.s   .ok
.rgb:       clr.w   -(sp)               ; RGB : ST low
            move.l  buf1,-(sp)
            move.l  buf1,-(sp)
            move.w  #5,-(sp)
            trap    #14
            lea     12(sp),sp
.ok:        lea     by16,a0             ; (XBIOS destroys a0 : reload it here)
            tst.w   tcmode
            beq.s   .b16
            lea     bytc,a0
.b16:       lea     bandy,a1            ; band lines of the mode
            moveq   #6,d0
.by:        move.w  (a0)+,(a1)+
            dbra    d0,.by
            move.w  scrh,d0
            subq.w  #1,d0
            move.w  d0,scrhm1
            move.l  buf3,disp
            move.l  buf1,front
            move.l  buf2,back
            move.w  #3,fullclr          ; clear the three screens
            lea     box1,a0             ; no old drawing
            moveq   #2,d0
.bx:        move.l  #$7fff0000,(a0)+
            clr.l   (a0)+
            dbra    d0,.bx
            clr.w   sigok               ; menu to rebuild
            lea     bandcache,a1        ; bands to redraw
            moveq   #NSLOTS-1,d0
.ib:        move.w  #-1,(a1)
            lea     SLOTSZ(a1),a1
            dbra    d0,.ib
            tst.w   tcmode
            bne.s   .out
            pea     objpal              ; 16 colours : the palette
            move.w  #6,-(sp)
            trap    #14
            addq.l  #6,sp
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

; V key : toggle (VGA only)
togglevideo:
            tst.w   vgamon
            beq.s   .out
            eori.w  #1,tcmode           ; 16 colours <-> True Color
            bsr     setvideo
.out:       rts

;--------------------------------------------------------------
; gentc : True Color tables (lines, background)
;--------------------------------------------------------------
gentc:
            lea     ytc,a0
            moveq   #0,d0
            move.w  #TCH-1,d1
.y:         move.l  d0,(a0)+
            add.l   #TCLINE,d0
            dbra    d1,.y
            ; rcp16[d] = 65536 / d (edge slopes), rcp16[0] = 0
            lea     rcp16,a0
            clr.l   (a0)+
            moveq   #1,d1
.r16:       move.l  #65536,d0
            divu.l  d1,d0
            move.l  d0,(a0)+
            addq.w  #1,d1
            cmp.w   #TCH+1,d1
            blo.s   .r16
            ; recip[w] = 32767 / w (Gouraud step per line), recip[0] = 0
            lea     recip,a0
            clr.w   (a0)+
            moveq   #1,d1
.rc:        move.l  #32767,d0
            divu    d1,d0
            move.w  d0,(a0)+
            addq.w  #1,d1
            cmp.w   #TCW,d1
            blo.s   .rc
            move.l  #-1,tclcol          ; white lines
            clr.w   phok                ; Phong / chrome maps : computed
                                        ; the first time these renderings are chosen (S)
            ; background : plain black (lets back faces be written without reading)
            lea     bgtab,a0
            move.w  #TCH-1,d1
.g:         clr.l   (a0)+
            dbra    d1,.g
            rts

;--------------------------------------------------------------
; mkramp : Gouraud ramp (128 RGB565 shades) from objpal 1..14,
;          highlight towards white at the top ; colours of the T faces
;--------------------------------------------------------------
stedec:     ; d0.w = STE nibble -> d0.w = 0..255
            and.w   #15,d0
            move.w  d0,d1
            and.w   #7,d0
            add.w   d0,d0
            lsr.w   #3,d1
            or.w    d1,d0               ; 0..15
            mulu    #17,d0
            rts

mkramp:
            movem.l d0-d7/a0-a3,-(sp)
            clr.w   curmat
.mat:       bsr     matrgbt             ; 14 colours of the material -> rgbtab
            move.w  curmat,d0           ; addresses of the material's ramps
            move.w  d0,d1
            mulu    #448,d1
            move.l  d1,d2
            add.l   #ramp,d1
            move.l  d1,mr
            add.l   #rampc,d2
            move.l  d2,mrc
            move.w  d0,d1
            mulu    #896,d1
            move.l  d1,d2
            add.l   #ramp2,d1
            move.l  d1,mr2
            add.l   #ramp2c,d2
            move.l  d2,mr2c
            moveq   #0,d1
            move.w  d0,d1
            swap    d1
            add.l   #phtex,d1
            move.l  d1,mph
            ; 128 shades
            move.l  mr,a2
            moveq   #0,d7               ; i
.r:         move.w  d7,d0
            mulu    #13,d0              ; position 0..1651 over 13 intervals
            divu    #127,d0
            move.w  d0,d5               ; k (0..13)
            swap    d0
            move.w  d0,d4               ; f (0..126)
            cmp.w   #13,d5
            blo.s   .k
            moveq   #12,d5
            move.w  #127,d4
.k:         mulu    #6,d5
            lea     rgbtab,a0
            adda.w  d5,a0               ; colour k and k+1
            moveq   #2,d6
            lea     tmprgb,a1
.cc:        move.w  (a0),d0             ; c = (ck*(127-f) + ck1*f) / 127
            move.w  #127,d1
            sub.w   d4,d1
            mulu    d1,d0
            move.w  6(a0),d1
            mulu    d4,d1
            add.l   d1,d0
            divu    #127,d0
            tst.w   mflat               ; flat : no highlight
            bne.s   .ns
            cmp.w   #SPEC,d7            ; highlight : towards white
            blo.s   .ns
            move.w  d7,d1
            sub.w   #SPEC,d1
            move.w  #255,d2
            sub.w   d0,d2
            mulu    d1,d2
            divu    #127-SPEC,d2
            add.w   d2,d0
.ns:        move.w  d0,(a1)+
            addq.l  #2,a0
            dbra    d6,.cc
            bsr     pack565
            move.w  d0,(a2)+
            move.l  mr2,a1              ; same shade on 2 pixels (fast TC)
            move.w  d7,d1
            lsl.w   #2,d1
            move.w  d0,(a1,d1.w)
            move.w  d0,2(a1,d1.w)
            addq.w  #1,d7
            cmp.w   #128,d7
            blo     .r
            ; margins of 48 shades on each side (approximate step on quads)
            move.l  mr,a0
            move.w  (a0),d0
            move.w  254(a0),d1
            lea     -96(a0),a1
            moveq   #47,d2
.mg:        move.w  d0,(a1)+
            move.w  d1,96+256-2(a1)
            dbra    d2,.mg
            move.l  mr2,a0
            move.l  (a0),d0
            move.l  508(a0),d1
            lea     -192(a0),a1
            moveq   #47,d2
.mg2:       move.l  d0,(a1)+
            move.l  d1,192+512-4(a1)
            dbra    d2,.mg2
            ; cel shading : 4 sharp steps taken from the ramp
            move.l  mr,a0
            move.l  mrc,a1
            move.l  mr2c,a2
            moveq   #0,d7
.cl:        moveq   #34,d1              ; shadow
            cmp.w   #52,d7
            blo.s   .cs
            moveq   #68,d1              ; mid-tone
            cmp.w   #84,d7
            blo.s   .cs
            moveq   #100,d1             ; lit
            cmp.w   #114,d7
            blo.s   .cs
            moveq   #124,d1             ; highlight
.cs:        add.w   d1,d1
            move.w  (a0,d1.w),d0
            move.w  d0,(a1)+
            move.w  d0,(a2)+
            move.w  d0,(a2)+
            addq.w  #1,d7
            cmp.w   #128,d7
            blo.s   .cl
            move.l  mrc,a0
            move.w  (a0),d0
            move.w  254(a0),d1
            lea     -96(a0),a1
            moveq   #47,d2
.mc:        move.w  d0,(a1)+
            move.w  d1,96+256-2(a1)
            dbra    d2,.mc
            move.l  mr2c,a0
            move.l  (a0),d0
            move.l  508(a0),d1
            lea     -192(a0),a1
            moveq   #47,d2
.mc2:       move.l  d0,(a1)+
            move.l  d1,192+512-4(a1)
            dbra    d2,.mc2
            ; fake Phong : shade map -> colours of this object
            tst.w   phok
            beq.s   .nph
            lea     phint,a0
            move.l  mph,a1
            move.l  mr,a2
            move.w  #127,d7
.pv:        moveq   #127,d6
.pu:        moveq   #0,d0
            move.b  (a0)+,d0
            add.w   d0,d0
            move.w  (a2,d0.w),(a1)+
            dbra    d6,.pu
            lea     256(a1),a1          ; lines of 256 texels
            dbra    d7,.pv
.nph:       addq.w  #1,curmat           ; next material
            move.w  curmat,d0
            cmp.w   nmat,d0
            blo     .mat
            ; colours of the transparent faces : planes 1..3 -> objpal[2,4,8]
            lea     tchalf+2,a2
            moveq   #2,d7
            moveq   #2,d6               ; palette index 2, 4, 8
.t:         lea     objpal,a0
            move.w  d6,d0
            add.w   d0,d0
            move.w  (a0,d0.w),d5
            lea     tmprgb,a1
            moveq   #8,d4
.tc:        move.w  d5,d0
            lsr.w   d4,d0
            bsr     stedec
            add.w   d0,d0               ; brighter (x2)
            cmp.w   #255,d0
            bls.s   .tl
            move.w  #255,d0
.tl:        move.w  d0,(a1)+
            subq.w  #4,d4
            bpl.s   .tc
            bsr     pack565
            lsr.w   #1,d0               ; half (for the 50 % blend)
            and.w   #$7bef,d0
            move.w  d0,(a2)+
            add.w   d6,d6
            dbra    d7,.t
            movem.l (sp)+,d0-d7/a0-a3
            rts

;--------------------------------------------------------------
; matrgbt : rgbtab (14 colours 0..255) of material curmat, mflat
;   old format : material 0 = objpal 1..14 (2..14 if there are
;   F 3 faces), material 1 = flat objpal 1 ; materials (C) : the
;   colour of the material from 32 % (dark) to 100 %
;--------------------------------------------------------------
matrgbt:
            movem.l d0-d7/a0-a1,-(sp)
            clr.w   mflat
            lea     rgbtab,a1
            tst.w   matmode
            bne.s   .mm
            tst.w   curmat
            bne.s   .fl
            lea     objpal+2,a0         ; material 0
            tst.w   lflat
            beq.s   .l
            lea     objpal+4,a0         ; (1 = flat : 2..14, 2 doubled)
            move.w  (a0),d6
            bsr.s   .dec
            moveq   #12,d7
            bra.s   .l1
.l:         moveq   #13,d7
.l1:        move.w  (a0)+,d6
            bsr.s   .dec
            dbra    d7,.l1
            bra.s   .out
.fl:        move.w  #1,mflat            ; flat : objpal 1 everywhere
            moveq   #13,d7
.f1:        move.w  objpal+2,d6
            bsr.s   .dec
            dbra    d7,.f1
            bra.s   .out
.mm:        move.w  curmat,d0           ; material : c * (1066+174 i) / 3328
            mulu    #6,d0
            lea     matrgb,a0
            adda.l  d0,a0
            moveq   #0,d7               ; i
.mi:        move.w  d7,d1
            mulu    #174,d1
            add.w   #1066,d1
            moveq   #0,d5
.mc:        move.w  (a0,d5.w*2),d0
            mulu    #17,d0              ; 0..255
            mulu    d1,d0
            divu    #3328,d0
            move.w  d0,(a1)+
            addq.w  #1,d5
            cmp.w   #3,d5
            blo.s   .mc
            addq.w  #1,d7
            cmp.w   #14,d7
            blo.s   .mi
.out:       movem.l (sp)+,d0-d7/a0-a1
            rts
.dec:       move.w  d6,d0               ; STE word d6 -> 3 words (a1)+
            lsr.w   #8,d0
            bsr     stedec
            move.w  d0,(a1)+
            move.w  d6,d0
            lsr.w   #4,d0
            bsr     stedec
            move.w  d0,(a1)+
            move.w  d6,d0
            bsr     stedec
            move.w  d0,(a1)+
            rts

;--------------------------------------------------------------
; genph : fake Phong map (once at start-up)
;   texel (u,v) = normal seen from the front : nx,ny = (u,v - 64) / 64,
;   nz = -sqrt(1 - nx2 - ny2) ; shade = same formula as the
;   Gouraud (ambient + diffuse, highlight at the top of the ramp).
;   The faces interpolate (u,v) = rotated normal of their vertices :
;   the light spot slides across the middle of the faces.
;--------------------------------------------------------------
genph:
            movem.l d0-d7/a0-a6,-(sp)
            bsr     phinit
            lea     phint,a0
            lea     phchr,a1
            moveq   #0,d7               ; v
.v:         moveq   #0,d6               ; u
.u:         bsr     phnorm
            move.w  d4,d0
            muls    #LX,d0
            move.w  d5,d1
            muls    #LY,d1
            add.l   d1,d0
            move.w  d2,d1
            muls    #LZ,d1
            add.l   d1,d0
            asr.l   #8,d0
            asr.l   #6,d0
            bpl.s   .p
            moveq   #0,d0
.p:         mulu    #(127-AMB)*128/64,d0
            lsr.l   #8,d0
            add.w   #AMB*128,d0
            cmp.w   #127*128,d0
            bls.s   .c
            move.w  #127*128,d0
.c:         lsr.w   #7,d0
            move.b  d0,(a0)+
            bsr     chrtexel            ; chrome map, same texel
            addq.w  #1,d6
            cmp.w   #128,d6
            blo     .u
            lea     256(a1),a1
            addq.w  #1,d7
            cmp.w   #128,d7
            blo     .v
            movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; phnorm : texel (d6 = u, d7 = v) -> normal seen from the front
;          d4 = nx, d5 = ny, d2 = nz (x 2^14, nz <= 0)
;--------------------------------------------------------------
phnorm:
            move.w  d6,d4               ; nx, ny : table (depends only on u / v)
            add.w   d4,d4
            move.w  phnx(pc,d4.w),d4
            move.w  d7,d5
            add.w   d5,d5
            move.w  phnx(pc,d5.w),d5
            move.w  d4,d2               ; r2 = nx2 + ny2
            muls    d4,d2
            move.w  d5,d3
            muls    d5,d3
            add.l   d3,d2
            move.l  #$10000000,d0
            sub.l   d2,d0
            bgt.s   .in
            moveq   #0,d2               ; outside the disc (never reached by
            rts                         ; unit normals) : edge
.in:        lsr.l   #8,d0               ; nz = -sqrt(2^28 - r2) : table
            lsr.l   #6,d0
            add.w   d0,d0
            lea     sqtab,a6
            move.w  (a6,d0.w),d2
            neg.w   d2
            rts
phnx:       ds.w    128                 ; (u*256+128-16384)*64/63

; phinit : genph tables (once) : phnx, sqtab[i] = sqrt(i*2^14)
phinit:
            lea     phnx(pc),a6
            moveq   #0,d6
.n:         move.w  d6,d4
            lsl.w   #8,d4
            add.w   #128,d4
            sub.w   #16384,d4
            ext.l   d4
            asl.l   #6,d4
            divs    #63,d4
            move.w  d4,(a6)+
            addq.w  #1,d6
            cmp.w   #128,d6
            blo.s   .n
            lea     sqtab,a6            ; increasing roots : k moves forward
            moveq   #0,d6               ; i
            moveq   #0,d5               ; k
.s:         move.l  d6,d0
            lsl.l   #8,d0
            lsl.l   #6,d0               ; v = i * 2^14
.k:         move.l  d5,d1
            addq.l  #1,d1
            mulu.l  d1,d1               ; (k+1)^2 <= v ?
            cmp.l   d0,d1
            bhi.s   .w
            addq.l  #1,d5
            bra.s   .k
.w:         move.w  d5,(a6)+
            addq.l  #1,d6
            cmp.l   #16384,d6
            bls.s   .s
            rts

;--------------------------------------------------------------
; chrtexel : map of the chrome environment mapping (at start-up)
;   reflection of the view on the normal : R = V - 2 (n.V) n, V = (0,0,1)
;   R upwards   : sky, dark blue at the top -> white at the horizon
;   R downwards : brown ground (light at the horizon), horizon line
;   + the sun (same light as the Gouraud) in white
;   fixed colours : chrome reflects the scenery, not the colour
;   of the object. (one texel, called by genph : d4,d5,d2 = normal,
;   d0 = Gouraud shade, a1 = output)
;--------------------------------------------------------------
chrtexel:
            movem.l d0-d7/a0,-(sp)
            move.w  d0,-(sp)            ; shade (sun)
            move.w  d2,d3
            neg.w   d3                  ; |nz|
            move.w  d5,d0               ; ry = 2 |nz| ny  (down > 0)
            muls    d3,d0
            asr.l   #8,d0
            asr.l   #5,d0
            move.w  d4,d1               ; rx = 2 |nz| nx
            muls    d3,d1
            asr.l   #8,d1
            asr.l   #5,d1
            lea     tmprgb,a0
            tst.w   d0
            bgt.s   .sol
            neg.w   d0                  ; sky : t = -ry (0..16384)
            move.w  #170,d1
            mulu    d0,d1
            moveq   #14,d2
            lsr.l   d2,d1
            move.w  #200,d3
            sub.w   d1,d3
            move.w  d3,(a0)+            ; r 200 -> 30
            move.w  #230,d3
            sub.w   d1,d3
            move.w  d3,(a0)+            ; g 230 -> 60
            move.w  #95,d1
            mulu    d0,d1
            lsr.l   d2,d1
            move.w  #255,d3
            sub.w   d1,d3
            move.w  d3,(a0)+            ; b 255 -> 160
            bra.s   .sun
.sol:       cmp.w   #900,d0
            bhs.s   .dam
            move.w  #255,(a0)+          ; horizon line
            move.w  #235,(a0)+
            move.w  #190,(a0)+
            bra.s   .sun
.dam:       sub.w   #900,d0             ; ground : light brown at the horizon
            mulu    #65536/15484,d0     ;  -> very dark brown at the bottom
            lsr.l   #8,d0               ; d0 = 0..255
            move.w  #255,d1
            sub.w   d0,d1               ; weight of the horizon
            move.w  #180,d2             ; r 180 -> 35
            mulu    d1,d2
            move.w  #35,d3
            mulu    d0,d3
            add.l   d3,d2
            lsr.l   #8,d2
            move.w  d2,(a0)+
            move.w  #120,d2             ; g 120 -> 18
            mulu    d1,d2
            move.w  #18,d3
            mulu    d0,d3
            add.l   d3,d2
            lsr.l   #8,d2
            move.w  d2,(a0)+
            move.w  #65,d2              ; b 65 -> 8
            mulu    d1,d2
            move.w  #8,d3
            mulu    d0,d3
            add.l   d3,d2
            lsr.l   #8,d2
            move.w  d2,(a0)+
.sun:       move.w  (sp)+,d0            ; sun : white if the Gouraud
                                        ; light is strong there
            sub.w   #114,d0
            ble.s   .ns
            lea     tmprgb,a0
            moveq   #2,d2
.sb:        move.w  #255,d1
            sub.w   (a0),d1
            mulu    d0,d1
            divu    #13,d1
            add.w   d1,(a0)+
            dbra    d2,.sb
.ns:        bsr     pack565
            move.w  d0,(a1)+
            movem.l (sp)+,d0-d7/a0
            rts

; pack565 : tmprgb (r,g,b 0..255) -> d0.w RGB565
pack565:
            move.w  tmprgb,d0
            lsr.w   #3,d0
            lsl.w   #8,d0
            lsl.w   #3,d0
            move.w  tmprgb+2,d1
            lsr.w   #2,d1
            lsl.w   #5,d1
            or.w    d1,d0
            move.w  tmprgb+4,d1
            lsr.w   #3,d1
            or.w    d1,d0
            rts

;--------------------------------------------------------------
; vertnorms : normal of each vertex = average of the normals
;             of the neighbouring faces (x 2^14) -> vnorm (mode S)
;--------------------------------------------------------------
vertnorms:
            movem.l d0-d7/a0-a4,-(sp)
            lea     vacc,a0             ; accumulator (3 longs per vertex)
            move.w  #3*MAXV-1,d0
.z:         clr.l   (a0)+
            dbra    d0,.z
            move.w  nf,d7
            beq     .norm
            subq.w  #1,d7
            lea     objf,a3
.f:         lea     F_IDX(a3),a2
            lea     objv,a1
            bsr     cross3              ; normal of the face (d0,d1,d2)
            move.w  F_LEN(a3),d3
            ext.l   d3
            lsl.l   #8,d0               ; x 2^14 / length
            lsl.l   #6,d0
            divs.l  d3,d0
            lsl.l   #8,d1
            lsl.l   #6,d1
            divs.l  d3,d1
            lsl.l   #8,d2
            lsl.l   #6,d2
            divs.l  d3,d2
            move.w  F_N(a3),d6
            subq.w  #1,d6
.v:         moveq   #0,d4
            move.b  (a2)+,d4
            mulu    #12,d4
            lea     vacc,a4
            adda.l  d4,a4
            add.l   d0,(a4)+
            add.l   d1,(a4)+
            add.l   d2,(a4)+
            dbra    d6,.v
            lea     FACESZ(a3),a3
            dbra    d7,.f
.norm:      move.w  nv,d7
            beq.s   .out
            subq.w  #1,d7
            lea     vacc,a0
            lea     vnorm,a1
.n:         movem.l (a0)+,d0-d2
            move.l  d0,d3               ; length (values <= 2^16)
            asr.l   #2,d3
            muls.l  d3,d3
            move.l  d1,d4
            asr.l   #2,d4
            muls.l  d4,d4
            add.l   d4,d3
            move.l  d2,d4
            asr.l   #2,d4
            muls.l  d4,d4
            add.l   d4,d3
            exg     d0,d3
            bsr     isqrt               ; |n| / 4
            exg     d0,d3
            and.l   #$ffff,d3
            bne.s   .nz
            moveq   #1,d3
.nz:        lsl.l   #2,d3
            lsl.l   #8,d0
            lsl.l   #6,d0
            divs.l  d3,d0
            move.w  d0,(a1)+
            lsl.l   #8,d1
            lsl.l   #6,d1
            divs.l  d3,d1
            move.w  d1,(a1)+
            lsl.l   #8,d2
            lsl.l   #6,d2
            divs.l  d3,d2
            move.w  d2,(a1)+
            dbra    d7,.n
.out:       movem.l (sp)+,d0-d7/a0-a4
            rts

;--------------------------------------------------------------
; tcfullclear : whole screen a0 = background
;--------------------------------------------------------------
tcfullclear:
            movem.l d0-d7/a0-a4,-(sp)
            lea     bgtab,a2
            move.l  a0,a3
            move.w  #TCH-1,d5
.row:       move.l  (a2)+,d0
            move.l  a3,a1
            moveq   #TCLINE/4/8-1,d6
.c:         move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            move.l  d0,(a1)+
            dbra    d6,.c
            lea     TCLINE(a3),a3
            dbra    d5,.row
            movem.l (sp)+,d0-d7/a0-a4
            rts

;--------------------------------------------------------------
; TRAIL (key R, True Color) : instead of clearing its old rectangle,
;   the buffer receives the previous frame (front) faded to 3/4, then
;   the object is drawn on top : each position fades out over about
;   ten frames. Per long (2 RGB565 pixels), per channel :
;   p/2 + p/4 (rounded down : reaches black exactly).
;   The rectangle of a buffer is then the union of the boxes of the
;   last TRK frames (after that, everything there is black again).
;--------------------------------------------------------------
TRK         equ     12

; boxof : a1 = rectangle of buffer a0
boxof:
            lea     box1,a1
            cmpa.l  buf1,a0
            beq.s   .o
            lea     box2,a1
            cmpa.l  buf2,a0
            beq.s   .o
            lea     box3,a1
.o:         rts

; trailbox : a2 = box of the object just computed (curbox) : added to the
;   history ; (a2) becomes the union of the last TRK boxes
trailbox:
            tst.w   tcmode
            beq.s   .off
            tst.w   trail
            bne.s   .on
.off:       clr.w   trn
            rts
.on:        movem.l d0-d7/a0,-(sp)
            tst.w   trn                 ; empty history : from slot 0
            bne.s   .h
            clr.w   trpos
.h:         lea     trhist,a0
            move.w  trpos,d0
            lsl.w   #3,d0
            move.l  (a2),(a0,d0.w)      ; history <- this box
            move.l  4(a2),4(a0,d0.w)
            move.w  trpos,d0
            addq.w  #1,d0
            cmp.w   #TRK,d0
            blo.s   .p
            moveq   #0,d0
.p:         move.w  d0,trpos
            cmp.w   #TRK,trn
            bhs.s   .u
            addq.w  #1,trn
.u:         movem.w (a2),d0-d3          ; union of the history
            move.w  trn,d7
            subq.w  #1,d7
.l:         movem.w (a0)+,d4-d6/a1
            cmp.w   d4,d0
            ble.s   .1
            move.w  d4,d0
.1:         cmp.w   d5,d1
            bge.s   .2
            move.w  d5,d1
.2:         cmp.w   d6,d2
            ble.s   .3
            move.w  d6,d2
.3:         cmp.w   a1,d3
            bge.s   .4
            move.w  a1,d3
.4:         dbra    d7,.l
            movem.w d0-d3,(a2)
            movem.l (sp)+,d0-d7/a0
            rts

; trailcopy : back a0 (old rectangle (a2)) <- front faded, on the union of
;   the rectangles of the two buffers (outside its own rectangle, the
;   front is black : black is copied there, so this also clears)
trailcopy:
            movem.l d0-d7/a0-a6,-(sp)
            move.l  a0,a5               ; back
            move.l  front,a0
            bsr     boxof               ; a1 = rectangle of the front
            movem.w (a1),d0-d3
            movem.w (a2),d4-d7
            cmp.w   d4,d0
            ble.s   .1
            move.w  d4,d0
.1:         cmp.w   d5,d1
            bge.s   .2
            move.w  d5,d1
.2:         cmp.w   d6,d2
            ble.s   .3
            move.w  d6,d2
.3:         cmp.w   d7,d3
            bge.s   .4
            move.w  d7,d3
.4:         cmp.w   dirty0,d0           ; touched lines (menu bands)
            bge.s   .5
            move.w  d0,dirty0
.5:         cmp.w   dirty1,d1
            ble.s   .6
            move.w  d1,dirty1
.6:         sub.w   d0,d1               ; lines - 1
            bmi.s   .out
            lsr.w   #1,d2               ; in longs
            lsr.w   #1,d3
            sub.w   d2,d3               ; longs - 1
            bmi.s   .out
            lea     ytc,a1
            move.l  (a1,d0.w*4),d4
            lsl.w   #2,d2
            add.l   d2,d4
            lea     (a0,d4.l),a3        ; front
            lea     (a5,d4.l),a4        ; back
            move.l  #$f7def7de,d5       ; p/2 : without the low bit of each channel
            move.l  #$e79ce79c,d6       ; p/4 : without the 2 low bits
.row:       move.l  a3,a0
            move.l  a4,a1
            move.w  d3,d7
.px:        move.l  (a0)+,d0
            move.l  d0,d2
            and.l   d5,d0
            lsr.l   #1,d0
            and.l   d6,d2
            lsr.l   #2,d2
            add.l   d2,d0
            move.l  d0,(a1)+
            dbra    d7,.px
            lea     TCLINE(a3),a3
            lea     TCLINE(a4),a4
            dbra    d1,.row
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; tcboxclear : restores the background in rectangle (a2) of screen a0
;              (y0,y1,x0,x1 in pixels)
;--------------------------------------------------------------
tcboxclear:
            move.w  (a2),d4             ; y0
            move.w  2(a2),d5            ; y1
            sub.w   d4,d5
            bmi     .out
            move.w  4(a2),d2            ; x0 (even)
            and.w   #$fffe,d2
            move.w  6(a2),d3
            sub.w   d2,d3
            lsr.w   #1,d3
            addq.w  #1,d3               ; number of longs (2 pixels)
            add.w   d3,d3               ; 2 bytes of code per long
            neg.w   d3
            add.w   d2,d2               ; x0 in bytes
            move.w  d4,d0
            lsl.w   #2,d0
            lea     ytc,a3
            move.l  (a3,d0.w),d0
            lea     (a0,d0.l),a3
            adda.w  d2,a3               ; top left corner
            lea     bgtab,a2
            adda.w  d4,a2
            adda.w  d4,a2
            adda.w  d4,a2
            adda.w  d4,a2               ; colour of the 1st line
            ; longs n = 32 q + r (r = 1..32) : r first, then q blocks of
            ; 32 (the code stays in the instruction cache)
            neg.w   d3
            lsr.w   #1,d3               ; n
            subq.w  #1,d3
            move.w  d3,d6
            lsr.w   #5,d6               ; q
            and.w   #31,d3              ; r - 1
            eor.w   #31,d3              ; 32 - r : moves to skip
            add.w   d3,d3
            lea     .tb,a4
            adda.w  d3,a4               ; entry
.row:       move.l  (a2)+,d0
            move.l  a3,a1
            move.w  d6,d1
            jmp     (a4)
.tb:        rept    32
            move.l  d0,(a1)+
            endr
            dbra    d1,.tb
            lea     TCLINE(a3),a3
            dbra    d5,.row
.out:       rts

;--------------------------------------------------------------
; lspan : extends the outline of line a5 with \1..\2
;--------------------------------------------------------------
lspan       MACRO                       ; (same)
            ENDM

;--------------------------------------------------------------
; tcline : white line (d0,d1)->(d2,d3) in screen a0
;          the drawn pixels are added to the outline (curl/curr)
;--------------------------------------------------------------
tcline:
            move.l  a6,-(sp)
            cmp.w   d0,d2               ; from left to right
            bge.s   .lr
            exg     d0,d2
            exg     d1,d3
.lr:        sub.w   d0,d2               ; dx >= 0
            move.w  #TCLINE,a1
            move.w  #2,a6               ; step in curl/curr
            sub.w   d1,d3
            bge.s   .dn
            neg.w   d3
            move.w  #-TCLINE,a1
            move.w  #-2,a6
.dn:        lea     curl,a5
            adda.w  d1,a5
            adda.w  d1,a5
            move.w  d1,d4
            lsl.w   #2,d4
            lea     ytc,a4
            move.l  (a4,d4.w),d4
            lea     (a0,d4.l),a4
            adda.w  d0,a4
            adda.w  d0,a4
            move.l  tclcol,d5           ; white (black : cel outlines)
            move.w  d0,d4               ; current x
            move.w  d0,d1               ; start of the segment of the line
            cmp.w   d3,d2
            blt.s   .ym
            move.w  d2,d7
            move.w  d2,d6
            asr.w   #1,d6
.xl:        move.w  d5,(a4)+
            sub.w   d3,d6
            bpl.s   .xc
            add.w   d2,d6
            adda.w  a1,a4
            lspan   d1,d4               ; line finished : [start, x]
            adda.w  a6,a5
            move.w  d4,d1
            addq.w  #1,d1
.xc:        addq.w  #1,d4
            dbra    d7,.xl
            subq.w  #1,d4
            lspan   d1,d4
            move.l  (sp)+,a6
            rts
.ym:        move.w  d3,d7
            move.w  d3,d6
            asr.w   #1,d6
.yl:        move.w  d5,(a4)
            lspan   d4,d4
            adda.w  a1,a4
            adda.w  a6,a5
            sub.w   d2,d6
            bpl.s   .yc
            add.w   d3,d6
            addq.l  #2,a4
            addq.w  #1,d4
.yc:        dbra    d7,.yl
            move.l  (sp)+,a6
            rts

;--------------------------------------------------------------
; tctrace : face a3 -> chains xa/xb (x) and ia/ib (intensity),
;           16.16 fixed point ; fymin/fymax (a0, a3 preserved)
;--------------------------------------------------------------
tctrace:
            movem.l a0/a2/a3/a6,-(sp)
            lea     F_IDX(a3),a5
            lea     proj,a2
            lea     vint,a6
            lea     fv,a4
            lea     fvi,a0
            move.w  F_N(a3),d7
            subq.w  #1,d7
            move.w  #32767,d5
            move.w  #-32768,d6
            move.l  a3,d0               ; texture u,v of the face :
            sub.l   #objf,d0            ; fuv + (a3 - objf) (16 bytes)
            lea     fuv,a1
            adda.l  d0,a1
.cp:        moveq   #0,d4
            move.b  (a5)+,d4
            move.w  d4,d3
            add.w   d3,d3
            move.w  uvmode,d0
            beq.s   .gi
            subq.w  #1,d0
            bne.s   .tx
            move.w  2*MAXV(a6,d3.w),(a0)    ; fake Phong : u and v
            move.w  4*MAXV(a6,d3.w),20(a0)
            bra.s   .il
.tx:        moveq   #0,d3               ; texture : u,v of the face (W)
            move.b  (a1)+,d3
            lsl.w   #8,d3
            move.w  d3,(a0)
            moveq   #0,d3
            move.b  (a1)+,d3
            lsl.w   #8,d3
            move.w  d3,20(a0)
            bra.s   .il
.gi:        move.w  (a6,d3.w),(a0)      ; intensity of the vertex
.il:        addq.l  #2,a0
            lsl.w   #2,d4
            move.l  (a2,d4.w),d0
            move.l  d0,(a4)+
            cmp.w   d5,d0
            bge.s   .c1
            move.w  d0,d5
.c1:        cmp.w   d6,d0
            ble.s   .c2
            move.w  d0,d6
.c2:        dbra    d7,.cp
            move.l  fv,(a4)             ; wrap around
            move.w  fvi,(a0)
            move.w  fvv,20(a0)
            move.w  d5,fymin
            cmp.w   d5,d6
            bne.s   .h
            subq.w  #1,d6
.h:         move.w  d6,fymax


            lea     fv,a4
            lea     fvi,a5
            lea     rcp16,a0            ; 65536 / dy (no division)
            move.w  F_N(a3),d7
            subq.w  #1,d7
.ed:        movem.w (a4),d0-d3          ; x0,y0,x1,y1
            addq.l  #4,a4
            move.w  (a5)+,d4            ; i0
            move.w  (a5),d5             ; i1
            move.w  18(a5),d6           ; v0 (fake Phong)
            move.w  20(a5),a2           ; v1
            lea     xa,a1
            lea     ia,a6
            cmp.w   d1,d3
            bgt.s   .go
            beq     .nx
            exg     d0,d2               ; going up : chain B
            exg     d1,d3
            exg     d4,d5
            exg     d6,a2
            lea     xb,a1
            lea     ib,a6
.go:        add.w   d1,a1
            add.w   d1,a1
            add.w   d1,a6
            add.w   d1,a6
            sub.w   d1,d3               ; dy > 0
            ext.l   d3
            sub.w   d0,d2               ; dx << 16 / dy = dx * (65536/dy)
            ext.l   d2
            muls.l  (a0,d3.w*4),d2
            swap    d0
            move.w  #$8000,d0
            sub.w   d4,d5               ; di << 16 / dy
            ext.l   d5
            muls.l  (a0,d3.w*4),d5
            swap    d4
            clr.w   d4
            move.w  d7,-(sp)
            tst.w   uvmode
            bne.s   .lq0
.lp:        move.l  d0,d1
            swap    d1
            move.w  d1,(a1)+
            move.l  d4,d1
            swap    d1
            move.w  d1,(a6)+
            add.l   d2,d0
            add.l   d5,d4
            dbra    d3,.lp
            move.w  (sp)+,d7
            bra.s   .nx
.lq0:       move.l  a2,d1               ; fake Phong : v as well (va/vb)
            sub.w   d6,d1
            ext.l   d1
            muls.l  (a0,d3.w*4),d1
            move.l  d1,a2
            swap    d6
            clr.w   d6
.lq:        move.l  d0,d1
            swap    d1
            move.w  d1,(a1)+
            move.l  d6,d1
            swap    d1
            move.w  d1,960(a6)
            move.l  d4,d1
            swap    d1
            move.w  d1,(a6)+
            add.l   d2,d0
            add.l   d5,d4
            add.l   a2,d6
            dbra    d3,.lq
            move.w  (sp)+,d7
.nx:        dbra    d7,.ed

            movem.l (sp)+,a0/a2/a3/a6
            rts

;--------------------------------------------------------------
; tcfillp : fake Phong - interpolated (u,v), texel of the phtex map
;   u : integer (byte, addx) + fraction ; v : 8.8 ; texel index =
;   integer v * 256 + integer u. Steps computed for each line.
;   va/vb at +1920 from xa/xb (ia/ib = u at +960)
;--------------------------------------------------------------
tcfillp:
            cmp.w   #3,F_N(a3)          ; triangle : the u,v step is the
            beq     tcfillpc            ; same on all its lines
            movem.l d0-d7/a0-a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d7
            sub.w   d0,d7
            bmi     .end
            move.w  d7,prow
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a6
            move.l  (a6,d0.w),d0
            adda.l  d0,a0
            move.l  curtex,a6           ; Phong or chrome map
            lea     recip,a4
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .a
            exg     d0,d1
            move.w  958(a2),d2          ; left u (chain B)
            move.w  958(a1),d4          ; right u
            move.w  1918(a2),d5         ; left v
            move.w  1918(a1),d7         ; right v
            bra.s   .b
.a:         move.w  958(a1),d2
            move.w  958(a2),d4
            move.w  1918(a1),d5
            move.w  1918(a2),d7
.b:         lea     (a0,d0.w*2),a3      ; 1st pixel
            sub.w   d0,d1               ; width - 1
            move.w  (a4,d1.w*2),d6      ; 32767 / width
            sub.w   d5,d7
            muls    d6,d7
            add.l   d7,d7
            swap    d7                  ; v step (8.8)
            sub.w   d2,d4
            muls    d6,d4
            asr.l   #7,d4               ; u step (16.16)
            move.w  d4,d6               ; fraction
            swap    d4                  ; integer
            move.w  d2,d0
            lsl.w   #8,d0               ; fraction of u
            lsr.w   #8,d2               ; integer of u
            moveq   #0,d3               ; 32-bit index (high = 0)
.px:        move.w  d5,d3               ; integer v . (fraction v)
            move.b  d2,d3               ; integer v . integer u
            move.w  (a6,d3.l*2),(a3)+   ; (index 0..65535 : v wraps)
            add.w   d6,d0
            addx.b  d4,d2
            add.w   d7,d5
            dbra    d1,.px
            lea     TCLINE(a0),a0
            subq.w  #1,prow
            bpl.s   .fy
.end:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; tcfillpc : tcfillp for a triangle (Phong, chrome, mapping) : the u,v
;   step along a line is the same on all its lines (exact for a plane
;   triangle) : computed once on the widest line (best precision)
;   instead of 2 multiplications on each line. (On a face of 4
;   vertices or more it is not exact : u,v could go past the end
;   values of a line, into the black corners of the chrome map.)
;--------------------------------------------------------------
tcfillpc:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d7
            sub.w   d0,d7
            bmi     .end
            move.w  d7,prow
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a6
            move.l  (a6,d0.w),d0
            adda.l  d0,a0
            ; --- widest line ---
            move.l  a1,a3
            move.l  a2,a5
            moveq   #-1,d6
            move.w  d7,d5
.w:         move.w  (a5)+,d1
            sub.w   (a3)+,d1
            bpl.s   .w1
            neg.w   d1
.w1:        cmp.w   d6,d1
            ble.s   .w2
            move.w  d1,d6
            move.w  d5,d4
.w2:        dbra    d5,.w
            sub.w   d7,d4
            neg.w   d4                  ; its line - fymin
            add.w   d4,d4
            lea     (a1,d4.w),a3
            lea     (a2,d4.w),a5
            move.w  (a3),d0
            move.w  (a5),d1
            cmp.w   d0,d1
            bge.s   .wa
            exg     d0,d1
            move.w  960(a5),d2          ; left u (chain B)
            move.w  960(a3),d4          ; right u
            move.w  1920(a5),d5         ; left v
            move.w  1920(a3),d7         ; right v
            bra.s   .wb
.wa:        move.w  960(a3),d2
            move.w  960(a5),d4
            move.w  1920(a3),d5
            move.w  1920(a5),d7
.wb:        sub.w   d0,d1               ; width - 1
            lea     recip,a4
            move.w  (a4,d1.w*2),d6      ; 32767 / width
            sub.w   d5,d7
            muls    d6,d7
            add.l   d7,d7
            swap    d7                  ; v step (8.8)
            sub.w   d2,d4
            muls    d6,d4
            asr.l   #7,d4               ; u step (16.16)
            move.w  d4,d6               ; fraction
            swap    d4                  ; integer
            move.l  curtex,a6           ; Phong or chrome map
            ; --- lines : left end, then the same steps ---
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .a
            exg     d0,d1
            move.w  958(a2),d2          ; left u (chain B)
            move.w  1918(a2),d5         ; left v
            bra.s   .b
.a:         move.w  958(a1),d2
            move.w  1918(a1),d5
.b:         lea     (a0,d0.w*2),a3      ; 1st pixel
            sub.w   d0,d1               ; width - 1
            move.w  d2,d0
            lsl.w   #8,d0               ; fraction of u
            lsr.w   #8,d2               ; integer of u
            moveq   #0,d3               ; 32-bit index (high = 0)
.px:        move.w  d5,d3               ; integer v . (fraction v)
            move.b  d2,d3               ; integer v . integer u
            move.w  (a6,d3.l*2),(a3)+   ; (index 0..65535 : v wraps)
            add.w   d6,d0
            addx.b  d4,d2
            add.w   d7,d5
            dbra    d1,.px
            lea     TCLINE(a0),a0
            subq.w  #1,prow
            bpl.s   .fy
.end:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; tcfillp2 : same by pairs of pixels (fast TC)
;--------------------------------------------------------------
tcfillp2:
            movem.l d0-d7/a0-a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d7
            sub.w   d0,d7
            bmi     .end
            move.w  d7,prow
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a6
            move.l  (a6,d0.w),d0
            adda.l  d0,a0
            move.l  curtex,a6
            lea     recip,a4
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .a
            exg     d0,d1
            move.w  958(a2),d2
            move.w  958(a1),d4
            move.w  1918(a2),d5
            move.w  1918(a1),d7
            bra.s   .b
.a:         move.w  958(a1),d2
            move.w  958(a2),d4
            move.w  1918(a1),d5
            move.w  1918(a2),d7
.b:         and.w   #$fffe,d0           ; starting pair
            lea     (a0,d0.w*2),a3
            sub.w   d0,d1
            move.w  d1,d6
            and.w   #$fffe,d6
            move.w  (a4,d6.w*2),d6      ; 32767 / pair width
            lsr.w   #1,d1               ; pairs - 1
            sub.w   d5,d7
            muls    d6,d7
            asl.l   #2,d7
            swap    d7                  ; v step per pair
            sub.w   d2,d4
            muls    d6,d4
            asr.l   #6,d4               ; u step per pair
            move.w  d4,d6
            swap    d4
            move.w  d2,d0
            lsl.w   #8,d0
            lsr.w   #8,d2
            moveq   #0,d3
.px:        move.w  d5,d3
            move.b  d2,d3
            move.w  (a6,d3.l*2),a5
            move.w  a5,(a3)+
            move.w  a5,(a3)+
            add.w   d6,d0
            addx.b  d4,d2
            add.w   d7,d5
            dbra    d1,.px
            lea     TCLINE(a0),a0
            subq.w  #1,prow
            bpl.s   .fy
.end:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; tcfillg : fills the face with Gouraud (030 version, used when the
;   DSP cannot do it) ; step computed for each line : (iR - iL) *
;   recip[width] (one multiplication per line, no division). The old
;   single step per face, measured on the middle line, overflowed the
;   ramp on thin faces seen at an angle : white dots (highlight)
;   flickering along the edges. Here the shade always stays
;   between those of the two ends of the line.
;   per pixel 3 instructions + dbra ; integer part = index in the
;   ramp, fraction + carry (addx). Deliberately short loop :
;   unrolled, it would no longer fit in the instruction cache (256 bytes)
;   ia/ib are at +960 bytes from xa/xb
;--------------------------------------------------------------
tcfillg:
            movem.l a0/a3-a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d7
            sub.w   d0,d7
            bmi     .end
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a6
            move.l  (a6,d0.w),d0
            adda.l  d0,a0               ; a0 = start of the line
            move.l  curramp,a6          ; ramp (Gouraud / cel, margins)
            lea     recip,a4
.fy:        move.w  (a1)+,d0            ; x of the two chains
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .a
            exg     d0,d1
            move.w  958(a2),d3          ; left intensity (chain B)
            move.w  958(a1),d4          ; right (chain A)
            bra.s   .b
.a:         move.w  958(a1),d3          ; left intensity (chain A)
            move.w  958(a2),d4
.b:         sub.w   d3,d4               ; iR - iL (7 fraction bits)
            move.w  d1,d6
            sub.w   d0,d6               ; width - 1
            muls    (a4,d6.w*2),d4      ; x 32767/width
            asr.l   #6,d4               ; 16.16 step in shades
            move.w  d4,d6               ; fraction (d6) . integer (d4)
            swap    d4
            move.w  d3,d5
            lsr.w   #7,d5               ; integer shade
            move.w  d3,d2
            lsl.w   #8,d2
            add.w   d2,d2               ; fraction (<< 9)
            lea     (a0,d0.w*2),a3      ; 1st pixel
            sub.w   d0,d1               ; n - 1
.px:        move.w  (a6,d5.w*2),(a3)+   ; pixel = ramp[integer]
            add.w   d6,d2               ; fraction += step
            addx.w  d4,d5               ; integer += step + carry
            dbra    d1,.px              ; (short loop : fits in the cache)
.tend:      lea     TCLINE(a0),a0
            dbra    d7,.fy
.end:       movem.l (sp)+,a0/a3-a6
            rts

;--------------------------------------------------------------
; tcfillg2 : same by pairs of pixels (fast TC), ramp of longs
;--------------------------------------------------------------
tcfillg2:
            movem.l a0/a3-a6,-(sp)
            move.w  fymin,d0
            move.w  fymax,d7
            sub.w   d0,d7
            bmi     .end
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a6
            move.l  (a6,d0.w),d0
            adda.l  d0,a0
            move.l  curramp2,a6
            lea     recip,a4
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .a
            exg     d0,d1
            move.w  958(a2),d3
            move.w  958(a1),d4
            bra.s   .b
.a:         move.w  958(a1),d3
            move.w  958(a2),d4
.b:         and.w   #$fffe,d0           ; starting pair
            sub.w   d3,d4               ; step per pair : the last
            move.w  d1,d6               ; pair ends on iR
            sub.w   d0,d6
            and.w   #$fffe,d6
            muls    (a4,d6.w*2),d4
            asr.l   #5,d4               ; x 2 (step per pair)
            move.w  d4,d6
            swap    d4
            move.w  d3,d5
            lsr.w   #7,d5
            move.w  d3,d2
            lsl.w   #8,d2
            add.w   d2,d2
            lea     (a0,d0.w*2),a3
            sub.w   d0,d1
            lsr.w   #1,d1               ; pairs - 1
.px:        move.l  (a6,d5.w*4),(a3)+
            add.w   d6,d2
            addx.w  d4,d5
            dbra    d1,.px
.tend:      lea     TCLINE(a0),a0
            dbra    d7,.fy
.end:       movem.l (sp)+,a0/a3-a6
            rts

;--------------------------------------------------------------
; tcfillb : fills the face (xa/xb) blended 50 % with the background
;           colour = tchalf[plane] (already divided by 2)
;--------------------------------------------------------------
tcfillb:
            movem.l a0/a3,-(sp)
            move.w  F_COL(a3),d0
            add.w   d0,d0
            lea     tchalf,a1
            move.w  (a1,d0.w),d6        ; colour / 2 (on 2 pixels)
            swap    d6
            move.w  (a1,d0.w),d6
            move.l  #$7bef7bef,d5       ; half mask
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi.s   .end
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a4
            move.l  (a4,d0.w),d0
            adda.l  d0,a0
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         move.w  d1,d7
            sub.w   d0,d7               ; n - 1
            lea     (a0,d0.w),a3
            adda.w  d0,a3
            lsr.w   #1,d7               ; pixel pairs - 1 (C = n even)
            bcc.s   .odd
.px:        move.l  (a3),d0             ; 2 pixels : background/2 + colour/2
            lsr.l   #1,d0
            and.l   d5,d0
            add.l   d6,d0
            move.l  d0,(a3)+
            dbra    d7,.px
            bra.s   .nr
.odd:       tst.w   d7                  ; n odd : a single pixel
            beq.s   .one
            subq.w  #1,d7
.px2:       move.l  (a3),d0
            lsr.l   #1,d0
            and.l   d5,d0
            add.l   d6,d0
            move.l  d0,(a3)+
            dbra    d7,.px2
.one:       move.w  (a3),d0
            lsr.w   #1,d0
            and.w   d5,d0
            add.w   d6,d0
            move.w  d0,(a3)
.nr:        lea     TCLINE(a0),a0
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3
            rts

;==============================================================
; FAST TC (old 3rd mode, no longer selectable) : pixels computed by
; pairs (160 x 240 effective), one shade for 2 pixels written in a move.l
;==============================================================

;--------------------------------------------------------------
; tcfillb2 : 50 % blend by aligned pairs (always longs)
;--------------------------------------------------------------
tcfillb2:
            movem.l a0/a3,-(sp)
            move.w  F_COL(a3),d0
            add.w   d0,d0
            lea     tchalf,a1
            move.w  (a1,d0.w),d6
            swap    d6
            move.w  (a1,d0.w),d6
            move.l  #$7bef7bef,d5
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi.s   .end
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a4
            move.l  (a4,d0.w),d0
            adda.l  d0,a0
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         and.w   #$fffe,d0
            move.w  d1,d7
            sub.w   d0,d7
            lsr.w   #1,d7               ; pairs - 1
            lea     (a0,d0.w),a3
            adda.w  d0,a3
.px:        move.l  (a3),d0
            lsr.l   #1,d0
            and.l   d5,d0
            add.l   d6,d0
            move.l  d0,(a3)+
            dbra    d7,.px
            lea     TCLINE(a0),a0
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3
            rts

;--------------------------------------------------------------
; tcline2 : white line at half resolution (pixel pairs)
;           outline updated like tcline
;--------------------------------------------------------------
tcline2:
            move.l  a6,-(sp)
            asr.w   #1,d0               ; x in pairs
            asr.w   #1,d2
            cmp.w   d0,d2
            bge.s   .lr
            exg     d0,d2
            exg     d1,d3
.lr:        sub.w   d0,d2
            move.w  #TCLINE,a1
            move.w  #2,a6
            sub.w   d1,d3
            bge.s   .dn
            neg.w   d3
            move.w  #-TCLINE,a1
            move.w  #-2,a6
.dn:        lea     curl,a5
            adda.w  d1,a5
            adda.w  d1,a5
            move.w  d1,d4
            lsl.w   #2,d4
            lea     ytc,a4
            move.l  (a4,d4.w),d4
            lea     (a0,d4.l),a4
            move.w  d0,d4
            lsl.w   #2,d4
            adda.w  d4,a4
            move.l  tclcol,d5
            move.w  d0,d4               ; x (pairs)
            move.w  d0,d1
            add.w   d1,d1               ; start of the segment (pixels)
            cmp.w   d3,d2
            blt.s   .ym
            move.w  d2,d7
            move.w  d2,d6
            asr.w   #1,d6
.xl:        move.l  d5,(a4)+
            sub.w   d3,d6
            bpl.s   .xc
            add.w   d2,d6
            adda.w  a1,a4
            move.w  d4,d0
            add.w   d0,d0
            addq.w  #1,d0               ; end of the segment (pixels)
            lspan   d1,d0
            adda.w  a6,a5
            move.w  d0,d1
            addq.w  #1,d1
.xc:        addq.w  #1,d4
            dbra    d7,.xl
            subq.w  #1,d4
            move.w  d4,d0
            add.w   d0,d0
            addq.w  #1,d0
            lspan   d1,d0
            move.l  (sp)+,a6
            rts
.ym:        move.w  d3,d7
            move.w  d3,d6
            asr.w   #1,d6
.yl:        move.l  d5,(a4)
            move.w  d4,d0
            add.w   d0,d0
            move.w  d0,d1
            addq.w  #1,d1
            lspan   d0,d1
            adda.w  a1,a4
            adda.w  a6,a5
            sub.w   d2,d6
            bpl.s   .yc
            add.w   d3,d6
            addq.l  #4,a4
            addq.w  #1,d4
.yc:        dbra    d7,.yl
            move.l  (sp)+,a6
            rts

;--------------------------------------------------------------
; tcband : draws the text of mline into image a0 (6 lines
;          of 640 bytes), white pixels on a black background
;--------------------------------------------------------------
tcband:
            movem.l d0-d7/a0-a4,-(sp)
            move.l  a0,a4
            move.w  #BANDTC/4-1,d0      ; black background
.clr:       clr.l   (a0)+
            dbra    d0,.clr
            lea     mline,a2
            moveq   #0,d7               ; column
.ch:        moveq   #0,d0
            move.b  (a2)+,d0
            cmp.w   #' ',d0
            beq     .nc
            move.w  d7,d1               ; x = 6 * column (in bytes x2)
            mulu    #12,d1
            lea     (a4,d1.w),a3
            moveq   #BANDH-1,d4
            cmp.w   #32,d0
            bhs.s   .font
            mulu    #BANDH,d0
            lea     blk6,a1
            adda.w  d0,a1
.bl:        moveq   #0,d2
            move.b  (a1)+,d2
            lsl.w   #8,d2
            bsr.s   .put
            dbra    d4,.bl
            bra.s   .nc
.font:      sub.w   fontfirst,d0
            add.w   d0,d0
            move.l  fontoff,a1
            move.w  (a1,d0.w),d3
            move.w  d3,d0
            lsr.w   #3,d0
            move.l  fontdat,a1
            adda.w  d0,a1
            and.w   #7,d3
.fl:        move.b  (a1),d2
            lsl.w   #8,d2
            move.b  1(a1),d2
            lsl.w   d3,d2
            bsr.s   .put
            adda.w  fontw,a1
            dbra    d4,.fl
.nc:        addq.w  #1,d7
            cmp.w   #COLS,d7
            blo     .ch
            movem.l (sp)+,d0-d7/a0-a4
            rts
.put:       moveq   #5,d5               ; 6 pixels : bits 15..10
            move.l  a3,a0
.pb:        add.w   d2,d2
            bcc.s   .p0
            move.w  #$ffff,(a0)
.p0:        addq.l  #2,a0
            dbra    d5,.pb
            lea     TCLINE(a3),a3
            rts

;==============================================================
; BLACK BACKGROUND : OPTIMISED TRUE COLOR DRAWING
;   - transparent objects : back faces of the 1st part written
;     without reading the screen (colour/2 = blend with black), then
;     clearing of the ring only (old outline minus the
;     new one), then the remaining faces blended and the edges
;   - solid objects : clearing of the old outline line by
;     line, then the faces
;==============================================================

; oldspans : a1 = previous outlines of screen a0 (L then R)
oldspans:
            lea     spans1,a1
            cmpa.l  buf1,a0
            beq.s   .o
            lea     spans2,a1
            cmpa.l  buf2,a0
            beq.s   .o
            lea     spans3,a1
.o:         rts

; spanreset : empty screen a0 -> empty previous outline
spanreset:
            movem.l d0/a1,-(sp)
            bsr     oldspans
            move.w  #TCH-1,d0
.l:         move.w  #32767,(a1)
            move.w  #-1,480(a1)
            addq.l  #2,a1
            dbra    d0,.l
            movem.l (sp)+,d0/a1
            rts

; spaninit : empty current outline
spaninit:
            lea     curl,a1
            move.w  #TCH-1,d0
.l:         move.w  #32767,(a1)
            move.w  #-1,480(a1)
            addq.l  #2,a1
            dbra    d0,.l
            rts

; spansave : current outline -> outline of screen a0
spansave:
            bsr     oldspans
            lea     curl,a2
            move.w  #2*TCH/2-1,d0       ; L and R : 480 words = 240 longs
.l:         move.l  (a2)+,(a1)+
            dbra    d0,.l
            rts

;--------------------------------------------------------------
; tcring : clears (black) in screen a0 the old outline
;          minus the current outline (margin of 2 pixels)
;--------------------------------------------------------------
tcring:
            movem.l d0-d7/a0-a4,-(sp)
            bsr     oldspans            ; a1 = old L, 480(a1) = old R
            lea     curl,a2
            lea     ytc,a4
            moveq   #0,d7               ; y
.row:       move.w  (a1),d0             ; old L
            move.w  480(a1),d1          ; old R
            cmp.w   d0,d1
            blt     .nx
            subq.w  #2,d0               ; margin (edges)
            bpl.s   .m0
            moveq   #0,d0
.m0:        addq.w  #2,d1
            cmp.w   #319,d1
            ble.s   .m1
            move.w  #319,d1
.m1:        move.w  (a2),d2             ; current L
            move.w  480(a2),d3          ; current R
            move.l  (a4),d6             ; start of line
            cmp.w   d2,d3
            bge.s   .two
            bsr.s   .clr                ; line now empty : everything
            bra.s   .nx
.two:       move.w  d1,d5               ; left : [aL, min(aR, L-1)]
            move.w  d2,d4
            subq.w  #1,d4
            cmp.w   d4,d1
            ble.s   .l1
            move.w  d4,d1
.l1:        bsr.s   .clr
            move.w  d5,d1               ; right : [max(aL, R+1), aR]
            move.w  d3,d4
            addq.w  #1,d4
            cmp.w   d4,d0
            bge.s   .r1
            move.w  d4,d0
.r1:        bsr.s   .clr
.nx:        addq.l  #2,a1
            addq.l  #2,a2
            addq.l  #4,a4
            addq.w  #1,d7
            cmp.w   #TCH,d7
            blo.s   .row
            movem.l (sp)+,d0-d7/a0-a4
            rts
            ; .clr : sets pixels d0..d1 (line d6) to 0 ; d0 kept
.clr:       move.w  d1,d4
            sub.w   d0,d4
            bmi.s   .c0
            lea     (a0,d6.l),a3
            adda.w  d0,a3
            adda.w  d0,a3
            moveq   #0,d2
.c:         move.w  d2,(a3)+
            dbra    d4,.c
            move.w  (a2),d2             ; (reload current L)
.c0:        rts

;--------------------------------------------------------------
; backface : is face a3 seen from the back ? (d0 = 1) ; d1 = 1 if 1st part
;--------------------------------------------------------------
backface:
            movem.l d2-d5/a1/a2,-(sp)
            lea     F_IDX(a3),a2
            lea     proj,a1
            moveq   #0,d0
            move.b  (a2),d0
            move.w  d0,d5               ; 1st vertex (part)
            lsl.w   #2,d0
            move.w  (a1,d0.w),d1
            move.w  2(a1,d0.w),d2
            moveq   #0,d0
            move.b  1(a2),d0
            lsl.w   #2,d0
            move.w  (a1,d0.w),d3
            sub.w   d1,d3
            move.w  2(a1,d0.w),d4
            sub.w   d2,d4
            moveq   #0,d0
            move.b  2(a2),d0
            lsl.w   #2,d0
            move.w  (a1,d0.w),d0
            sub.w   d1,d0
            moveq   #0,d1
            move.b  2(a2),d1
            lsl.w   #2,d1
            move.w  2(a1,d1.w),d1
            sub.w   d2,d1
            muls    d1,d3               ; (x1-x0)(y2-y0)
            muls    d0,d4               ; (y1-y0)(x2-x0)
            sub.l   d4,d3
            moveq   #0,d0
            tst.l   d3
            bmi.s   .f                  ; < 0 : front facing
            moveq   #1,d0
.f:         moveq   #0,d1
            cmp.w   p0end,d5
            bhs.s   .p
            moveq   #1,d1
.p:         movem.l (sp)+,d2-d5/a1/a2
            rts

;--------------------------------------------------------------
; tcdrawobj : True Color drawing (black background)
;--------------------------------------------------------------
tcdrawobj:
            tst.w   objmode
            bne     .solid

            ; --- transparent object ---
            move.w  nv,d0               ; end of the 1st part
            cmp.w   #2,np
            blo.s   .p1
            move.w  parts+PARTSZ+P_FIRST,d0
.p1:        move.w  d0,p0end
            moveq   #0,d6               ; pass 0 : back faces of the 1st part (written)
            bsr     .pass
            moveq   #1,d6               ; pass 1 : other back faces (blended)
            bsr     .pass
            moveq   #2,d6               ; pass 2 : front faces (blended)
            bsr     .pass
            bra     .edges

.pass:      move.w  nf,d7
            beq.s   .pe
            subq.w  #1,d7
            lea     objf,a3
.pf:        bsr     backface
            tst.w   d6
            bne.s   .p12
            tst.w   d0                  ; pass 0 : back AND 1st part
            beq.s   .pn
            tst.w   d1
            beq.s   .pn
            movem.l d6/d7,-(sp)
            bsr     tctrace
            cmp.w   #2,tcmode
            beq.s   .w2
            bsr     tcfillw
            bra.s   .wd
.w2:        bsr     tcfillw2
.wd:        movem.l (sp)+,d6/d7
            bra.s   .pn
.p12:       cmp.w   #1,d6
            bne.s   .p2
            tst.w   d0                  ; pass 1 : back, other part
            beq.s   .pn
            tst.w   d1
            bne.s   .pn
            bra.s   .blend
.p2:        tst.w   d0                  ; pass 2 : front facing
            bne.s   .pn
.blend:     movem.l d6/d7,-(sp)
            bsr     tctrace
            bsr     fillT
            movem.l (sp)+,d6/d7
.pn:        lea     FACESZ(a3),a3
            dbra    d7,.pf
.pe:        rts

.edges:     move.w  ne,d7
            beq.s   .ee
            subq.w  #1,d7
            lea     obje,a3
.e:         moveq   #0,d4
            move.b  (a3)+,d4
            lsl.w   #2,d4
            moveq   #0,d5
            move.b  (a3)+,d5
            lsl.w   #2,d5
            lea     proj,a2
            move.w  (a2,d4.w),d0
            move.w  2(a2,d4.w),d1
            move.w  (a2,d5.w),d2
            move.w  2(a2,d5.w),d3
            move.w  d7,-(sp)
            bsr     dline
            move.w  (sp)+,d7
            dbra    d7,.e
.ee:        rts

            ; --- solid object : clears the old outline, then the faces ---
.solid:     bra     drawsolid

;--------------------------------------------------------------
; tcfillw / tcfillw2 : back face written without reading (colour/2)
;                      and outline updated
;--------------------------------------------------------------
tcfillw:
            movem.l a0/a3,-(sp)
            move.w  F_COL(a3),d0
            add.w   d0,d0
            lea     tchalf,a1
            move.w  (a1,d0.w),d6
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi.s   .end
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a4
            move.l  (a4,d0.w),d0
            adda.l  d0,a0
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         spanupd
            move.w  d1,d7
            sub.w   d0,d7
            lea     (a0,d0.w),a3
            adda.w  d0,a3
.px:        move.w  d6,(a3)+
            dbra    d7,.px
            lea     TCLINE(a0),a0
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3
            rts

tcfillw2:
            movem.l a0/a3,-(sp)
            move.w  F_COL(a3),d0
            add.w   d0,d0
            lea     tchalf,a1
            move.w  (a1,d0.w),d6
            swap    d6
            move.w  (a1,d0.w),d6
            move.w  fymin,d0
            move.w  fymax,d4
            sub.w   d0,d4
            bmi.s   .end
            move.w  d0,d1
            add.w   d1,d1
            lea     xa,a1
            adda.w  d1,a1
            lea     xb,a2
            adda.w  d1,a2
            lsl.w   #2,d0
            lea     ytc,a4
            move.l  (a4,d0.w),d0
            adda.l  d0,a0
.fy:        move.w  (a1)+,d0
            move.w  (a2)+,d1
            cmp.w   d0,d1
            bge.s   .o
            exg     d0,d1
.o:         and.w   #$fffe,d0
            spanupd
            move.w  d1,d7
            sub.w   d0,d7
            lsr.w   #1,d7
            lea     (a0,d0.w),a3
            adda.w  d0,a3
.px:        move.l  d6,(a3)+
            dbra    d7,.px
            lea     TCLINE(a0),a0
            dbra    d4,.fy
.end:       movem.l (sp)+,a0/a3
            rts

;==============================================================
; 3D BY THE DSP (3DREAMS.P56) NEXT TO SIMPLET'S REPLAY
;
;   The DSP program 3DREAMS.P56 is sent to the DSP together with
;   Simplet's replay program (same Dsp_ExecProg, his blocks first) :
;   his files are not modified, only his idle loop is redirected.
;   His replay works under interrupt on the DSP ; 3DREAMS runs in the
;   free time and computes the 3D :
;     vertices : rotation, projection, lighting (fake Phong u,v),
;     faces : the 030 sends the vertices, the DSP traces the edges,
;     computes each line and sends back the RGB565 pixels.
;
;   Golden rule : the 030 only talks to 3DREAMS when the music does
;   not talk to the DSP (MGTK_Replay_In_Service = 0), interrupts
;   masked, and each exchange ends with an answer from the DSP. So the
;   host port is always empty when the music's Timer A comes.
;==============================================================

D3D_RAMPX   equ     $1000               ; Gouraud ramps (4 x 224) then cel
D3D_RECIP   equ     $1700               ; 1/w table
D3D_PRCP    equ     $1900               ; 2^23/d table (projection)
D3D_VTX     equ     $2200               ; vertices x,y,z,nx,ny,nz
D3D_MFROM   equ     $2800               ; morphing : starting cloud (x,y,z)
D3D_MTO     equ     $2B00               ;            target cloud
D3D_BATCH   equ     40                  ; lines per exchange (= BATCH of the DSP)
D3D_TMO     equ     200000              ; max wait for the DSP (loops)

;--------------------------------------------------------------
; d3dinit : replaces MGTK_Init_DSP (same job) : Simplet's DSP program
;   (AMIGADSP.P56, unchanged) followed by 3DREAMS.P56 are sent
;   together by Dsp_ExecProg, then the same connection test.
;   (The MGTK_P56_Loader loader is not used : it goes through a host
;   command that Hatari emulates badly -> hang at start-up.)
;   d0 = 0 : ok ; -1 : no DSP
;--------------------------------------------------------------
d3dinit:
            movem.l d1-d7/a0-a6,-(sp)
            lea     MGTK_DSP_Replay_Code,a0     ; Simplet first
            lea     d3dcomb,a1
            move.l  #MGTK_DSP_Replay_Size*3,d0
            subq.l  #1,d0
.c1:        move.b  (a0)+,(a1)+
            subq.l  #1,d0
            bpl.s   .c1
            lea     d3dcode,a0                  ; then 3DREAMS
            move.l  #d3dcend-d3dcode,d0
            subq.l  #1,d0
.c2:        move.b  (a0)+,(a1)+
            subq.l  #1,d0
            bpl.s   .c2
            move.w  #113,-(sp)                  ; Dsp_RequestUniqueAbility
            trap    #14
            addq.l  #2,sp
            move.w  d0,-(sp)
            move.l  #MGTK_DSP_Replay_Size+(d3dcend-d3dcode)/3,-(sp)
            pea     d3dcomb
            move.w  #109,-(sp)                  ; Dsp_ExecProg
            trap    #14
            lea     12(sp),sp
            move.l  #87654321,$ffffa204.w       ; connection test (Simplet)
            move.l  #100000,d1
.w:         btst    #0,$ffffa202.w
            bne.s   .g
            subq.l  #1,d1
            bne.s   .w
            moveq   #-1,d0
            bra.s   .out
.g:         move.l  $ffffa204.w,d0
            moveq   #0,d0
.out:       movem.l (sp)+,d1-d7/a0-a6
            rts

;--------------------------------------------------------------
; d3dload : does 3DREAMS (loaded by d3dinit) answer ? tests it,
;           sends the reciprocal tables -> dsp3d = 1 if all is well
;--------------------------------------------------------------
d3dload:
            movem.l d0-d7/a0-a6,-(sp)
            clr.w   dsp3d
            clr.w   d3don
            tst.w   dspok
            beq     .out
            ; --- PING ---
            bsr     d3dbegin
            move.l  #$040000,d0
            bsr     d3dput
            bmi     .ko
            bsr     d3dget
            bmi     .ko
            cmp.l   #$5a5a5a,d0
            bne     .ko
            bsr     d3dend
            ; --- reciprocal table : $7fffff / w ---
            lea     d3dbuf,a0
            clr.l   (a0)+
            moveq   #1,d1
.rc:        move.l  #$7fffff,d0
            divu.l  d1,d0
            move.l  d0,(a0)+
            addq.w  #1,d1
            cmp.w   #321,d1
            bls.s   .rc
            lea     d3dbuf,a0
            move.l  #D3D_RECIP,d0
            move.w  #321,d1
            bsr     d3duplong
            bmi.s   .out
            ; --- projection table : 2^23 / d rounded up (d = 0..1023) ---
            lea     d3dvbuf,a0
            move.l  #$7fffff,(a0)+
            moveq   #1,d1
.pr:        move.l  #$800000,d0
            add.l   d1,d0
            subq.l  #1,d0
            divu.l  d1,d0
            cmp.l   #$7fffff,d0
            bls.s   .pr1
            move.l  #$7fffff,d0
.pr1:       move.l  d0,(a0)+
            addq.w  #1,d1
            cmp.w   #1024,d1
            blo.s   .pr
            lea     d3dvbuf,a0
            move.l  #D3D_PRCP,d0
            move.w  #1024,d1
            bsr     d3duplong
            bmi.s   .out
            move.w  #1,dsp3d
            move.w  #1,d3don            ; the DSP computes the 3D
            bra.s   .out
.ko:        bsr     d3dend
.out:       movem.l (sp)+,d0-d7/a0-a6
            rts

;--------------------------------------------------------------
; d3dbegin / d3dend : start / end of an exchange with 3DREAMS
;   waits until the music has finished talking to the DSP, then
;   masks the interrupts (music Timer A included)
;--------------------------------------------------------------
d3dbegin:
            ; Only the music's Timer A is held back (MFP mask register),
            ; not all interrupts : with SR = $2700 the VBL interrupt was
            ; delayed by the long exchanges, the new screen address was
            ; then set too late and an older screen flashed on display.
            ; The mask is set with the interrupts held for a few
            ; instructions : a Timer A request already on its way to the
            ; 68030 could otherwise still be taken just after the test of
            ; MGTK_Replay_In_Service, and the music would then talk to the
            ; DSP in the middle of our exchange (random freeze, stuck note).
            move.w  sr,-(sp)
.w:         or.w    #$0700,sr
            move.b  $fffffa13.w,d3dimra ; IMRA as it was (Timer A on / off)
            bclr    #5,$fffffa13.w      ; Timer A masked (it stays pending)
            tst.b   $fffffa13.w         ; (MFP read : its request line has settled)
            tst.b   MGTK_Replay_In_Service
            beq.s   .ok
            bsr.s   d3dend              ; the music is talking : let it finish
            move.w  (sp),sr
            bra.s   .w
.ok:        move.w  (sp)+,sr
            rts

d3dend:
            btst    #5,d3dimra          ; Timer A back as it was
            beq.s   .x
            bset    #5,$fffffa13.w
.x:         rts

; d3dput : sends d0 (24 bits) ; N = 1 if the DSP does not answer
d3dput:
            move.l  d1,-(sp)
            move.l  #D3D_TMO,d1
.w:         btst    #1,$ffffa202.w
            bne.s   .ok
            subq.l  #1,d1
            bne.s   .w
            bra.s   d3dfail
.ok:        move.l  d0,$ffffa204.w
            move.l  (sp)+,d1
            tst.w   d3dzero             ; N = 0
            rts

; d3dget : reads a word from the DSP into d0 ; N = 1 if nothing comes
d3dget:
            move.l  d1,-(sp)
            move.l  #D3D_TMO,d1
.w:         btst    #0,$ffffa202.w
            bne.s   .ok
            subq.l  #1,d1
            bne.s   .w
            bra.s   d3dfail
.ok:        move.l  $ffffa204.w,d0
            and.l   #$ffffff,d0
            move.l  (sp)+,d1
            tst.w   d3dzero             ; N = 0
            rts

d3dfail:    move.l  (sp)+,d1            ; the DSP no longer answers : 030 rendering
            clr.w   dsp3d
            clr.w   d3don
            moveq   #-1,d0
            rts

; d3dgetm : reads until a word whose bits 23-22 = d2 (resync)
d3dgetm:
.l:         bsr     d3dget
            bmi.s   .out
            move.l  d0,d1
            and.l   #$c00000,d1
            cmp.l   d2,d1
            bne.s   .l
            tst.w   d3dzero
.out:       rts

;--------------------------------------------------------------
; d3duplong : a0 = longs, d0 = X address, d1 = count
; d3dupword : a0 = words (RGB565), d0 = X address, d1 = count
;   sent in packets of 224 ; N = 1 on error
;--------------------------------------------------------------
d3duplong:
            moveq   #1,d3
            bra.s   d3dup
d3dupword:
            moveq   #0,d3
d3dup:
            movem.l d0-d6/a0,-(sp)
            move.l  d0,d4               ; address
            move.w  d1,d5               ; remaining
.pk:        move.w  d5,d6
            beq.s   .ok
            cmp.w   #224,d6
            bls.s   .n
            move.w  #224,d6
.n:         bsr     d3dbegin
            move.l  #$010000,d0
            bsr     d3dput
            bmi.s   .ko
            move.l  d4,d0
            bsr     d3dput
            bmi.s   .ko
            moveq   #0,d0
            move.w  d6,d0
            bsr     d3dput
            bmi.s   .ko
            move.w  d6,d1
            subq.w  #1,d1
.wd:        tst.w   d3
            beq.s   .w16
            move.l  (a0)+,d0
            bra.s   .put
.w16:       moveq   #0,d0
            move.w  (a0)+,d0
.put:       bsr     d3dput
            bmi.s   .ko
            dbra    d1,.wd
            move.l  #$400000,d2         ; acknowledge
            bsr     d3dgetm
            bmi.s   .ko
            bsr     d3dend
            add.w   d6,d4
            sub.w   d6,d5
            bra.s   .pk
.ko:        bsr     d3dend
            movem.l (sp)+,d0-d6/a0
            moveq   #-1,d0
            rts
.ok:        movem.l (sp)+,d0-d6/a0
            tst.w   d3dzero
            rts

;--------------------------------------------------------------
; d3dramps : sends the Gouraud and cel ramps to the DSP (after mkramp)
;--------------------------------------------------------------
d3dramps:
            tst.w   dsp3d
            beq.s   .out
            movem.l d0-d1/a0,-(sp)
            lea     rampx,a0
            move.l  #D3D_RAMPX,d0
            move.w  #224*MAXMAT,d1
            bsr     d3dupword
            bmi.s   .e
            lea     rampcx,a0
            move.l  #D3D_RAMPX+224*MAXMAT,d0
            move.w  #224*MAXMAT,d1
            bsr     d3dupword
.e:         movem.l (sp)+,d0-d1/a0
.out:       rts

;--------------------------------------------------------------
; dspface : fills face a3 (Gouraud / cel) with the DSP
;   a0 = screen. d0 = 0 : done ; d0 = -1 : to be done by the 030
;   (vertex off screen, DSP missing)
;   exchange 1 : vertices -> face header + 1st packet of lines
;   next exchanges : LINES k (k <= D3D_BATCH)
;   line : $800000 | x << 9 | (n - 1), then n pixels read without
;   waiting (the DSP is faster than the 030) : RGB565 words ; end of packet
;   $400000. A word without the right marker is skipped (resync).
;--------------------------------------------------------------
D3DW        MACRO                       ; sends \1 to the DSP
.w\@:       btst    #1,$ffffa202.w
            beq.s   .w\@
            move.l  \1,(a6)
            ENDM
D3DWW       MACRO                       ; sends the word \1 (a5 = $a206) :
.w\@:       btst    #1,$ffffa202.w      ; 2 host-port accesses instead of 4,
            beq.s   .w\@                ; the high byte (TXH) keeps the value
            move.w  \1,(a5)             ; of the previous word (0 here)
            ENDM

dspface:
            tst.w   d3don
            beq     .no
            movem.l d1-d7/a0-a6,-(sp)
            ; --- vertices on screen ? -> d3dbuf (x, y, i) ---
            lea     F_IDX(a3),a1
            lea     proj,a2
            lea     vint,a4
            lea     d3dbuf,a6
            move.w  F_N(a3),d7
            move.w  d7,d6               ; n
            subq.w  #1,d7
            move.w  scrh,d5
.v:         moveq   #0,d4
            move.b  (a1)+,d4
            move.w  (a4,d4.w*2),d3      ; intensity
            move.w  (a2,d4.w*4),d1      ; x
            move.w  2(a2,d4.w*4),d2     ; y
            cmp.w   #TCW,d1
            bhs     .cpu                ; (unsigned : x < 0 too)
            cmp.w   d5,d2
            bhs     .cpu
            movem.w d1-d3,(a6)          ; (all three 0..65535 : sent as words)
            addq.l  #6,a6
            dbra    d7,.v
            ; --- material ramp : X = RAMPX + mat*224 + 48 (+ cel) ---
            move.w  F_COL(a3),d4
            mulu    #224,d4
            add.l   #D3D_RAMPX+48,d4
            tst.w   cel
            beq.s   .nc
            add.l   #224*MAXMAT,d4
.nc:        lea     $ffffa204.w,a6      ; host port (24 bits)
            lea     2(a6),a5            ; low word ($a206)
            lea     d3dbuf,a1
            ; --- FACE ---
            bsr     d3dbegin
            moveq   #0,d0
            move.w  d6,d0
            or.l    #$020000,d0
            D3DW    d0
            D3DW    d4                  ; (TXH = 0 from here on)
            subq.w  #1,d6
.sv:        D3DWW   (a1)+               ; x, y, i of a vertex
            D3DWW   (a1)+
            D3DWW   (a1)+
            dbra    d6,.sv
            move.l  #D3D_TMO,d2         ; face header (DSP alive ?)
.fh:        subq.l  #1,d2
            beq     .err
            btst    #0,$ffffa202.w
            beq.s   .fh
            move.l  (a6),d0
            btst    #22,d0              ; $C00000 | ymin << 9 | nlines
            beq.s   .fh
            move.w  d0,d6
            and.w   #$1ff,d6            ; number of lines
            beq     .end1               ; (nothing else follows)
            lsr.l   #8,d0
            lsr.l   #1,d0
            and.w   #$1ff,d0            ; ymin
            lea     ytc,a1
            adda.l  (a1,d0.w*4),a0      ; a0 = start of the 1st line
            bra.s   .lines
            ; --- next packets ---
.pk:        bsr     d3dbegin
            moveq   #0,d0
            move.w  d6,d0
            cmp.w   #D3D_BATCH,d0
            bls.s   .k
            moveq   #D3D_BATCH,d0
.k:         or.l    #$030000,d0
            D3DW    d0
.lines:     move.w  d6,d5               ; lines of this packet
            cmp.w   #D3D_BATCH,d5
            bls.s   .k2
            moveq   #D3D_BATCH,d5
.k2:        sub.w   d5,d6
            subq.w  #1,d5
            move.l  #D3D_TMO,d7
.hw:        btst    #0,$ffffa202.w      ; line header
            bne.s   .hr
            subq.l  #1,d7
            bne.s   .hw
            bra     .err
.hr:        move.l  (a6),d0
            btst    #23,d0
            beq.s   .hw
            move.l  d0,d1
            lsr.l   #8,d1
            and.w   #$3fe,d1            ; 2 x
            lea     (a0,d1.w),a2
            and.w   #$1ff,d0            ; n - 1
            move.w  (a5),(a2)+          ; 1st pixel (RGB565)
            lsr.w   #1,d0               ; remaining pairs, C = 1 more
            bcc.s   .p2
            move.w  (a5),(a2)+
.p2:        subq.w  #1,d0
            bmi.s   .nl
.px:        move.w  (a5),(a2)+          ; (measured on the real Falcon :
            move.w  (a5),(a2)+          ;  faster than 1 byte + a ramp)
            dbra    d0,.px
.nl:        lea     TCLINE(a0),a0
            move.l  #D3D_TMO,d7
            dbra    d5,.hw
.tw:        btst    #0,$ffffa202.w      ; end of the packet
            bne.s   .tr
            subq.l  #1,d7
            bne.s   .tw
            bra     .err
.tr:        move.l  (a6),d0
            and.l   #$c00000,d0
            cmp.l   #$400000,d0
            bne.s   .tw
            bsr     d3dend
            tst.w   d6
            bne     .pk
            bra.s   .done
.end1:      bsr     d3dend
.done:      movem.l (sp)+,d1-d7/a0-a6
            moveq   #0,d0
            rts
.err:       bsr     d3dend
            clr.w   dsp3d               ; the DSP no longer answers : 030
            clr.w   d3don
.cpu:       movem.l (sp)+,d1-d7/a0-a6
.no:        moveq   #-1,d0
            rts

;--------------------------------------------------------------
; dspfaceuv : face a3 in Phong / chrome (True Color) by the DSP, as
;   dspface : the DSP traces the edges (x, u, v) and computes the lines,
;   it sends for each pixel the index v.int << 8 | u.int in the map
;   (curtex) : the 030 only reads the map. Also the textures (Mapping :
;   u,v of the face). d0 = 0 : done ; -1 : 030.
;--------------------------------------------------------------
dspfaceuv:
            tst.w   d3don
            beq     .no
            movem.l d1-d7/a0-a6,-(sp)
            ; --- vertices on screen ? -> d3dbuf (x, y, u, v) ---
            move.l  a3,d0               ; (texture : fuv + (a3 - objf))
            sub.l   #objf,d0
            lea     fuv,a5
            adda.l  d0,a5
            lea     F_IDX(a3),a1
            lea     proj,a2
            lea     vint,a4
            lea     d3dbuf,a6
            move.w  F_N(a3),d7
            move.w  d7,d6               ; n
            subq.w  #1,d7
            move.w  scrh,d5
.v:         moveq   #0,d4
            move.b  (a1)+,d4
            cmp.w   #2,uvmode           ; texture : u,v of the face (W)
            bne.s   .vp
            moveq   #0,d3
            move.b  (a5)+,d3
            lsl.w   #8,d3               ; u (8.8)
            moveq   #0,d0
            move.b  (a5)+,d0
            lsl.w   #8,d0               ; v (8.8)
            bra.s   .vs
.vp:        move.w  2*MAXV(a4,d4.w*2),d3 ; Phong / chrome : u (8.8)
            move.w  4*MAXV(a4,d4.w*2),d0 ; v (8.8)
.vs:
            move.w  (a2,d4.w*4),d1      ; x
            move.w  2(a2,d4.w*4),d2     ; y
            cmp.w   #TCW,d1
            bhs     .cpu                ; (unsigned : x < 0 too)
            cmp.w   d5,d2
            bhs     .cpu
            move.w  d1,(a6)+            ; (all four 0..65535 : sent as words)
            move.w  d2,(a6)+
            move.w  d3,(a6)+
            move.w  d0,(a6)+
            dbra    d7,.v
            ; --- the map (Phong or chrome) : the DSP sends indices ---
            move.l  curtex,a4
            moveq   #0,d3               ; (index : high word 0)
            lea     $ffffa204.w,a6      ; host port (24 bits)
            lea     2(a6),a5            ; low word ($a206)
            lea     d3dbuf,a1
            ; --- FACE ---
            bsr     d3dbegin
            moveq   #0,d0
            move.w  d6,d0
            or.l    #$070000,d0         ; FACEUV
            D3DW    d0
            move.w  (a1)+,d0            ; x of the 1st vertex : 24 bits
            ext.l   d0                  ; (TXH = 0 from here on)
            D3DW    d0
            D3DWW   (a1)+               ; y, u, v
            D3DWW   (a1)+
            D3DWW   (a1)+
            subq.w  #2,d6
.sv:        D3DWW   (a1)+               ; x, y, u, v of the others
            D3DWW   (a1)+
            D3DWW   (a1)+
            D3DWW   (a1)+
            dbra    d6,.sv
            move.l  #D3D_TMO,d2         ; face header (DSP alive ?)
.fh:        subq.l  #1,d2
            beq     .err
            btst    #0,$ffffa202.w
            beq.s   .fh
            move.l  (a6),d0
            btst    #22,d0              ; $C00000 | ymin << 9 | nlines
            beq.s   .fh
            move.w  d0,d6
            and.w   #$1ff,d6            ; number of lines
            beq     .end1               ; (nothing else follows)
            lsr.l   #8,d0
            lsr.l   #1,d0
            and.w   #$1ff,d0            ; ymin
            lea     ytc,a1
            adda.l  (a1,d0.w*4),a0      ; a0 = start of the 1st line
            bra.s   .lines
            ; --- next packets ---
.pk:        bsr     d3dbegin
            moveq   #0,d0
            move.w  d6,d0
            cmp.w   #D3D_BATCH,d0
            bls.s   .k
            moveq   #D3D_BATCH,d0
.k:         or.l    #$030000,d0
            D3DW    d0
.lines:     move.w  d6,d5               ; lines of this packet
            cmp.w   #D3D_BATCH,d5
            bls.s   .k2
            moveq   #D3D_BATCH,d5
.k2:        sub.w   d5,d6
            subq.w  #1,d5
            move.l  #D3D_TMO,d7
.hw:        btst    #0,$ffffa202.w      ; line header
            bne.s   .hr
            subq.l  #1,d7
            bne.s   .hw
            bra     .err
.hr:        move.l  (a6),d0
            btst    #23,d0
            beq.s   .hw
            move.l  d0,d1
            lsr.l   #8,d1
            and.w   #$3fe,d1            ; 2 x
            lea     (a0,d1.w),a2
            and.w   #$1ff,d0            ; n - 1
            move.w  (a5),d3             ; 1st pixel : index in the map
            move.w  (a4,d3.l*2),(a2)+
            lsr.w   #1,d0               ; remaining pairs, C = 1 more
            bcc.s   .p2
            move.w  (a5),d3
            move.w  (a4,d3.l*2),(a2)+
.p2:        subq.w  #1,d0
            bmi.s   .nl
.px:        move.w  (a5),d3
            move.w  (a4,d3.l*2),(a2)+
            move.w  (a5),d3
            move.w  (a4,d3.l*2),(a2)+
            dbra    d0,.px
.nl:        lea     TCLINE(a0),a0
            move.l  #D3D_TMO,d7
            dbra    d5,.hw
.tw:        btst    #0,$ffffa202.w      ; end of the packet
            bne.s   .tr
            subq.l  #1,d7
            bne.s   .tw
            bra     .err
.tr:        move.l  (a6),d0
            and.l   #$c00000,d0
            cmp.l   #$400000,d0
            bne.s   .tw
            bsr     d3dend
            tst.w   d6
            bne     .pk
            bra.s   .done
.end1:      bsr     d3dend
.done:      movem.l (sp)+,d1-d7/a0-a6
            moveq   #0,d0
            rts
.err:       bsr     d3dend
            clr.w   dsp3d               ; the DSP no longer answers : 030
            clr.w   d3don
.cpu:       movem.l (sp)+,d1-d7/a0-a6
.no:        moveq   #-1,d0
            rts

;--------------------------------------------------------------
; d3dverts : object vertices (x,y,z) + normals -> DSP memory
;            (after each object loading)
;--------------------------------------------------------------
d3dverts:
            tst.w   dsp3d
            beq.s   .out
            movem.l d0-d2/a0-a2,-(sp)
            move.w  nv,d2
            beq.s   .x
            lea     objv,a0
            lea     vnorm,a1
            lea     d3dvbuf,a2
            subq.w  #1,d2
.v:         moveq   #2,d1
.c:         move.w  (a0)+,d0
            ext.l   d0
            move.l  d0,(a2)+
            dbra    d1,.c
            moveq   #2,d1
.n:         move.w  (a1)+,d0
            ext.l   d0
            move.l  d0,(a2)+
            dbra    d1,.n
            dbra    d2,.v
            lea     d3dvbuf,a0
            move.l  #D3D_VTX,d0
            move.w  nv,d1
            mulu    #6,d1
            bsr     d3duplong
.x:         movem.l (sp)+,d0-d2/a0-a2
.out:       rts

;--------------------------------------------------------------
; d3dxform : rotation + projection + lighting of a part by the DSP
;   a5 = part, a1 = its vertices (objv), a3 = rv, a2 = proj,
;   a0 = vint, a4 = vnorm  (pointers advanced like the 030 loop)
;   matrix (mxx..), lo, off, path already computed. d0 = -1 : failure
;--------------------------------------------------------------
D3DR        MACRO                       ; reads a word from the DSP -> \1
.r\@:       btst    #0,$ffffa202.w
            beq.s   .r\@
            move.w  (a5),\1
            ENDM
D3DQ        MACRO                       ; word x 2^14 -> x 2^23, clamped to
            move.w  \1,d0              ; -1.0 .. +1.0 : the matrix can hold
            ext.l   d0                  ; -16385 or 16385 (rounding), which
            asl.l   #8,d0               ; overflowed 24 bits and flipped the
            add.l   d0,d0               ; sign (an old pose flashed on screen)
            cmp.l   #$7fffff,d0
            ble.s   .a\@
            move.l  #$7fffff,d0
.a\@:       cmp.l   #-$800000,d0
            bge.s   .q\@
            move.l  #-$800000,d0
.q\@:       D3DW    d0
            ENDM

d3dxform:
            movem.l d1-d7/a6,-(sp)
            move.l  a5,-(sp)
            move.w  P_COUNT(a5),d7      ; number of vertices
            move.l  a1,d6
            sub.l   #objv,d6
            divu    #6,d6               ; 1st vertex
            lea     $ffffa204.w,a6
            lea     2(a6),a5            ; low word
            bsr     d3dbegin
            moveq   #0,d0
            move.w  d7,d0
            or.l    #$050000,d0
            D3DW    d0
            moveq   #0,d0
            move.w  d6,d0
            D3DW    d0
            moveq   #0,d1               ; flags
            tst.w   gour
            beq.s   .f
            moveq   #1,d1
            tst.w   phong
            beq.s   .f
            moveq   #3,d1
.f:         D3DW    d1
            D3DQ    mxx
            D3DQ    mxy
            D3DQ    mxz
            D3DQ    myx
            D3DQ    myy
            D3DQ    myz
            D3DQ    mzx
            D3DQ    mzy
            D3DQ    mzz
            D3DQ    lox
            D3DQ    loy
            D3DQ    loz
            lea     offx,a6             ; offx offy offz pathx pathy ymax
            move.w  (a6)+,d0
            ext.l   d0
            lea     $ffffa204.w,a6
            D3DW    d0
            move.w  offy,d0
            ext.l   d0
            D3DW    d0
            move.w  offz,d0
            ext.l   d0
            D3DW    d0
            move.w  pathx,d0
            ext.l   d0
            D3DW    d0
            move.w  pathy,d0
            ext.l   d0
            D3DW    d0
            move.w  scrhm1,d0
            ext.l   d0
            D3DW    d0
            ; --- answers : rx ry rz X Y [i] [u v] per vertex ---
            subq.w  #1,d7
            bmi.s   .te
.v:         D3DR    (a3)+
            D3DR    (a3)+
            D3DR    (a3)+
            D3DR    (a2)+
            D3DR    (a2)+
            tst.w   d1
            beq.s   .nx
            D3DR    (a0)
            cmp.w   #3,d1
            bne.s   .ni
            D3DR    2*MAXV(a0)
            D3DR    4*MAXV(a0)
.ni:        addq.l  #2,a0
            addq.l  #6,a4
.nx:        addq.l  #6,a1
            dbra    d7,.v
.te:        move.l  #D3D_TMO,d7
.t:         btst    #0,$ffffa202.w      ; end
            bne.s   .tr
            subq.l  #1,d7
            bne.s   .t
            clr.w   dsp3d               ; no end : the DSP no longer answers
            clr.w   d3don
            bra.s   .tx
.tr:        move.l  (a6),d0
            and.l   #$c00000,d0
            cmp.l   #$400000,d0
            bne.s   .t
.tx:        bsr     d3dend
            move.l  (sp)+,a5
            movem.l (sp)+,d1-d7/a6
            moveq   #0,d0
            rts

;--------------------------------------------------------------
; d3dmorphup : the two clouds of a new morphing (mfrom, mcloud) -> DSP
;--------------------------------------------------------------
d3dmorphup:
            tst.w   dsp3d
            beq.s   .out
            movem.l d0-d2/a0-a1,-(sp)
            lea     mfrom,a1
            move.l  #D3D_MFROM,d2
            bsr.s   .one
            lea     mcloud,a1
            move.l  #D3D_MTO,d2
            bsr.s   .one
            movem.l (sp)+,d0-d2/a0-a1
.out:       rts
.one:       lea     d3dvbuf,a0          ; words -> signed longs
            move.w  #3*MPTS-1,d1
.c:         move.w  (a1)+,d0
            ext.l   d0
            move.l  d0,(a0)+
            dbra    d1,.c
            lea     d3dvbuf,a0
            move.l  d2,d0
            move.w  #3*MPTS,d1
            bra     d3duplong

;--------------------------------------------------------------
; d3dmorph : the cloud of the morphing computed by the DSP (instead
;   of the 030 : 256 points interpolated, rotated, projected) ->
;   proj (X,Y) and the z of rv. Matrix (mkmat), ms, mf already
;   computed. d0 = -1 : failure (then the 030 does it)
;--------------------------------------------------------------
d3dmorph:
            movem.l d1-d7/a2-a6,-(sp)
            lea     $ffffa204.w,a6
            lea     2(a6),a5            ; low word
            bsr     d3dbegin
            move.l  #$060000,d0         ; MORPH
            D3DW    d0
            moveq   #0,d0               ; s = ms / 256 (x 2^23)
            move.w  ms,d0
            moveq   #15,d1
            lsl.l   d1,d0
            cmp.l   #$7fffff,d0
            ble.s   .s
            move.l  #$7fffff,d0
.s:         D3DW    d0
            moveq   #0,d0               ; f / 2 = mf / 512 (x 2^23)
            move.w  mf,d0
            moveq   #14,d1
            lsl.l   d1,d0
            D3DW    d0
            D3DQ    mxx
            D3DQ    mxy
            D3DQ    mxz
            D3DQ    myx
            D3DQ    myy
            D3DQ    myz
            D3DQ    mzx
            D3DQ    mzy
            D3DQ    mzz
            move.w  pathx,d0
            ext.l   d0
            D3DW    d0
            move.w  pathy,d0
            ext.l   d0
            D3DW    d0
            move.w  scrhm1,d0           ; y : 0 .. last line - 1 (2x2)
            subq.w  #1,d0
            ext.l   d0
            D3DW    d0
            ; --- the DSP computes the 256 points, then sends them in a
            ;     row : wait for the 1st word only ---
            move.l  #D3D_TMO,d7
.w0:        btst    #0,$ffffa202.w
            bne.s   .go
            subq.l  #1,d7
            bne.s   .w0
            bra.s   .err
.go:        lea     proj,a2
            lea     rv+4,a3
            move.w  #MPTS-1,d7
.p:         move.w  (a5),d0             ; (X/2) << 8 | Y
            move.w  (a5),(a3)           ; z
            addq.l  #6,a3
            move.w  d0,d1
            lsr.w   #7,d1
            and.w   #$1fe,d1
            move.w  d1,(a2)+            ; X (even : 2x2 points)
            and.w   #$ff,d0
            move.w  d0,(a2)+            ; Y
            dbra    d7,.p
            move.l  #D3D_TMO,d7
.t:         btst    #0,$ffffa202.w      ; end
            bne.s   .tr
            subq.l  #1,d7
            bne.s   .t
            bra.s   .err
.tr:        move.l  (a6),d0
            and.l   #$c00000,d0
            cmp.l   #$400000,d0
            bne.s   .t
            bsr     d3dend
            movem.l (sp)+,d1-d7/a2-a6
            moveq   #0,d0
            rts
.err:       bsr     d3dend
            clr.w   dsp3d               ; the DSP no longer answers : 030
            clr.w   d3don
            movem.l (sp)+,d1-d7/a2-a6
            moveq   #-1,d0
            rts

            section data
            even
d3dcode:    incbin  '3DREAMS.P56'        ; (3 bytes per DSP word)
d3dcend:
            even
d3dzero:    dc.w    0

            section bss
            even
dsp3d:      ds.w    1                   ; 3DREAMS loaded and answering
d3don:      ds.w    1                   ; 3D computed by the DSP (0 : it does not answer)
d3dsr:      ds.w    1
d3dimra:    ds.b    1
            even
d3dbuf:     ds.l    330                 ; vertices / table sent
d3dcomb:    ds.b    3*1024              ; Simplet + 3DREAMS for Dsp_ExecProg
d3dvbuf:    ds.l    6*MAXV              ; vertices / table sent

            section text
;==============================================================
; WELCOME PAGE (before the demo, in the style of REP_PWER) : TOS text
;   centred on the desktop screen (40 or 80 columns),
;   SPACE = demo, ESC = back to the desktop
;==============================================================

; infopage : d0 = 0 : start the demo ; d0 = -1 : quit
infopage:
            movem.l d1-d7/a0-a6,-(sp)
            dc.w    $a000               ; Line-A : size of the text screen
            move.w  -44(a0),d6          ; last column
            addq.w  #1,d6               ; columns
            move.w  -42(a0),d5          ; last line
            addq.w  #1,d5
            sub.w   #INFOH,d5           ; vertical margin
            asr.w   #1,d5
            bpl.s   .m
            moveq   #0,d5
.m:         bsr     ipalset             ; black background, white text
            dc.w    $a00a               ; hide the mouse
            pea     i_cls(pc)
            move.w  #9,-(sp)            ; Cconws
            trap    #1
            addq.l  #6,sp
            lea     infotab,a3
.l:         move.b  (a3)+,d7            ; line (-1 = end)
            bmi.s   .wait
            move.l  a3,a4               ; text length
.n:         tst.b   (a4)+
            bne.s   .n
            move.l  a4,d0
            sub.l   a3,d0
            subq.w  #1,d0
            move.w  d6,d1               ; column = (width - length) / 2
            sub.w   d0,d1
            asr.w   #1,d1
            bpl.s   .c
            moveq   #0,d1
.c:         lea     i_pos,a0            ; ESC Y line column
            add.b   d5,d7
            add.b   #32,d7
            move.b  d7,2(a0)
            add.b   #32,d1
            move.b  d1,3(a0)
            pea     (a0)
            move.w  #9,-(sp)
            trap    #1
            addq.l  #6,sp
            pea     (a3)
            move.w  #9,-(sp)
            trap    #1
            addq.l  #6,sp
            move.l  a4,a3
            bra.s   .l
.wait:      move.w  #7,-(sp)            ; Crawcin
            trap    #1
            addq.l  #2,sp
            cmp.b   #' ',d0
            beq.s   .go
            cmp.b   #27,d0
            bne.s   .wait
            bsr     ipalrst             ; desktop colours back
            pea     i_end(pc)           ; ESC : back to the desktop
            move.w  #9,-(sp)
            trap    #1
            addq.l  #6,sp
            dc.w    $a009
            moveq   #-1,d0
            bra.s   .out
.go:        bsr     ipalrst             ; desktop colours back
            pea     i_end(pc)
            move.w  #9,-(sp)
            trap    #1
            addq.l  #6,sp
            moveq   #0,d0
.out:       movem.l (sp)+,d1-d7/a0-a6
            rts

;--------------------------------------------------------------
; ipalset / ipalrst : the page uses the text colour 0 and the background
;   colour 15 (as many bits as the desktop has planes). On the desktop
;   these colours are whatever the user chose, so they are forced to
;   white and black, in the ST palette (Setcolor) and in the Falcon
;   palette (VsetRGB), then given back before leaving the page.
;   a0 = Line-A variables (planes in 0(a0)) for ipalset.
;--------------------------------------------------------------
ipalset:
            movem.l d0-d2/a0-a2,-(sp)
            move.w  (a0),d1             ; planes
            moveq   #15,d0
            cmp.w   #4,d1
            bhs.s   .b
            moveq   #1,d0               ; 1 or 2 planes : 1 or 3
            lsl.w   d1,d0
            subq.w  #1,d0
.b:         move.w  d0,ipbg
            ; --- save (only the first time) ---
            tst.w   ipsaved
            bne.s   .s
            st      ipsaved
            clr.w   d0
            bsr.s   ipstget
            move.w  d0,ipst
            move.w  ipbg,d0
            bsr.s   ipstget
            move.w  d0,ipst+2
            pea     ipfal               ; VgetRGB(0,1,ipfal)
            move.w  #1,-(sp)
            clr.w   -(sp)
            move.w  #94,-(sp)
            trap    #14
            lea     10(sp),sp
            pea     ipfal+4             ; VgetRGB(bg,1,ipfal+4)
            move.w  #1,-(sp)
            move.w  ipbg,-(sp)
            move.w  #94,-(sp)
            trap    #14
            lea     10(sp),sp
            ; --- white text, black background ---
.s:         move.w  #$0fff,d1
            clr.w   d0
            bsr.s   ipstset
            moveq   #0,d1
            move.w  ipbg,d0
            bsr.s   ipstset
            lea     ipwhite,a0
            clr.w   d0
            bsr.s   ipfset
            lea     ipblack,a0
            move.w  ipbg,d0
            bsr.s   ipfset
            movem.l (sp)+,d0-d2/a0-a2
            rts
ipstget:    moveq   #-1,d1              ; Setcolor(d0,-1) : d0 = colour
ipstset:    move.w  d1,-(sp)            ; Setcolor(d0,d1)
            move.w  d0,-(sp)
            move.w  #7,-(sp)
            trap    #14
            addq.l  #6,sp
            rts
ipfset:     pea     (a0)                ; VsetRGB(d0,1,a0)
            move.w  #1,-(sp)
            move.w  d0,-(sp)
            move.w  #93,-(sp)
            trap    #14
            lea     10(sp),sp
            rts

ipalrst:
            movem.l d0-d2/a0-a2,-(sp)
            tst.w   ipsaved
            beq.s   .x
            clr.w   ipsaved
            move.w  ipst,d1
            clr.w   d0
            bsr.s   ipstset
            move.w  ipst+2,d1
            move.w  ipbg,d0
            bsr.s   ipstset
            lea     ipfal,a0
            clr.w   d0
            bsr.s   ipfset
            lea     ipfal+4,a0
            move.w  ipbg,d0
            bsr.s   ipfset
.x:         movem.l (sp)+,d0-d2/a0-a2
            rts

i_cls:      dc.b    27,'c','?',27,'b','@'   ; black background (colour 15/3/1), white text (0)
            dc.b    27,'E',27,'f',0     ; clear, cursor hidden
i_end:      dc.b    27,'c','@',27,'b','?',27,'E',0  ; desktop colours
            even

            section data
i_pos:      dc.b    27,'Y',0,0,0
            even
ipwhite:    dc.l    $00ffffff           ; Falcon palette : $00RRGGBB
ipblack:    dc.l    $00000000
ipfal:      ds.l    2                   ; desktop colours 0 and bg (Falcon)
ipst:       ds.w    2                   ; desktop colours 0 and bg (ST)
ipbg:       ds.w    1                   ; index of the background colour
ipsaved:    ds.w    1
INFOH       equ     23                  ; page height (lines)
; line (0..22), text (38 characters max : fits in 40 columns)
infotab:
            dc.b    0,'HALTERO / ABSTRACT',0
            dc.b    1,'PRESENTS',0
            dc.b    3,'--- 3DREAMS ---',0
            dc.b    4,'Dedicated to Skynet / Abstract',0
            dc.b    6,'Atari Falcon 030 + DSP 56001, VGA',0
            dc.b    7,'Real-time 3D objects : Gouraud, Phong,',0
            dc.b    8,'Cel, Chrome, Mapping and morphing.',0
            dc.b    9,'3D maths and filling done by the DSP.',0
            dc.b    10,'Music : DSP MOD replay and YM tunes.',0
            dc.b    12,'Design .......... Haltero / Abstract',0
            dc.b    13,'DSP MOD replay .. Simplet / Abstract',0
            dc.b    14,'YM replay+tune .. Jochen Hippel',0
            dc.b    15,'Inspired by X-Perience (Abstract 94)',0
            dc.b    17,'+ -  volume   P  pause   M  music',0
            dc.b    18,'O  object     T  auto    V  video',0
            dc.b    19,'S  rendering  ESC  greetings / quit',0
            dc.b    20,'R  trail (True Color)',0
            dc.b    22,'Press SPACE',0
            dc.b    -1
            even
            section text
;==============================================================
            section data
            even
modmask:    dc.b    'ZIK\*.MOD',0
ymmask:     dc.b    'ZIK\*.ORG',0
            even
errtab:     dc.l    e0,e1,e2,e3,e4,e5,e6,e7,e8,e9,e10,e11,e12
e0:         dc.b    '! UNKNOWN ERROR',0
e1:         dc.b    '! CANNOT OPEN THE MODULE',0
e2:         dc.b    '! FILE TOO SMALL FOR A MODULE',0
e3:         dc.b    '! NOT ENOUGH ST-RAM FOR MODULE',0
e4:         dc.b    '! READ ERROR',0
e5:         dc.b    '! NOT ENOUGH ST-RAM FOR SOUND',0
e6:         dc.b    '! MODULE REFUSED BY MEGAPLAYER',0
e7:         dc.b    '! BAD SONG LENGTH IN MODULE',0
e8:         dc.b    '! SOUND SYSTEM ALREADY IN USE',0
e9:         dc.b    '! NO .MOD/.ORG IN ZIK\',0
e10:        dc.b    '! DSP NOT AVAILABLE',0
e11:        dc.b    '! DSP REPLAY NOT ANSWERING',0
e12:        dc.b    '! NOT A COSO .ORG BLOCK',0
t_fps:      dc.b    'FPS ',0
            even
; multipliers for the average depth : 840/n (n = 3..8)
avgmul:     dc.w    0,0,0,280,210,168,140,120,105
; greetings page : y, text (centred)
gtab:       dc.w    0                   ; band number (bandy), text
            dc.l    g1
            dc.w    1
            dc.l    g2
            dc.w    2
            dc.l    g3
            dc.w    3
            dc.l    g4
            dc.w    4
            dc.l    g5
            dc.w    5
            dc.l    g6
            dc.w    6
            dc.l    g7
            dc.w    -1
g1:         dc.b    '- GREETINGS -',0
g2:         dc.b    'MUSIC : MEGAPLAYER DSP REPLAY BY SIMPLET / ABSTRACT',0
g3:         dc.b    'HELLO TO THE OLD ABSTRACT CREW :',0
g4:         dc.b    'SKYNET - SIMPLET - EXOCET',0
g5:         dc.b    'AND TO ZACK   -   CODE : CLAUDE',0
g6:         dc.b    '[+][-] VOLUME [P] PAUSE [M] MUSIC [O] OBJECT [T] AUTO',0
g7:         dc.b    '[V] VIDEO [S] SHADE [R] TRAIL [ESC] QUIT [SPACE] BACK',0
t_title:    dc.b    'MUSICS',0
t_pause:    dc.b    '** PAUSE **',0
t_esc:      dc.b    '[ESC] END',0
t_load:     dc.b    'LOADING ZIK\',0
t_sep:      dc.b    ' > ',0
t_arrow:    dc.b    '>',0
t_slash:    dc.b    '/',0
t_vol:      dc.b    'VOLUME',0
t_pm:       dc.b    '[+] [-]',0
t_help:     dc.b    '[P]PAUSE [M]MUSIC [O]OBJECT [T]AUTO [V]VIDEO [S]SHADE',0
t_pts:      dc.b    ' POINTS ',0
t_fcs:      dc.b    ' FACES',0
t_tg:       dc.b    'TC GOURAUD',0
t_trail:    dc.b    'TRAIL',0
t_tp:       dc.b    'TC PHONG',0
t_tcl:      dc.b    'TC CEL',0
t_fg:       dc.b    'FAST GOURAUD',0
t_fp:       dc.b    'FAST PHONG',0
t_fcl:      dc.b    'FAST CEL',0
t_tch:      dc.b    'TC CHROME',0
t_fch:      dc.b    'FAST CHROME',0
t_tmp:      dc.b    'TC MAPPING',0
t_fmp:      dc.b    'FAST MAPPING',0
            even
shdtab:     dc.l    t_tg,t_tp,t_tcl,t_tch,t_tmp,t_fg,t_fp,t_fcl,t_fch,t_fmp
t_m16:      dc.b    '16 COLORS',0
t_mtc:      dc.b    'TRUECOLOR',0
t_mtf:      dc.b    'TC FAST',0
            even
; band lines : 16 colours (200 lines) / True Color (240)
by16:       dc.w    1,8,15,172,179,186,193
bytc:       dc.w    1,8,15,212,219,226,233
t_obj:      dc.b    'OBJECT : ',0
t_auto:     dc.b    'AUTO ',0
t_sec:      dc.b    ' S',0
t_off:      dc.b    'OFF',0
            even
autotab:    dc.w    10,20,30,60,0,-1    ; durations of the T key (s)
t_defobj:   dc.b    'CUBE',0
objmask:    dc.b    'OBJ\*.OBJ',0
            even
; internal 6x6 glyphs : 0 = empty, 1 = full box, 2 = empty box (bar)
blk6:       dc.b    0,0,0,0,0,0
            dc.b    $78,$78,$78,$78,$78,0
            dc.b    0,0,0,0,$78,0
; ProTracker periods, finetune 0, C-1 .. B-3
palT:       dc.w    $000,$777,$003,$777     ; 0 background, 1 white, 2 red,  3 white
            dc.w    $333,$777,$666,$777     ; 4 green, 5 white, 6 yellow,  7 white
            dc.w    $444,$777,$002,$777     ; 8 blue, 9 white, 10 magenta,11 white
            dc.w    $555,$777,$666,$777     ; 12 cyan,13 white, 14 grey,  15 white

; palette of mode S (solid) : blue -> white gradient
palS:       dc.w    $000,$09a,$893,$823,$8ab,$1a4,$93c,$9b5
            dc.w    $245,$acd,$356,$4de,$c6e,$de7,$e7f,$777
; built-in object (if OBJ\ is empty) : the cube
defobj:
            dc.b    'N CUBE',13,10
            dc.b    'M T',13,10
            dc.b    'V -40 -40 -40',13,10
            dc.b    'V 40 -40 -40',13,10
            dc.b    'V 40 40 -40',13,10
            dc.b    'V -40 40 -40',13,10
            dc.b    'V -40 -40 40',13,10
            dc.b    'V 40 -40 40',13,10
            dc.b    'V 40 40 40',13,10
            dc.b    'V -40 40 40',13,10
            dc.b    'F 1 0 1 2 3',13,10
            dc.b    'F 1 4 5 6 7',13,10
            dc.b    'F 2 0 3 7 4',13,10
            dc.b    'F 2 1 2 6 5',13,10
            dc.b    'F 3 0 1 5 4',13,10
            dc.b    'F 3 3 2 6 7',13,10
defobjend:
            even
;==============================================================
            section bss
            even
tframe:     ds.w    1                   ; time in frames (angles)
sinx:       ds.w    1
cosx:       ds.w    1
siny:       ds.w    1
cosy:       ds.w    1
sinz:       ds.w    1
cosz:       ds.w    1
s0x:        ds.w    1                   ; rotation of the 1st part
c0x:        ds.w    1                   ; (frame of the bounces)
s0y:        ds.w    1
c0y:        ds.w    1
s0z:        ds.w    1
c0z:        ds.w    1
mxx:        ds.w    1                   ; rotation matrix (x 2^14),
mxy:        ds.w    1                   ; stored by rows : mxx mxy mxz
mxz:        ds.w    1
myx:        ds.w    1
myy:        ds.w    1
myz:        ds.w    1
mzx:        ds.w    1
mzy:        ds.w    1
mzz:        ds.w    1
lox:        ds.w    1                   ; light in the object's frame
loy:        ds.w    1
loz:        ds.w    1
offx:       ds.w    1                   ; displacement of the part (bounce)
offy:       ds.w    1
offz:       ds.w    1
tpos:       ds.w    3
oldmode:    ds.w    1
oldssp:     ds.l    1
musok:      ds.w    1
ymmode:     ds.w    1                   ; 1 = current music is YM (.ORG)
ymatt:      ds.w    1                   ; codec attenuation (YM)
ysv893a:    ds.w    1                   ; codec state before the YM
ysv8937:    ds.b    1
ysv8938:    ds.b    1
ymmute:     ds.b    1                   ; pause / volume 0 : YM muted
            even
muserr:     ds.w    1
sndh:       ds.w    1
dspok:      ds.w    1                   ; DSP program loaded
playing:    ds.w    1                   ; replay started
fps:        ds.w    1                   ; frames per second (display)
fpscnt:     ds.w    1
fpsclk:     ds.l    1
clkval:     ds.l    1
initres:    ds.l    1                   ; result of MGTK_Init_Module_Samples
paused:     ds.w    1                   ; 0 = playing, -1 = paused
gpage:      ds.w    1                   ; 0 = menu, 1 = greetings
loading:    ds.w    1                   ; 1 while loading
nmods:      ds.w    1                   ; number of modules in ZIK
curmod:     ds.w    1                   ; index of the current module
fontw:      ds.w    1                   ; font width (bytes)
fontdat:    ds.l    1                   ; 6x6 font data
fontoff:    ds.l    1                   ; table of the x of each character
fontfirst:  ds.w    1                   ; 1st character of the font
proj:       ds.w    2*MAXV              ; screen x,y
rv:         ds.w    3*MAXV              ; rotated x,y,z
fymin:      ds.w    1
fymax:      ds.w    1
pofs:       ds.w    1
fv:         ds.w    18                  ; 9 points (x,y)
xa:         ds.w    240                 ; chain of the descending edges
xb:         ds.w    240                 ; chain of the ascending edges
ia:         ds.w    240                 ; intensities (Gouraud)
ib:         ds.w    240
va:         ds.w    240                 ; v (fake Phong), at +1920 from xa
vb:         ds.w    240
curl:       ds.w    240                 ; current outline (TC) : x min
curr:       ds.w    240                 ;                        x max
spans1:     ds.w    2*240               ; outline drawn in buf1 (L, R)
spans2:     ds.w    2*240               ; outline drawn in buf2
spans3:     ds.w    2*240
p0end:      ds.w    1                   ; end of the 1st part (vertices)
fvi:        ds.w    10                  ; intensities of the face's vertices
fvv:        ds.w    10                  ; v of the vertices (fake Phong) = fvi+20
tcmode:     ds.w    1                   ; 0 = 16 colours, 1 = True Color
autostage:  ds.w    1                   ; step of the auto mode (autonext)
objtex:     ds.b    MAXOBJ              ; object with a texture (auto Mapping)
            even
vgamon:     ds.w    1                   ; VGA monitor
gour:       ds.w    1                   ; Gouraud active (TC + solid object)
scrh:       ds.w    1                   ; screen height (200 / 240)
scrhm1:     ds.w    1
scrcy:      ds.w    1                   ; vertical centre
bandy:      ds.w    7                   ; band lines of the mode
ytc:        ds.l    TCH                 ; y * 640
bgtab:      ds.l    TCH                 ; gradient background (2 pixels per long)
; ramps : one per material (MAXMAT), each = margin 48, 128 shades, margin 48
rampx:      ds.w    224*MAXMAT          ; Gouraud (RGB565)
ramp        equ     rampx+96
ramp2x:     ds.l    224*MAXMAT          ; same on 2 pixels (fast TC)
ramp2       equ     ramp2x+192
rampcx:     ds.w    224*MAXMAT          ; cel shading (4 steps)
rampc       equ     rampcx+96
ramp2cx:    ds.l    224*MAXMAT
ramp2c      equ     ramp2cx+192
matmode:    ds.w    1                   ; 1 = materials (C lines) in the file
mattexn:    ds.b    14*MAXMAT           ; texture names (X)
mattex:     ds.w    MAXMAT              ; texture loaded
texpath:    ds.b    32
uvmode:     ds.w    1                   ; 0 intensity, 1 normal, 2 texture
texmat:     ds.w    1                   ; material carrying the texture (-1 none)
fhasw:      ds.b    MAXF                ; face with texture coordinates (W) :
                                        ; -1 = fan of triangles, 1 = planar
            even
uapb:       ds.w    2*8                 ; uvaffine : vertices in the plane
uadet:      ds.l    1
uaan:       ds.l    1
uabn:       ds.l    1
            even
fuv:        ds.b    16*(MAXF+1)         ; texture u,v per face vertex (+ triangle)
nmat:       ds.w    1                   ; materials used (1..MAXMAT)
nshade:     ds.w    1                   ; shades per material (16 colours)
lflat:      ds.w    1                   ; old format : F 3 faces (flat)
matrgb:     ds.w    3*MAXMAT            ; colours of the materials (0..15)
matdef:     ds.w    MAXMAT              ; material defined by a C line
curmat:     ds.w    1                   ; material being processed (mkramp)
mflat:      ds.w    1                   ; constant ramp (flat)
mr:         ds.l    1                   ; ramps of the current material
mr2:        ds.l    1
mrc:        ds.l    1
mr2c:       ds.l    1
mph:        ds.l    1
curramp:    ds.l    1                   ; ramp in use (Gouraud / cel)
curramp2:   ds.l    1
shade:      ds.w    1                   ; 0 Gouraud, 1 fake Phong, 2 cel, 3 chrome
phong:      ds.w    1                   ; fake Phong active this frame
cel:        ds.w    1                   ; cel shading active this frame
prow:       ds.w    1
tclcol:     ds.l    1                   ; colour of the TC lines
phint:      ds.b    128*128             ; shade of the Phong map (0..127)
            even
phtex:      ds.w    128*256*MAXMAT      ; Phong maps RGB565 (line = 256), one per material
phchr:      ds.w    128*256             ; chrome map (environment mapping)
textab:     ds.w    256*256*MAXMAT      ; textures (128 KB each : 128x128 repeated 2x2)
sqtab:      ds.w    16385               ; square roots (genph)
curtex:     ds.l    1                   ; map used by tcfillp
phok:       ds.w    1                   ; Phong / chrome maps ready
objrad:     ds.w    1                   ; radius of the object on screen
mrad0:      ds.w    1                   ; radius of the previous object
curax:      ds.w    1                   ; amplitudes of the path
curay:      ds.w    1
pathx:      ds.w    1                   ; centre of the object on screen
pathy:      ds.w    1
mcloud:     ds.w    3*256               ; cloud of the displayed object (MPTS)
mfrom:      ds.w    3*256               ; starting cloud of the morphing
mcur:       ds.w    3*256               ; current position
mkey:       ds.w    256
mtri:       ds.b    4
mseed:      ds.l    1
mtot:       ds.l    1
macc:       ds.l    1
morph:      ds.w    1                   ; morphing frames left
mdraw:      ds.w    1                   ; this frame : point cloud
mvalid:     ds.w    1                   ; mcloud holds an object
ms:         ds.w    1                   ; progress (smooth curve, 0..256)
mf:         ds.w    1                   ; swelling (256 = none)
fnrm:       ds.w    3*MAXF              ; face normals (x 2^14)
fadj:       ds.w    8*MAXF              ; neighbour of each edge (cel)
recip:      ds.w    TCW                 ; 32767 / line width
rcp16:      ds.l    TCH+1               ; 65536 / edge height
cursig:     ds.w    SIGN                ; state displayed by the menu
lastsig:    ds.w    SIGN
sigok:      ds.w    1
lastslots:  ds.w    1
tchalf:     ds.w    4                   ; colours/2 of the transparent faces
rgbtab:     ds.w    3*14
tmprgb:     ds.w    3
vnorm:      ds.w    3*MAXV              ; vertex normals (x 2^14)
vint:       ds.w    MAXV                ; intensity per vertex (0..127 x 128)
vu:         ds.w    MAXV                ; fake Phong : u,v of the vertex (8.8)
vv:         ds.w    MAXV                ;   = rotated normal x,y
vacc:       ds.l    3*MAXV
modbase:    ds.l    1
modlen:     ds.l    1
modend:     ds.l    1
numbuf:     ds.b    16
mastervol:  ds.w    1                  ; master volume 0..64
dta:        ds.b    44                  ; DTA for Fsfirst/Fsnext
            even
modnames:   ds.b    MAXMODS*NAMESZ      ; 8.3 names of the modules
pathbuf:    ds.b    32                  ; "ZIK\NAME.MOD"
mline:      ds.b    LINESZ              ; menu line (COLS characters)
            even
slotidx:    ds.w    1                   ; current cache slot
fullclr:    ds.w    1                   ; full clears left
dirty0:     ds.w    1                   ; lines touched by the cube (current screen)
dirty1:     ds.w    1
curbox:     ds.l    1
box1:       ds.w    4                   ; last drawing in buf1 (y0,y1,word0,word1)
box2:       ds.w    4                   ; last drawing in buf2
box3:       ds.w    4                   ; last drawing in buf3
trail:      ds.w    1                   ; True Color trail : -1 = on
trn:        ds.w    1                   ; boxes in the history
trpos:      ds.w    1                   ; next slot of the history
trhist:     ds.w    4*TRK               ; boxes of the last TRK frames
ytab:       ds.w    200                 ; y*160
; --- current object ---
nv:         ds.w    1
nf:         ds.w    1
ne:         ds.w    1
np:         ds.w    1
nvis:       ds.w    1
objmode:    ds.w    1                   ; 0 = transparent, 1 = solid
custpal:    ds.w    1
objerr:     ds.w    1
nobjs:      ds.w    1
curobj:     ds.w    1
autosec:    ds.w    1                   ; object change (s), 0 = off
objclk:     ds.l    1                   ; _hz_200 of the last change
curcol:     ds.w    1                   ; colour of the face (mode S)
objpal:     ds.w    16
objtitle:   ds.b    TITLESZ
objpath:    ds.b    32
objnames:   ds.b    MAXOBJ*NAMESZ
            even
parts:      ds.b    MAXP*PARTSZ
objv:       ds.w    3*MAXV
objf:       ds.b    (MAXF+1)*FACESZ     ; (+1 : temporary triangle of the mapping)
objt:       ds.b    MAXT*TSZ            ; BSP tree (mode S)
nt:         ds.w    1                   ; BSP nodes (0 = sort by z)
frank:      ds.w    MAXF                ; drawing rank of each face
bspcnt:     ds.w    1
nsin:       ds.w    1
cbuf:       ds.b    16                  ; indices of a face (x2)
cuv:        ds.w    16                  ; u,v of a face (x2)
            even
            even
bspeye:     ds.l    3                   ; eye in the object's frame
obje:       ds.b    2*MAXE
vislist:    ds.l    2*MAXF
rkbuf:      ds.l    2*MAXF              ; visible faces ordered by BSP rank
fseen:      ds.w    MAXF                ; frame in which the face was visible
fshade:     ds.b    MAXF                ; displayed shade (smoothed)
            even
objtext:    ds.b    OBJTXT
            even
ltab:       ds.l    320                 ; left mask : offset (per x)
rtab:       ds.l    320                 ; right mask : offset (per x)
bandcache:  ds.b    NSLOTS*SLOTSZ       ; bands already drawn
            even
oldfpal:    ds.l    256                 ; saved Falcon palette
oldlog:     ds.l    1
oldphys:    ds.l    1
buf1:       ds.l    1
buf2:       ds.l    1
buf3:       ds.l    1
disp:       ds.l    1                   ; screen on display (the oldest)
vqprev:     ds.l    1                   ; VBL of the previous swap
frcval:     ds.l    1
front:      ds.l    1
back:       ds.l    1
sintab:     ds.w    256
            ds.b    8192                ; (supervisor : TOS + interrupts)
stackend:   ds.l    1

;==============================================================
;  Amiga DSP replay - MegaPlayer - Simplet / FATAL DESIGN
;  (original source not modified, see AMIGADSP.S)
;==============================================================
MGTK_FX_Voices  equ     MGTK_Fx_Voices  ; same label, different case
            include 'AMIGADSP.S'
