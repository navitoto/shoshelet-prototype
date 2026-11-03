#!/usr/bin/env python3
"""Build emoji-catalog.js for Shoshelet: exact Emoji 15.0 fully-qualified set.
Inputs (download first, same directory):
  emoji-test-15.0.txt       https://unicode.org/Public/emoji/15.0/emoji-test.txt (UTS #51 keyboard data)
  cldr-he.json              CLDR annotations, Hebrew (unicode-org/cldr-json, cldr-annotations-full/annotations/he)
  cldr-he-territories.json  CLDR territory display names, Hebrew (cldr-localenames-full/main/he)
Output: emoji-catalog-new.js -> rename to emoji-catalog.js
"""

import json, re
GROUP_TO_CAT = {
 'Smileys & Emotion':'smileys','People & Body':'smileys',
 'Animals & Nature':'animals','Food & Drink':'food',
 'Travel & Places':'travel','Activities':'activity',
 'Objects':'objects','Symbols':'symbols','Flags':'flags'}
CATS=[('smileys','סמיילים','😀'),('animals','חיות וטבע','🐻'),('food','אוכל ושתייה','🍕'),
 ('travel','נסיעות ומקומות','✈️'),('activity','ספורט ותחביבים','⚽'),('objects','חפצים','💡'),
 ('symbols','סמלים','🔣'),('flags','דגלים','🏁')]
CATIDX={c[0]:i for i,c in enumerate(CATS)}
TONE_CPS={0x1F3FB,0x1F3FC,0x1F3FD,0x1F3FE,0x1F3FF}
TONE_ORDER=[0x1F3FB,0x1F3FC,0x1F3FD,0x1F3FE,0x1F3FF]
VS16=0xFE0F
RI=lambda c: 0x1F1E6<=c<=0x1F1FF
BASELESS={(0x1FAF1,0x200D,0x1FAF2):'🤝',(0x1F469,0x200D,0x1F91D,0x200D,0x1F469):'👭',
 (0x1F469,0x200D,0x1F91D,0x200D,0x1F468):'👫',(0x1F468,0x200D,0x1F91D,0x200D,0x1F468):'👬',
 (0x1F9D1,0x200D,0x2764,0x200D,0x1F48B,0x200D,0x1F9D1):'💏',
 (0x1F9D1,0x200D,0x2764,0x200D,0x1F9D1):'💑'}
cldr=json.load(open('cldr-he.json'))['annotations']['annotations']
terr=json.load(open('cldr-he-territories.json'))['main']['he']['localeDisplayNames']['territories']
def direct(ch):
    a=cldr.get(ch.replace('️','')) or cldr.get(ch)
    if not a: return None
    tts=a.get('tts',[''])[0] if a.get('tts') else ''
    kw=[k for k in (a.get('default') or []) if k!=tts]
    return tts+' '+' '.join(kw) if tts or kw else None
def keywords(seq,eng):
    d=direct(seq)
    if d: return d
    cps=[ord(c) for c in seq]
    if len(cps)==2 and all(RI(c) for c in cps):
        iso=''.join(chr(0x41+c-0x1F1E6) for c in cps)
        t=terr.get(iso)
        return ('דגל '+t+' ' if t else '')+eng
    if '‍' in seq:
        parts=[direct(comp) for comp in seq.split('‍')]
        parts=[p for p in parts if p]
        return (' '.join(parts)+' ' if parts else '')+eng
    return eng
entries=[];group=None
for line in open('emoji-test-15.0.txt',encoding='utf-8'):
    line=line.rstrip('\n')
    if line.startswith('# group:'): group=line.split(':',1)[1].strip(); continue
    if not line or line.startswith('#'): continue
    cps_s,rest=line.split(';',1)
    if rest.split('#')[0].strip()!='fully-qualified': continue
    name=rest.split('#',1)[1].strip()
    cps=[int(x,16) for x in cps_s.split()]
    entries.append((''.join(chr(c) for c in cps),cps,group,name))
def key(cps): return tuple(c for c in cps if c not in TONE_CPS and c!=VS16)
fams={}
for seq,cps,g,n in entries: fams.setdefault(key(cps),[]).append((seq,cps,g,n))
def tonekey(sc):
    t=[TONE_ORDER.index(c) for c in sc[1] if c in TONE_CPS]
    return (t[0],t[0]) if len(t)==1 else tuple(t)
items=[];tones={};baseless=[]
for k,members in fams.items():
    untoned=[m for m in members if not any(c in TONE_CPS for c in m[1])]
    toned=[m for m in members if any(c in TONE_CPS for c in m[1])]
    for seq,cps,g,n in untoned:
        eng=re.sub(r'^\S+ E[\d.]+ ','',n).lower()
        items.append([seq,CATIDX[GROUP_TO_CAT[g]],keywords(seq,eng)])
    if toned:
        if untoned: tones[untoned[0][0]]=[m[0] for m in sorted(toned,key=tonekey)]
        else: baseless.append((k,toned))
assert len(baseless)==6
for k,toned in baseless:
    combined=[(s,[ord(c) for c in s]) for s in tones.get(BASELESS[k],[])]+[(m[0],m[1]) for m in toned]
    tones[BASELESS[k]]=[s for s,c in sorted(combined,key=tonekey)]
out={'cats':[{'id':c,'label':l,'symbol':s} for c,l,s in CATS],'items':items,'tones':tones}
js='window.EMOJI_CATALOG='+json.dumps(out,ensure_ascii=False,separators=(',',':'))+';'
open('emoji-catalog-new.js','w',encoding='utf-8').write(js)
official={e[0] for e in entries}
itemset={i[0] for i in items}
mine=set(itemset)
for vs in tones.values(): mine.update(vs)
assert mine==official and all(b in itemset for b in tones)
from collections import Counter
import os
print('items:',len(items),'| tone groups:',len(tones),'| sizes:',Counter(len(v) for v in tones.values()))
print('selectable:',len(mine),'== official:',len(official),'| bytes:',os.path.getsize('emoji-catalog-new.js'))
