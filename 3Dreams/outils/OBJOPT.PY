# OBJOPT.PY - optimises a 3Dreams object (OBJ\*.OBJ) : fewer faces, fewer
# vertices, same look.
#
#   python OBJOPT.PY OBJ\08CLAUDE.OBJ              (rewrites the file)
#   python OBJOPT.PY input.OBJ output.OBJ
#
#   - two faces in the same plane, of the same colour, sharing an edge are
#     merged when the result stays convex with 8 vertices at most (the DSP
#     and the 030 cost mostly per face : fewer faces = faster) ;
#   - a vertex in the middle of a straight edge, used by that face only,
#     is removed ; unused vertices too ;
#   - texture coordinates (W) follow their vertices (only faces whose
#     shared vertices have the same u,v are merged) ;
#   - the BSP tree (T lines) is rebuilt as BSPOBJ.PY does (W kept).
import sys, math

def sub(a, b): return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def dot(a, b): return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]

def load(path):
    head, tail, V, F = [], [], [], []
    for line in open(path, encoding='latin-1'):
        line = line.rstrip('\r\n')
        s = line.split()
        k = s[0].upper() if s else ''
        if k == 'V':
            V.append([float(c) for c in s[1:4]])
        elif k == 'F':
            F.append([int(s[1]), [int(c) for c in s[2:]], None])
        elif k == 'W':
            uv = [int(c) for c in s[1:]]
            F[-1][2] = [(uv[2*i], uv[2*i+1]) for i in range(len(uv)//2)]
        elif k == 'T':
            pass
        elif k == 'E':
            tail.append(line)
        else:
            head.append(line)
    return head, tail, V, F

def newell(V, idx):
    n = [0.0, 0.0, 0.0]
    for i in range(len(idx)):
        a, b = V[idx[i]], V[idx[(i+1) % len(idx)]]
        n[0] += (a[1]-b[1])*(a[2]+b[2]); n[1] += (a[2]-b[2])*(a[0]+b[0]); n[2] += (a[0]-b[0])*(a[1]+b[1])
    l = math.sqrt(dot(n, n)) or 1
    n = [c/l for c in n]
    return n, dot(n, V[idx[0]])

def convex(V, idx, n):
    m = len(idx)
    for i in range(m):
        a, b, c = V[idx[i]], V[idx[(i+1) % m]], V[idx[(i+2) % m]]
        if dot(cross(sub(b, a), sub(c, b)), n) < -1e-6: return False
    return len(set(idx)) == m

def collinear(V, a, b, c):
    x = cross(sub(V[b], V[a]), sub(V[c], V[b]))
    return dot(x, x) < 1e-6

def first3(V, f):
    # the engine takes the normal from the first 3 vertices : not aligned
    col, idx, uv = f
    for k in range(len(idx)):
        if not collinear(V, idx[k], idx[(k+1) % len(idx)], idx[(k+2) % len(idx)]):
            idx = idx[k:] + idx[:k]
            if uv: uv = uv[k:] + uv[:k]
            return [col, idx, uv]
    return None

def merge_all(V, F):
    F = [list(f) for f in F]
    changed = True
    while changed:
        changed = False
        edges = {}
        for fi, f in enumerate(F):
            idx = f[1]
            for i in range(len(idx)):
                edges[(idx[i], idx[(i+1) % len(idx)])] = fi
        best = None
        for (a, b), fi in edges.items():
            gj = edges.get((b, a))
            if gj is None or gj <= fi: continue
            f, g = F[fi], F[gj]
            if f[0] != g[0] or (f[2] is None) != (g[2] is None): continue
            nf, df = newell(V, f[1]); ng, dg = newell(V, g[1])
            if dot(nf, ng) < 0.9995 or abs(df - dg) > 0.5: continue
            # f : ... a b ... ; g : ... b a ... -> merged : f from b round to a, then g after a to before b
            i = f[1].index(b); fa = f[1][i:] + f[1][:i]        # b ... a
            j = g[1].index(a); ga = g[1][j:] + g[1][:j]        # a ... b
            idx = fa + ga[1:-1]
            if f[2]:
                uvf = dict(zip(f[1], f[2])); uvg = dict(zip(g[1], g[2]))
                if uvf[a] != uvg[a] or uvf[b] != uvg[b]: continue
                uv = [uvf[v] if v in uvf else uvg[v] for v in idx]
            else:
                uv = None
            if not convex(V, idx, nf): continue
            # drop the aligned vertices used by this face only
            cnt = {}
            for k, h in enumerate(F):
                if k in (fi, gj): continue
                for v in h[1]: cnt[v] = cnt.get(v, 0) + 1
            k = 0
            while k < len(idx) and len(idx) > 3:
                p, v, q = idx[k-1], idx[k], idx[(k+1) % len(idx)]
                if cnt.get(v, 0) == 0 and collinear(V, p, v, q):
                    del idx[k]
                    if uv: del uv[k]
                    k = 0
                else:
                    k += 1
            if len(idx) > 8: continue
            m = first3(V, [f[0], idx, uv])
            if m is None: continue
            gain = len(f[1]) + len(g[1]) - len(idx)
            if best is None or gain > best[0]:
                best = (gain, fi, gj, m)
        if best:
            _, fi, gj, m = best
            F[fi] = m
            del F[gj]
            changed = True
    return F

def compact(V, F, tail):
    used = sorted(set(v for f in F for v in f[1]) |
                  set(int(c) for e in tail for c in e.split()[1:3]))
    remap = {o: n for n, o in enumerate(used)}
    V2 = [V[o] for o in used]
    F2 = [[f[0], [remap[v] for v in f[1]], f[2]] for f in F]
    T2 = []
    for e in tail:
        s = e.split()
        T2.append(f'E {remap[int(s[1])]} {remap[int(s[2])]}')
    return V2, F2, T2

# --- BSP (as BSPOBJ.PY, the texture coordinates follow) ---
class Builder:
    def __init__(self, V):
        self.V = [list(v) for v in V]; self.nodes = []; self.vcache = {}
    def plane(self, f):
        v0, v1, v2 = (self.V[i] for i in f[1][:3])
        n = cross(sub(v1, v0), sub(v2, v0))
        return n, dot(n, v0)
    def newv(self, p):
        key = tuple(round(c) for c in p)
        if key not in self.vcache:
            self.vcache[key] = len(self.V); self.V.append(list(key))
        return self.vcache[key]
    def classify(self, f, n, d, eps):
        s = [dot(n, self.V[i]) - d for i in f[1]]
        if all(abs(x) <= eps for x in s): return 'on'
        if all(x >= -eps for x in s): return 'front'
        if all(x <= eps for x in s): return 'back'
        return 'span'
    def split(self, f, n, d, eps):
        col, idx, uv = f
        fr, bk = [], []
        m = len(idx)
        for k in range(m):
            a, b = idx[k], idx[(k+1) % m]
            ua = uv[k] if uv else None; ub = uv[(k+1) % m] if uv else None
            sa, sb = dot(n, self.V[a]) - d, dot(n, self.V[b]) - d
            if sa >= -eps: fr.append((a, ua))
            if sa <= eps: bk.append((a, ua))
            if (sa > eps and sb < -eps) or (sa < -eps and sb > eps):
                t = sa / (sa - sb)
                p = [self.V[a][c] + t*(self.V[b][c]-self.V[a][c]) for c in range(3)]
                vi = self.newv(p)
                uvi = (round(ua[0]+t*(ub[0]-ua[0])), round(ua[1]+t*(ub[1]-ua[1]))) if uv else None
                fr.append((vi, uvi)); bk.append((vi, uvi))
        def mk(L):
            out = []
            for e in L:
                if not out or out[-1][0] != e[0]: out.append(e)
            if len(out) > 1 and out[0][0] == out[-1][0]: out.pop()
            if len(out) < 3: return []
            res = []
            parts = [out] if len(out) <= 8 else [out[:8], [out[0]] + out[7:]]
            for P in parts:
                g = first3(self.V, [col, [e[0] for e in P], [e[1] for e in P] if uv else None])
                if g: res.append(g)
            return res
        return mk(fr), mk(bk)
    def build(self, faces):
        if not faces: return -1
        best, bestk = None, None
        for c in faces:
            n, d = self.plane(c); eps = 0.01 * (math.sqrt(dot(n, n)) or 1)
            nf = nb = ns = 0
            for g in faces:
                k = self.classify(g, n, d, eps)
                if k == 'front': nf += 1
                elif k == 'back': nb += 1
                elif k == 'span': ns += 1
            score = ns * 100 + abs(nf - nb)
            if best is None or score < best: best, bestk = score, c
        n, d = self.plane(bestk); eps = 0.01 * (math.sqrt(dot(n, n)) or 1)
        on, fr, bk = [], [], []
        for g in faces:
            if g is bestk: on.append(g); continue
            k = self.classify(g, n, d, eps)
            if k == 'on': on.append(g)
            elif k == 'front': fr.append(g)
            elif k == 'back': bk.append(g)
            else:
                a, b = self.split(g, n, d, eps); fr += a; bk += b
        on.sort(key=lambda g: g is not bestk)
        me = len(self.nodes); self.nodes.append(None)
        nfr = self.build(fr); nbk = self.build(bk)
        self.nodes[me] = (on, nfr, nbk)
        return me

def main():
    src = sys.argv[1]; dst = sys.argv[2] if len(sys.argv) > 2 else src
    head, tail, V, F = load(src)
    hadT = any(l.split()[:1] in (['T'], ['t']) for l in open(src, encoding='latin-1'))
    nv0, nf0 = len(V), len(F)
    F = merge_all(V, F)
    V, F, tail = compact(V, F, tail)
    nodes = []
    if hadT:
        b = Builder(V); b.build(list(F))
        out, tl = [], []
        for (on, fr, bk) in b.nodes:
            tl.append((len(out), len(on), fr, bk)); out += on
        V, F, nodes = b.V, out, tl
    if len(V) > 256 or len(F) > 400:
        sys.exit(f'object too big : {len(V)} vertices, {len(F)} faces')
    L = [h for h in head if not h.startswith('; BSP') and not h.startswith('; OBJOPT')]
    L.insert(0, f'; OBJOPT : {nv0} -> {len(V)} vertices, {nf0} -> {len(F)} faces'
                + (f', BSP {len(nodes)} nodes' if hadT else ''))
    L += [f'V {int(round(v[0]))} {int(round(v[1]))} {int(round(v[2]))}' for v in V]
    for c, idx, uv in F:
        L.append(f'F {c} ' + ' '.join(map(str, idx)))
        if uv: L.append('W ' + ' '.join(f'{u} {v}' for u, v in uv))
    L += tail
    L += [f'T {a} {n} {fr} {bk}' for a, n, fr, bk in nodes]
    open(dst, 'w', newline='\r\n', encoding='latin-1').write('\n'.join(L) + '\n')
    print(f'{dst} : {nv0} -> {len(V)} vertices, {nf0} -> {len(F)} faces'
          + (f', {len(nodes)} BSP nodes' if hadT else ''))

if __name__ == '__main__':
    main()
