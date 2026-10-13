# Subshot app icon — clapperboard with LED timecode (rebuilt as SVG, 1024 full bleed, opaque)
SEG = {"0":"abcdef","1":"bc","2":"abged","3":"abgcd","4":"fgbc","5":"afgcd","6":"afgedc","7":"abc","8":"abcdefg","9":"abcfgd"}
def digit(ch, x, y, w, h, t, skew=0.12, g=2.5):
    def sk(px,py): return (px + (y+h-py)*skew, py)
    def hbar(x0,y0,x1): return [(x0,y0),(x0+t/2,y0-t/2),(x1-t/2,y0-t/2),(x1,y0),(x1-t/2,y0+t/2),(x0+t/2,y0+t/2)]
    def vbar(x0,y0,y1): return [(x0,y0),(x0+t/2,y0+t/2),(x0+t/2,y1-t/2),(x0,y1),(x0-t/2,y1-t/2),(x0-t/2,y0+t/2)]
    L,R,T,M,B = x+t/2, x+w-t/2, y+t/2, y+h/2, y+h-t/2
    sh={"a":hbar(L+g,T,R-g),"g":hbar(L+g,M,R-g),"d":hbar(L+g,B,R-g),"f":vbar(L,T+g,M-g),"b":vbar(R,T+g,M-g),"e":vbar(L,M+g,B-g),"c":vbar(R,M+g,B-g)}
    return [("M"+" L".join(f"{sk(px,py)[0]:.1f},{sk(px,py)[1]:.1f}" for px,py in pts)+"Z", k in SEG[ch]) for k,pts in sh.items()]

W=1024
P=[]
P.append('''<defs>
<linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#38383b"/><stop offset="0.5" stop-color="#29292b"/><stop offset="1" stop-color="#1c1c1e"/></linearGradient>
<linearGradient id="clap" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1e1e20"/><stop offset="1" stop-color="#0f0f10"/></linearGradient>
<linearGradient id="white" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fafafa"/><stop offset="1" stop-color="#dcdcde"/></linearGradient>
<linearGradient id="plate" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#77777c"/><stop offset="0.6" stop-color="#5a5a5f"/><stop offset="1" stop-color="#424246"/></linearGradient>
<radialGradient id="rivet" cx="0.4" cy="0.35" r="0.7"><stop offset="0" stop-color="#85858b"/><stop offset="0.6" stop-color="#5a5a60"/><stop offset="1" stop-color="#36363a"/></radialGradient>
<linearGradient id="led" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0e0e0f"/><stop offset="1" stop-color="#060607"/></linearGradient>
<pattern id="grain" width="1024" height="6" patternUnits="userSpaceOnUse"><rect width="1024" height="1.2" fill="#ffffff" opacity="0.022"/></pattern>
<filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<filter id="soft" x="-10%" y="-10%" width="130%" height="140%"><feDropShadow dx="2" dy="5" stdDeviation="6" flood-color="#000" flood-opacity="0.5"/></filter>
<linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.10"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<clipPath id="clapclip"><rect x="0" y="0" width="1024" height="326"/></clipPath>
</defs>''')
P.append(f'<rect width="{W}" height="{W}" fill="url(#body)"/><rect width="{W}" height="{W}" fill="url(#grain)"/>')
# clapper: arm 0..164, seam, stick 170..326 — white chevrons ">" across both
P.append('<g clip-path="url(#clapclip)"><rect x="0" y="0" width="1024" height="326" fill="url(#clap)"/>')
per, wc, shift = 290, 148, 116
for k in range(-1,5):
    x0 = 150 + k*per
    P.append(f'<polygon points="{x0},0 {x0+wc},0 {x0+wc+shift},164 {x0+shift},164" fill="url(#white)"/>')
    P.append(f'<polygon points="{x0+shift},170 {x0+wc+shift},170 {x0+wc},326 {x0},326" fill="url(#white)"/>')
P.append('<rect x="0" y="0" width="1024" height="164" fill="url(#hl)"/>')
P.append('<rect x="0" y="0" width="1024" height="3" fill="#ffffff" opacity="0.10"/>')
P.append('<rect x="0" y="163" width="1024" height="7" fill="#0a0a0b"/><rect x="0" y="170" width="1024" height="2" fill="#ffffff" opacity="0.09"/>')
P.append('</g>')
P.append('<rect x="0" y="325" width="1024" height="6" fill="#0b0b0c"/><rect x="0" y="331" width="1024" height="3" fill="#ffffff" opacity="0.07"/>')
# hinge plate (smaller, like the original): top edge to ~168, diagonal down to ~256, rounded bottom-right
P.append('<path d="M0,0 L150,0 Q172,0 182,20 L262,232 Q272,262 262,290 Q252,318 222,318 L0,318 Z" fill="url(#plate)" filter="url(#soft)"/>')
P.append('<path d="M0,1.5 L150,1.5 Q172,1.5 182,21 L262,232" fill="none" stroke="#ffffff" stroke-opacity="0.20" stroke-width="3"/>')
for cx,cy in ((80,98),(58,262),(190,262)):
    P.append(f'<circle cx="{cx+1}" cy="{cy+3}" r="23" fill="#000" opacity="0.35"/><circle cx="{cx}" cy="{cy}" r="21" fill="url(#rivet)"/><circle cx="{cx-6}" cy="{cy-6}" r="5.5" fill="#fff" opacity="0.18"/>')
# labels
for x,t in ((204,"Hr"),(512,"Min"),(820,"Sec")):
    P.append(f'<text x="{x}" y="438" text-anchor="middle" font-family="Helvetica Neue, Arial, sans-serif" font-size="38" font-weight="500" fill="#8a8a8f">{t}</text>')
# LED windows + fine red 7-segment digits
for (x,val) in ((82,"03"),(390,"54"),(698,"28")):
    w,h,y=244,176,462
    P.append(f'<rect x="{x}" y="{y+5}" width="{w}" height="{h}" rx="9" fill="#000" opacity="0.5"/>')
    P.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="9" fill="url(#led)" stroke="#38383b" stroke-width="3"/>')
    dw,dh,gap,t=56,104,26,9
    total=2*dw+gap
    sx=x+(w-total)/2-5; sy=y+(h-dh)/2
    on=[];off=[]
    for i,ch in enumerate(val):
        for d,o in digit(ch, sx+i*(dw+gap), sy, dw, dh, t):
            (on if o else off).append(d)
    P.append('<g fill="#ff2d20" opacity="0.06">'+"".join(f'<path d="{d}"/>' for d in off)+'</g>')
    P.append('<g fill="#ff3b30" filter="url(#glow)">'+"".join(f'<path d="{d}"/>' for d in on)+'</g>')
ln='stroke="#4b4b4f" stroke-width="5" stroke-linecap="round"'
P.append(f'<line x1="82" y1="712" x2="942" y2="712" {ln}/><line x1="82" y1="830" x2="640" y2="830" {ln}/><line x1="82" y1="946" x2="942" y2="946" {ln}/><line x1="644" y1="716" x2="644" y2="946" {ln}/>')
P.append('<rect x="0" y="334" width="1024" height="110" fill="url(#hl)" opacity="0.55"/>')
svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">'+"".join(P)+'</svg>'
open("icon.svg","w").write(svg)
open("icon.html","w").write('<html><body style="margin:0;background:#000">'+svg+'</body></html>')
