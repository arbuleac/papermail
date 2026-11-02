import math, itertools, sys
sys.path.insert(0,'.')
from colorlib import *
def lab2rgb(L,a,b):
    fy=(L+16)/116; fx=fy+a/500; fz=fy-b/200
    def finv(t): return t**3 if t**3>216/24389 else (116*t-16)/(24389/27)
    X=0.95047*finv(fx); Y=finv(fy); Z=1.08883*finv(fz)
    r= 3.2404542*X-1.5371385*Y-0.4985314*Z
    g=-0.9692660*X+1.8760108*Y+0.0415560*Z
    bb=0.0556434*X-0.2040259*Y+1.0572252*Z
    out=(r,g,bb)
    if any(c< -0.001 or c>1.001 for c in out): return None
    return tuple(delin(max(0,min(1,c))) for c in out)
def lch(L,C,h): return lab2rgb(L,C*math.cos(math.radians(h)),C*math.sin(math.radians(h)))
