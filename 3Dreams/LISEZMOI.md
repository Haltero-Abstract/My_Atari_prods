# 3Dreams — Atari Falcon 030 + DSP 56001

**3Dreams** (anciennement *CUBEDSP*) par **Haltero / Abstract**, dédié à **Skynet**.

Des objets 3D en temps réel avec un lecteur de musique à l'écran. Les calculs 3D et le
remplissage Gouraud sont faits par le DSP 56001, qui mixe la musique en même temps, dans
l'esprit de *X-Perience* (Abstract, 1994).

## Crédits

| | |
|---|---|
| Design | Haltero / Abstract |
| Replay MOD DSP | Simplet / Fatal Design (MegaPlayer 1.16, `AMIGADSP.S` + `AMIGADSP.P56`, non modifiés) |
| Replay YM + musique | Jochen Hippel (« Mad Max », format COSO), tirée de l'intro *Power Boat* |
| Inspiration | *X-Perience* de Skynet et Simplet (Abstract, 1994) |

> « You can freely use this code in your programs or demos, I only ask you to credit me. »
> — Simplet, `MGPL-116\AMIGA\READ.ME`

## Configuration

- Atari Falcon 030 avec son DSP 56001.
- **Moniteur VGA** pour le True Color (sur un moniteur RGB/télé, seul le mode 16 couleurs est
  disponible).
- 4 Mo de mémoire conseillés. La démo elle-même a besoin d'environ 2 Mo, plus la taille du
  module joué (un gros module de 3,4 Mo demande un Falcon de 14 Mo).
- Testée dans Hatari 2.6 (émulation Falcon + DSP, EmuTOS). Pas encore testée sur un vrai Falcon
  depuis l'ajout de la 3D au DSP.

## Lancement

Mettre `3DREAMS.PRG` à côté des dossiers `OBJ\` et `ZIK\` et le lancer.

Une page d'accueil présente le contenu, les crédits et les touches.
- **ESPACE** lance la démo.
- **ESC** revient au bureau.

## Touches

| Touche | Action |
|---|---|
| `+` / `-` | volume |
| `P` | pause / reprise |
| `M` | musique suivante (`ZIK\*.MOD` et `ZIK\*.ORG`, ordre alphabétique ; à la fin d'un module, le suivant démarre seul) |
| `O` | objet suivant (`OBJ\*.OBJ`) |
| `T` | changement automatique : 10 / 20 / 30 / 60 s / arrêt (10 s au départ) |
| `V` | 16 couleurs ↔ True Color 320×240 (VGA seulement) |
| `S` | rendu des objets pleins en True Color : Gouraud → Phong → Cel → Chrome → Mapping |
| `R` | traînée en True Color : l'objet laisse une traînée qui s'efface (TRAIL s'affiche en haut) |
| `ESC` | page des greetings ; un 2e `ESC` quitte (vidéo, palette, son et souris restaurés) |
| `ESPACE` | retour depuis la page des greetings |

La ligne du haut affiche le mode vidéo, le rendu et le nombre d'images par seconde.

## Mode automatique

- Tous les objets passent en 16 couleurs.
- Puis, en True Color :
  1. les objets transparents et fil de fer ;
  2. les objets pleins en Gouraud, Cel, Phong et Chrome ;
  3. les objets pleins texturés en Mapping.
- Puis on recommence.

Une étape sans objet correspondant est sautée. Chaque changement d'objet est un **morphing** :
l'ancien objet devient un nuage de 256 points qui vole vers le nouveau. Les objets se déplacent
aussi sur une courbe de Lissajous entre les bandeaux de texte.

## Rendus

| Rendu | Description |
|---|---|
| 16 couleurs | VGA 320×200, faces triées (ou ordonnées par l'arbre BSP), 14 teintes par objet |
| Gouraud | rampe de 128 teintes par matière, intensités interpolées depuis les normales aux sommets |
| Phong (faux) | normales (u,v) interpolées, lues dans une carte de lumière 128×128 : le reflet glisse sur les faces |
| Cel | 4 teintes nettes + contours noirs sur les arêtes vives et la silhouette |
| Chrome | environment mapping d'un décor ciel / horizon / sol / soleil |
| Mapping | textures 128×128 RGB565 (affine), faces découpées en triangles |
| Transparent | faces mélangées à 50 % avec arêtes blanches |

## La partie DSP

Le DSP fait tourner deux programmes à la fois :

- **le replay MOD de Simplet** (`AMIGADSP.P56`, non modifié). Il travaille entièrement sous
  interruption.
- **le programme 3D de 3Dreams** (`3DREAMS.P56`, source dans `outils\DSP\3DREAMS.A56`). Il tourne dans le temps libre
  du DSP.
  - Pour chaque sommet, il fait la rotation, la projection et l'éclairage (plus les u,v du
    faux Phong), dans tous les modes.
  - En True Color Gouraud et Cel, le 68030 envoie seulement les sommets de chaque face. Le DSP
    trace les arêtes et calcule chaque ligne, puis renvoie les pixels RGB565. Le 68030 se
    contente de les recopier à l'écran (mesuré sur le vrai Falcon : plus rapide qu'envoyer
    un indice de rampe et chercher la couleur côté 68030).
  - Pendant un morphing, il calcule les 256 points du nuage (interpolation, rotation,
    projection) et les renvoie d'un bloc ; le 68030 ne fait que les dessiner.

Les deux programmes sont envoyés ensemble par `Dsp_ExecProg`. La boucle d'attente de Simplet est
redirigée vers le programme 3D, et ses fichiers eux-mêmes ne sont pas modifiés. Le 68030 ne parle au
programme 3D que quand la musique n'utilise pas le DSP (`MGTK_Replay_In_Service = 0`, interruptions
masquées) : le port hôte est donc toujours libre quand la musique en a besoin. Si le DSP ne
répond plus, le 68030 reprend ces calculs tout seul.

Le 68030 garde :
- la lecture des cartes Phong / Chrome et des textures (trop grandes pour la mémoire DSP
  laissée libre par le replay) : le DSP trace les faces et envoie pour chaque pixel sa position
  dans la carte ;
- le mélange à 50 %, car il doit relire l'écran ;
- le remplissage en plans des 16 couleurs ;
- le dessin du nuage du morphing.

Hatari, objet CLAUDE, images/s :

| Mode | 68030 seul | avec le DSP |
|---|---|---|
| TC Gouraud | 25,0 | 29,9 |
| TC Phong | 18,6 | 21,2 |
| TC Chrome | 19,2 | 21,4 |
| 16 couleurs | 41,0 | 45,3 |

## Musique

- **`ZIK\*.MOD`** : modules Amiga mixés par le DSP. Le replay accepte 4/6/8 voies, M.K., M!K!,
  FLT4, RASP, OCTA, CD81, FA0x et xxCH.
- **`ZIK\*.ORG`** : un bloc COSO de Jochen Hippel (player + musique) tel que copié de la mémoire,
  par exemple `PWRBOAT.ORG`.
  - Il est joué sur le YM2149 par le Timer A à 50 Hz.
  - Les écritures dans le YM propres au ST sont corrigées pour le Falcon au chargement (le
    fichier lui-même n'est pas modifié).

`REPFREQ` dans `3DREAMS.S` règle la fréquence du replay DSP : 1 = 49 kHz, 2 = 32,8 kHz (par
défaut), 3 = 24,5 kHz.

## Objets 3D (`OBJ\*.OBJ`)

Un fichier texte par objet, lus au démarrage et triés par nom. Un préfixe numérique (`01`,
`02`…) fixe l'ordre.

Limites :
- 32 objets ;
- 256 sommets et 200 faces par objet ;
- 4 matières par objet.

Une commande par ligne ; `;` commence un commentaire :

```
N nom            nom affiché dans le menu (20 caractères max)
M T | M S        T = transparent, S = plein ombré
P retard         nouvelle partie : même rotation, <retard> images plus tard
B h a T Tx       la partie rebondit : parabole -h..+h toutes les T images, aller-retour -a..+a en Tx images
V x y z          sommet (garder l'objet dans un rayon d'environ 70)
F c a b c [d..]  face convexe de 3 à 8 sommets ; c = plan 1..3 (T) ou matière 1..4 (S)
                 mode S : sommets dans le sens direct vus de l'extérieur
E a b            arête en plus (mode T)
L i r g b        couleur i (0..14) de la palette, r g b = 0..15
C m r g b        matière m (1..4) de couleur r g b (0..15)
X m NOM.TEX      texture OBJ\NOM.TEX (128x128 RGB565, 32768 octets)
W u0 v0 u1 v1..  coordonnées de texture de la face précédente (0..255, se répète tous les 128)
T f n av ar      nœud BSP : faces f..f+n-1, fils devant / derrière (-1 = aucun), nœud 0 = racine
```

## Outils (`outils\`)

- **`extrudeur.html`** — l'extrudeur. À ouvrir en local dans un navigateur.
  - Il transforme une image en objet 3D extrudé.
  - On peut colorier des faces et ajouter une texture.
  - Il écrit `NOM.OBJ` (avec son arbre BSP) et `NOM.TEX` : copier les deux dans `OBJ\`.
- **`BSPOBJ.PY`** — ajoute un arbre BSP à un objet plein fait à la main.
- **`GENOBJ.PY`** (dans le dossier principal) — génère les objets de base : sphère, tore…
- **`DSP\3DREAMS.A56`** — source du programme DSP. Pour refaire `3DREAMS.P56`, l'assembler avec
  l'assembleur DSP56001 libre [a56](https://github.com/xboxdev/a56), puis le convertir avec
  `DSP\LOD2P56.PY` :
  ```
  a56 -o 3DREAMS.OUT 3DREAMS.A56
  python LOD2P56.PY 3DREAMS.OUT ..\..\3DREAMS.P56
  ```

## Assemblage

```powershell
.\build.ps1
```

`build.ps1` assemble `3DREAMS.S` avec rg-asm et produit `3DREAMS.PRG`.
- `3DREAMS.S` inclut `AMIGADSP.S` (qui inclut `AMIGADSP.P56`) et `3DREAMS.P56`.
- Ces fichiers doivent rester à côté de `3DREAMS.S`.

## Fichiers

| Fichier | Contenu |
|---|---|
| `3DREAMS.S` / `3DREAMS.PRG` | la démo (source / programme) |
| `3DREAMS.P56` | programme 3D du DSP (fait à partir de `outils\DSP\3DREAMS.A56`) |
| `AMIGADSP.S`, `AMIGADSP.P56` | replay DSP de Simplet (non modifié) |
| `OBJ\` | objets 3D et textures |
| `ZIK\` | musiques (`.MOD`, `.ORG`) |
| `outils\` | outils extrudeur, BSP et DSP |
| `README.md` | ce fichier en anglais |
