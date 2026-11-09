# a56 .OUT (lines "P addr word") -> DSP binary blocks (Dsp_ExecProg / Simplet's loader format)
# format : type (0=P 1=X 2=Y), address, count, words... ; 3 bytes per word
import sys
mem={'P':{}, 'X':{}, 'Y':{}}
for l in open(sys.argv[1]):
    s=l.split()
    if len(s)==3 and s[0] in mem:
        mem[s[0]][int(s[1],16)]=int(s[2],16)
out=[]
for t,sp in enumerate('PXY'):
    m=mem[sp]; ad=sorted(m); i=0
    while i<len(ad):
        j=i
        while j+1<len(ad) and ad[j+1]==ad[j]+1: j+=1
        out+= [t, ad[i], j-i+1] + [m[a] for a in ad[i:j+1]]
        i=j+1
b=b''.join((w & 0xffffff).to_bytes(3,'big') for w in out)
open(sys.argv[2],'wb').write(b)
print(sys.argv[2], len(out), 'DSP words')
