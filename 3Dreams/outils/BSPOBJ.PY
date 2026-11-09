# BSPOBJ.PY - adds a BSP tree to a solid object (M S) for 3Dreams
#
#   python BSPOBJ.PY OBJ\06CLAUDE.OBJ            (rewrites the file)
#   python BSPOBJ.PY input.OBJ output.OBJ
#
# The BSP tree gives the engine the exact drawing order of the faces (from
# back to front) whatever the viewing angle : no more flickering faces
# and no more back faces drawn on top.
# Faces crossed by a plane are split (new vertices).
#
# Adds to the file :
#   - the faces in node order (the faces of a node follow each other)
#   - one line per node :  T first_face face_count front back
#     (front/back = number of the child node, -1 = none ; node 0 = root)
#   the plane of a node is the one of its first face.

import sys, math

def load(path):
    head, V, F = [], [], []
    for line in open(path, encoding='latin-1'):
        s = line.split()
        if s and s[0].upper() == 'V':
            V.append([float(c) for c in s[1:4]])
        elif s and s[0].upper() == 'F':
            F.append((int(s[1]), [int(c) for c in s[2:]]))
        elif s and s[0].upper() == 'T':
            pass                                    # old tree : rebuilt
        else:
            head.append(line.rstrip('\r\n'))
    return head, V, F

def sub(a, b): return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def dot(a, b): return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]

class Builder:
    def __init__(self, V, F):
        self.V = [list(v) for v in V]
        self.faces = F                      # (colour, [indices])
        self.nodes = []                     # (faces, front, back)
        self.vcache = {}

    def plane(self, f):
        idx = f[1]
        v0, v1, v2 = (self.V[i] for i in idx[:3])
        n = cross(sub(v1, v0), sub(v2, v0))
        return n, dot(n, v0)

    def side(self, n, d, v):
        return dot(n, v) - d

    def newv(self, p):
        key = tuple(round(c) for c in p)
        if key not in self.vcache:
            self.vcache[key] = len(self.V)
            self.V.append(list(key))
        return self.vcache[key]

    def split(self, f, n, d, eps):
        col, idx = f
        front, back = [], []
        m = len(idx)
        for k in range(m):
            a, b = idx[k], idx[(k+1) % m]
            sa, sb = self.side(n, d, self.V[a]), self.side(n, d, self.V[b])
            if sa >= -eps: front.append(a)
            if sa <= eps: back.append(a)
            if (sa > eps and sb < -eps) or (sa < -eps and sb > eps):
                t = sa / (sa - sb)
                p = [self.V[a][c] + t*(self.V[b][c]-self.V[a][c]) for c in range(3)]
                vi = self.newv(p)
                front.append(vi); back.append(vi)
        def clean(L):
            out = []
            for i in L:
                if not out or out[-1] != i: out.append(i)
            if len(out) > 1 and out[0] == out[-1]: out.pop()
            return out
        front, back = clean(front), clean(back)
        def cap(L):
            if len(L) < 3: return []
            # first 3 vertices not aligned (the demo takes the normal from them)
            for k in range(len(L)):
                q = L[k:] + L[:k]
                c = cross(sub(self.V[q[1]], self.V[q[0]]), sub(self.V[q[2]], self.V[q[0]]))
                if dot(c, c) > 0.25: L = q; break
            else:
                return []
            if len(L) <= 8: return [(col, L)]
            return [(col, L[:8]), (col, [L[0]] + L[7:])]
        res_f, res_b = cap(front), cap(back)
        return res_f, res_b

    def classify(self, f, n, d, eps):
        s = [self.side(n, d, self.V[i]) for i in f[1]]
        if all(abs(x) <= eps for x in s): return 'on'
        if all(x >= -eps for x in s): return 'front'
        if all(x <= eps for x in s): return 'back'
        return 'span'

    def build(self, faces):
        if not faces: return -1
        # choice of the plane : the one that splits the fewest faces (and balances)
        best, bestk = None, 0
        cand = faces
        for c in cand:
            n, d = self.plane(c)
            ln = math.sqrt(dot(n, n)) or 1
            eps = 0.01 * ln
            nf = nb = ns = 0
            for g in faces:
                k = self.classify(g, n, d, eps)
                if k == 'front': nf += 1
                elif k == 'back': nb += 1
                elif k == 'span': ns += 1
            score = ns * 100 + abs(nf - nb)   # splitting is expensive
            if best is None or score < best: best, bestk = score, c
        n, d = self.plane(bestk)
        ln = math.sqrt(dot(n, n)) or 1
        eps = 0.01 * ln
        on, fr, bk = [], [], []
        for g in faces:
            if g is bestk:                      # non-planar face : keep it
                on.append(g); continue
            k = self.classify(g, n, d, eps)
            if k == 'on':
                on.append(g)
            elif k == 'front': fr.append(g)
            elif k == 'back': bk.append(g)
            else:
                a, b = self.split(g, n, d, eps)
                fr += a; bk += b
        # the 1st face of the node must carry the plane (bestk first)
        on.sort(key=lambda g: g is not bestk)
        me = len(self.nodes)
        self.nodes.append(None)
        nfront = self.build(fr)
        nback = self.build(bk)
        self.nodes[me] = (on, nfront, nback)
        return me

def main():
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src
    head, V, F = load(src)
    up = [h.split()[0].upper() for h in head if h.split()]
    if 'P' in up:
        sys.exit("object with several parts (P) : no BSP tree possible")
    if not any(h.split()[:2] in (['M', 'S'], ['m', 's'], ['M', 's'], ['m', 'S']) for h in head):
        sys.exit("BSP useless in mode T (transparent) : use M S")
    b = Builder(V, F)
    b.build(list(F))
    out_faces, tl = [], []
    for (on, fr, bk) in b.nodes:
        tl.append((len(out_faces), len(on), fr, bk))
        out_faces += on
    if len(b.V) > 256 or len(out_faces) > 400 or len(b.nodes) > 400:
        sys.exit(f'object too big after splitting : {len(b.V)} vertices, '
                 f'{len(out_faces)} faces, {len(b.nodes)} nodes')
    L = [h for h in head if not h.startswith('; BSP')]
    # header : V then F then T (N, M, L and comments are kept)
    L.insert(0, f'; BSP : {len(b.nodes)} nodes, {len(out_faces)} faces '
                f'({len(out_faces)-len(F)} pieces added by splitting), '
                f'{len(b.V)} vertices - generated by BSPOBJ.PY')
    L += [f'V {int(round(v[0]))} {int(round(v[1]))} {int(round(v[2]))}' for v in b.V]
    L += [f'F {c} ' + ' '.join(map(str, idx)) for c, idx in out_faces]
    L += [f'T {a} {n} {fr} {bk}' for a, n, fr, bk in tl]
    open(dst, 'w', newline='\r\n', encoding='latin-1').write('\n'.join(L) + '\n')
    print(f'{dst} : {len(b.nodes)} nodes, {len(out_faces)} faces '
          f'(+{len(out_faces)-len(F)}), {len(b.V)} vertices (+{len(b.V)-len(V)})')

if __name__ == '__main__':
    main()
