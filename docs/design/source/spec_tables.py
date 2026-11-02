import sys, itertools; sys.path.insert(0,'.')
from colorlib import *
from tokens import *
import contrast as CT
ML={'light':'Light','dark':'Dark','lightIC':'Light IC','darkIC':'Dark IC'}
def fmt(v):
    if isinstance(v,tuple): return '`%s` @ %g%%'%(v[0],round(v[1]*100,1))
    return '`%s`'%v
def color_table():
    groups=[('Surfaces',['spine','paper','canvas','sheet','raised','slip']),
            ('Ink',['ink','ink2','ink3','inkDisabled','onSlip','onSlip2']),
            ('Rules and washes',['rule','ruleStrong','hover','pressed','fill','scrim']),
            ('Iron Gall: accent, selection, focus',['accent','accentHover','accentPressed','onAccent','accentWash','focus','selWash','selRule','selWashIdle','selRuleIdle']),
            ('Marks and semantics',['star','success','warning','danger','info','successWash','warningWash','dangerWash','infoWash','dangerFill','onDanger'])]
    out=[]
    for g,toks in groups:
        out.append('\n**%s**\n\n| Token | Light | Dark | Light IC | Dark IC | Use |\n|---|---|---|---|---|---|'%g)
        for t in toks:
            out.append('| `q.%s` | %s |'%(t,' | '.join(fmt(C[t][m]) for m in MODES)+' | '+C[t]['note']))
    return '\n'.join(out)
def account_table():
    out=['| # | Ink | Light | Dark | Light IC | Dark IC |','|---|---|---|---|---|---|']
    for i,a in enumerate(ACCOUNTS):
        out.append('| %d | %s | `%s` | `%s` | `%s` | `%s` |'%(i+1,a[0],a[1],a[2],a[3],a[4]))
    return '\n'.join(out)
def cvd_table():
    kinds=['normal','protan','deutan','tritan']
    out=['| Mode | Normal | Protanopia | Deuteranopia | Tritanopia | Worst CVD pair | Min CVD ΔE for the first k accounts (k = 2…10) |','|---|---|---|---|---|---|---|']
    for mi,m in enumerate(MODES):
        cols={a[0]:hex2rgb(a[1+mi])[0] for a in ACCOUNTS}
        names=[a[0] for a in ACCOUNTS]
        labs={n:{k:rgb2lab(simulate(cols[n],k)) for k in kinds} for n in names}
        mins={}
        for k in kinds:
            mins[k]=min((de2000(labs[a][k],labs[b][k]),a,b) for a,b in itertools.combinations(names,2))
        worst=min((min(de2000(labs[a][k],labs[b][k]) for k in kinds[1:]),a,b) for a,b in itertools.combinations(names,2))
        cum=[min(min(de2000(labs[a][k],labs[b][k]) for k in kinds[1:]) for a,b in itertools.combinations(names[:j],2)) for j in range(2,11)]
        out.append('| %s | %.1f | %.1f | %.1f | %.1f | %s / %s (%.1f) | %s |'%(ML[m],mins['normal'][0],mins['protan'][0],mins['deutan'][0],mins['tritan'][0],worst[1],worst[2],worst[0],' · '.join('%.0f'%x for x in cum)))
    return '\n'.join(out)
def avatar_table():
    out=['| Tint | Light face / ink | Dark face / ink | Light IC face / ink | Dark IC face / ink |','|---|---|---|---|---|']
    for av in AVATARS:
        out.append('| %s | `%s` / `%s` | `%s` / `%s` | `%s` / `%s` | `%s` / `%s` |'%av)
    return '\n'.join(out)
def type_table():
    out=['| Role | Family | Size (pt) | Weight | Line height (pt) | Tracking (pt) | Used for |','|---|---|---|---|---|---|---|']
    for r,f,s,w,l,t,u in TYPE:
        out.append('| `%s` | %s | %s | %s | %s | %+.1f | %s |'%(r,f,s if s else '0.42 × avatar','%s'%w,l if l else '1.0 × size',t,u))
    return '\n'.join(out)
def contrast_table():
    rows,fails=CT.run()
    out=['| Pair | Foreground | Background | Need | Light | Dark | Light IC | Dark IC |','|---|---|---|---|---|---|---|---|']
    for what,fg,bg,th,r in rows:
        fgs=fg.replace('acct:','account.') if fg else ''
        out.append('| %s | `%s` | `%s` | %.1f | %s |'%(what,fgs,bg.replace('+',' + '),th,' | '.join('%.2f'%x for x in r)))
    out.append('\nAll %d pairs pass in all four modes (%d failures). Lowest margins: %s.'%(len(rows),len(fails),
        '; '.join('%s %.2f (%s)'%(w,min(r),ML[MODES[r.index(min(r))]]) for w,fg,bg,th,r in sorted(rows,key=lambda x:min(x[4])/x[3])[:5])))
    return '\n'.join(out)
def css_block():
    import build
    return build.tokens_css()
T={'{{COLOR_TABLE}}':color_table,'{{ACCOUNT_TABLE}}':account_table,'{{CVD_TABLE}}':cvd_table,'{{AVATAR_TABLE}}':avatar_table,'{{TYPE_TABLE}}':type_table,'{{CONTRAST_TABLE}}':contrast_table}
if __name__=='__main__':
    for k,f in T.items(): print(k); print(f()[:600]); print()
