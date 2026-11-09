# GENOBJ.PY - generates the basic 3D objects of 3Dreams (OBJ\*.OBJ) and OBJDATA.INC
#   python GENOBJ.PY   (run from the main folder ; rewrites the files below)
import math
def ste(v): return (v>>1)|((v&1)<<3)
def palw(r,g,b): return (ste(r)<<8)|(ste(g)<<4)|ste(b)

def cross(a,b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def sub(a,b): return tuple(x-y for x,y in zip(a,b))
def dot(a,b): return sum(x*y for x,y in zip(a,b))

def orient(V,face,outdir):
    v0,v1,v2=[V[i] for i in face[:3]]
    n=cross(sub(v1,v0),sub(v2,v0))
    return face if dot(n,outdir)>0 else face[::-1]

def write(name,lines):
    open(f'OBJ/{name}','w',newline='\r\n').write('\n'.join(lines)+'\n')

hdr=lambda t:[f'; {t}',"; format : see the 3D OBJECTS header in 3DREAMS.S (N M P V F E L)"]

# --- cube (transparent, like the original) ---
CUBEV=[(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]
CUBEF=[(2,(0,1,2,3)),(2,(4,5,6,7)),(4,(0,3,7,4)),(4,(1,2,6,5)),(6,(0,1,5,4)),(6,(3,2,6,7))]
def cube_lines(s):
    L=[f'V {x*s} {y*s} {z*s}' for x,y,z in CUBEV]
    return L
def cube_faces(off):
    return [f'F {p//2} '+' '.join(str(i+off) for i in f) for p,f in CUBEF]
cube=hdr('transparent cube')+['N CUBE','M T']+cube_lines(40)+cube_faces(0)
write('01CUBE.OBJ',cube)
builtin=cube[2:]

# --- 3D triangle (tetrahedron, transparent) ---
s=38
TV=[(s,s,s),(s,-s,-s),(-s,s,-s),(-s,-s,s)]
TF=[(1,(0,1,2)),(2,(0,3,1)),(3,(0,2,3)),(1,(1,3,2))]
tri=hdr('3D triangle : transparent tetrahedron')+['N TRIANGLE 3D','M T']+[f'V {x} {y} {z}' for x,y,z in TV]+[f'F {p} '+' '.join(map(str,f)) for p,f in TF]
write('02TRI.OBJ',tri)

# --- sphere (solid, 8 x 5) ---
R=58; SL=8; ST=5
V=[(0,-R,0)]
for i in range(1,ST):
    th=math.pi*i/ST; y=-R*math.cos(th); r=R*math.sin(th)
    for j in range(SL):
        ph=2*math.pi*j/SL; V.append((round(r*math.cos(ph)),round(y),round(r*math.sin(ph))))
V.append((0,R,0))
F=[]
ring=lambda i,j:1+(i-1)*SL+(j%SL)
for j in range(SL): F.append((0,ring(1,j+1),ring(1,j)))
for i in range(1,ST-1):
    for j in range(SL): F.append((ring(i,j),ring(i,j+1),ring(i+1,j+1),ring(i+1,j)))
last=len(V)-1
for j in range(SL): F.append((last,ring(ST-1,j),ring(ST-1,j+1)))
F=[orient(V,f,tuple(sum(V[k][c] for k in f)/len(f) for c in range(3))) for f in F]
sph=hdr(f'solid sphere : {len(V)} vertices, {len(F)} faces')+['N SPHERE','M S']+[f'V {x} {y} {z}' for x,y,z in V]+['F 1 '+' '.join(map(str,f)) for f in F]
write('03SPHERE.OBJ',sph)

# --- torus (solid, 10 x 5, orange palette) ---
RA=44; RB=19; NU=10; NV=5
V=[];C=[]
for i in range(NU):
    u=2*math.pi*i/NU
    for j in range(NV):
        v=2*math.pi*j/NV
        x=(RA+RB*math.cos(v))*math.cos(u); z=(RA+RB*math.cos(v))*math.sin(u); y=RB*math.sin(v)
        V.append((round(x),round(y),round(z)))
idx=lambda i,j:(i%NU)*NV+(j%NV)
F=[]
for i in range(NU):
    for j in range(NV):
        f=(idx(i,j),idx(i+1,j),idx(i+1,j+1),idx(i,j+1))
        um=2*math.pi*(i+0.5)/NU
        cen=tuple(sum(V[k][c] for k in f)/4 for c in range(3))
        ringp=(RA*math.cos(um),0,RA*math.sin(um))
        F.append(orient(V,f,sub(cen,ringp)))
def amb(i): return 0.32+0.68*(i-1)/13          # ambient light : never black
pal=['L 0 0 0 0']+[f'L {i} {round(15*amb(i))} {round(10*amb(i)**1.4)} {round(4*amb(i)**3)}' for i in range(1,15)]
tore=hdr(f'solid torus : {len(V)} vertices, {len(F)} faces, orange palette')+['N TORE','M S']+pal+[f'V {x} {y} {z}' for x,y,z in V]+['F 1 '+' '.join(map(str,f)) for f in F]
write('04TORE.OBJ',tore)

# --- grand finale : cube in the cube, 2 s delay ---
fin=hdr('grand finale : a cube in the cube, same rotation with a 2 s delay')+['N BOUQUET FINAL','M T']
fin+=cube_lines(40)+cube_faces(0)
fin+=['; 2nd part : 120 frames of delay = 2 seconds at 60 Hz (VGA)','P 120',
      '; it bounces like a ball : height 24, back and forth 16, bounce in 50 frames,',
      '; crossing in 170 frames (radius 10.4 + sqrt(24x24+16x16) = 39.2 : stays inside the big cube)','B 24 16 50 170']
fin+=cube_lines(6)+cube_faces(8)
write('05FINAL.OBJ',fin)

# --- default S palette (blue -> white) + built-in object ---
palS=[0]+[palw(round(13*amb(i)**3),round(14*amb(i)**1.5),round(15*amb(i))) for i in range(1,15)]+[palw(14,14,14)]
asm=['; palette of mode S (solid) : blue -> white gradient',
     'palS:       dc.w    '+','.join(f'${w:03x}' for w in palS[:8]),
     '            dc.w    '+','.join(f'${w:03x}' for w in palS[8:]),
     '; built-in object (if OBJ\\ is empty) : the cube',
     'defobj:']
for l in builtin: asm.append(f"            dc.b    '{l}',13,10")
asm.append('defobjend:')
asm.append('            even')
open('OBJDATA.INC','w').write('\n'.join(asm)+'\n')
print(len(sph),len(tore))
