# 3Dreams — Atari Falcon 030 + DSP 56001

**3Dreams** (formerly *CUBEDSP*) by **Haltero / Abstract**, dedicated to **Skynet**.

Real-time 3D objects with an on-screen music player. The 3D maths and the Gouraud
filling are done by the DSP 56001 while it also mixes the music, in the spirit of
*X-Perience* (Abstract, 1994).

## Credits

| | |
|---|---|
| Design | Haltero / Abstract |
| DSP MOD replay | Simplet / Fatal Design (MegaPlayer 1.16, `AMIGADSP.S` + `AMIGADSP.P56`, unmodified) |
| YM replay + tune | Jochen Hippel ("Mad Max", COSO format), taken from the *Power Boat* intro |
| Inspiration | *X-Perience* by Skynet & Simplet (Abstract, 1994) |

> "You can freely use this code in your programs or demos, I only ask you to credit me."
> — Simplet, `MGPL-116\AMIGA\READ.ME`

## Requirements

- Atari Falcon 030 with its DSP 56001.
- **VGA monitor** for True Color (on an RGB/TV monitor only the 16-colour mode is available).
- 4 MB of RAM recommended. The demo itself needs about 2 MB, plus the size of the module
  being played (a large module of 3.4 MB needs a 14 MB Falcon).
- Tested in Hatari 2.6 (Falcon + DSP emulation, EmuTOS). Not yet tested on a real Falcon
  since the DSP 3D was added.

## Running

Put `3DREAMS.PRG` next to the `OBJ\` and `ZIK\` folders and run it.

A welcome page shows the contents, the credits and the keys.
- **SPACE** starts the demo.
- **ESC** returns to the desktop.

## Keys

| Key | Action |
|---|---|
| `+` / `-` | volume |
| `P` | pause / resume |
| `M` | next music (`ZIK\*.MOD` and `ZIK\*.ORG`, alphabetical order; a finished module goes to the next one) |
| `O` | next object (`OBJ\*.OBJ`) |
| `T` | automatic change: 10 / 20 / 30 / 60 s / off (10 s at start) |
| `V` | 16 colours ↔ True Color 320×240 (VGA only) |
| `S` | rendering of solid objects in True Color: Gouraud → Phong → Cel → Chrome → Mapping |
| `R` | trail in True Color: the object leaves a fading trail (TRAIL is shown at the top) |
| `ESC` | greetings page; a 2nd `ESC` quits (video, palette, sound and mouse restored) |
| `SPACE` | back from the greetings page |

The top line shows the video mode, the rendering and the frames per second.

## Automatic mode

- Every object is shown in 16 colours.
- Then, in True Color:
  1. the transparent and wireframe objects;
  2. the solid objects in Gouraud, Cel, Phong and Chrome;
  3. the textured solid objects in Mapping.
- Then it starts again.

A step with no matching object is skipped. Each change of object is a **morphing**: the old
object turns into a cloud of 256 points that flies to the new one. The objects also move
along a Lissajous curve between the text bands.

## Renderings

| Rendering | Description |
|---|---|
| 16 colours | 320×200 VGA, faces sorted (or BSP-ordered), 14 shades per object |
| Gouraud | 128-shade ramp per material, intensities interpolated from the vertex normals |
| Phong (fake) | interpolated normals (u,v) read in a 128×128 light map: the highlight slides across the faces |
| Cel | 4 sharp shades + black outlines on sharp edges and silhouettes |
| Chrome | environment mapping of a sky / horizon / ground / sun scenery |
| Mapping | 128×128 RGB565 textures (affine), faces cut into triangles |
| Transparent | faces blended at 50 % with white edges |

## The DSP part

The DSP runs two programs at once:

- **Simplet's MOD replay** (`AMIGADSP.P56`, unmodified). It works entirely under interrupt.
- **the 3Dreams 3D program** (`3DREAMS.P56`, source in `outils\DSP\3DREAMS.A56`). It runs in the DSP's free time.
  - For every vertex it does the rotation, the projection and the lighting (plus the fake
    Phong u,v), in every mode.
  - In True Color Gouraud and Cel, the 68030 only sends the vertices of each face. The DSP
    traces the edges and computes every line, then sends back the RGB565 pixels. The 68030
    simply copies them to the screen (measured on the real Falcon: faster than sending a
    ramp index and looking the colour up on the 68030).
  - During a morphing, it computes the 256 points of the cloud (interpolation, rotation,
    projection) and sends them back in one go ; the 68030 only draws them.

Both programs are sent together by `Dsp_ExecProg`. Simplet's idle loop is redirected to
the 3D program, and his files themselves are not changed. The 68030 only talks to the 3D program when the
music is not using the DSP (`MGTK_Replay_In_Service = 0`, interrupts masked), so the host port
is always free when the music needs it. If the DSP stops answering, the 68030 takes these
computations back by itself.

The 68030 still does:
- reading the Phong / Chrome maps and the textures (too big for the DSP memory left free by
  the replay): the DSP traces the faces and sends, for each pixel, its position in the map;
- 50 % blending, because it has to read the screen;
- the 16-colour bitplane filling;
- the drawing of the morphing cloud.

Hatari, CLAUDE object, frames/s:

| Mode | 68030 only | with the DSP |
|---|---|---|
| TC Gouraud | 25.0 | 29.9 |
| TC Phong | 18.6 | 21.2 |
| TC Chrome | 19.2 | 21.4 |
| 16 colours | 41.0 | 45.3 |

## Music

- **`ZIK\*.MOD`**: Amiga modules mixed by the DSP. The replay accepts 4/6/8 voices, M.K., M!K!,
  FLT4, RASP, OCTA, CD81, FA0x and xxCH.
- **`ZIK\*.ORG`**: a Jochen Hippel COSO block (player + tune) as dumped from memory, for
  example `PWRBOAT.ORG`.
  - It is played on the YM2149 by Timer A at 50 Hz.
  - The ST-only YM writes are patched for the Falcon when the file is loaded (the file itself
    is not changed).

`REPFREQ` in `3DREAMS.S` sets the DSP replay frequency: 1 = 49 kHz, 2 = 32.8 kHz (default),
3 = 24.5 kHz.

## 3D objects (`OBJ\*.OBJ`)

There is one text file per object, read at start-up and sorted by name. A numeric prefix
(`01`, `02`…) sets the order.

Limits:
- 32 objects;
- 256 vertices and 200 faces per object;
- 4 materials per object.

Each line is one command; `;` starts a comment:

```
N name           name shown in the menu (20 characters max)
M T | M S        T = transparent, S = shaded solid
P delay          new part : same rotation, <delay> frames later
B h a T Tx       the part bounces : parabola -h..+h every T frames, back and forth -a..+a in Tx frames
V x y z          vertex (keep the object within a radius of about 70)
F c a b c [d..]  convex face of 3 to 8 vertices ; c = plane 1..3 (T) or material 1..4 (S)
                 mode S : vertices counter-clockwise seen from the outside
E a b            extra edge (mode T)
L i r g b        palette colour i (0..14), r g b = 0..15
C m r g b        material m (1..4) of colour r g b (0..15)
X m NAME.TEX     texture OBJ\NAME.TEX (128x128 RGB565, 32768 bytes)
W u0 v0 u1 v1..  texture coordinates of the previous face (0..255, repeats every 128)
T f n fr bk      BSP node : faces f..f+n-1, front / back child (-1 = none), node 0 = root
```

## Tools (`outils\`)

- **`extrudeur.html`** — the extruder. Open it locally in a browser.
  - It turns an image into an extruded 3D object.
  - You can paint face colours and add a texture.
  - It writes `NAME.OBJ` (with its BSP tree) and `NAME.TEX`: copy both into `OBJ\`.
- **`BSPOBJ.PY`** — adds a BSP tree to a hand-made solid object.
- **`GENOBJ.PY`** (in the main folder) — generates the basic objects: sphere, torus…
- **`DSP\3DREAMS.A56`** — source of the DSP program. To rebuild `3DREAMS.P56`, assemble it with
  the free DSP56001 assembler [a56](https://github.com/xboxdev/a56), then convert it with
  `DSP\LOD2P56.PY`:
  ```
  a56 -o 3DREAMS.OUT 3DREAMS.A56
  python LOD2P56.PY 3DREAMS.OUT ..\..\3DREAMS.P56
  ```

## Building

```powershell
.\build.ps1
```

`build.ps1` assembles `3DREAMS.S` with rg-asm into `3DREAMS.PRG`.
- `3DREAMS.S` includes `AMIGADSP.S` (which includes `AMIGADSP.P56`) and `3DREAMS.P56`.
- Keep these files next to `3DREAMS.S`.

## Files

| File | Contents |
|---|---|
| `3DREAMS.S` / `3DREAMS.PRG` | the demo (source / program) |
| `3DREAMS.P56` | DSP 3D program (built from `outils\DSP\3DREAMS.A56`) |
| `AMIGADSP.S`, `AMIGADSP.P56` | Simplet's DSP replay (unmodified) |
| `OBJ\` | 3D objects and textures |
| `ZIK\` | music (`.MOD`, `.ORG`) |
| `outils\` | extruder, BSP and DSP tools |
| `LISEZMOI.md` | this file in French |
