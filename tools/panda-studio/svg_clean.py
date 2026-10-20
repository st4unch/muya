import re, sys
from xml.etree import ElementTree as ET
ET.register_namespace('', 'http://www.w3.org/2000/svg')
NS = '{http://www.w3.org/2000/svg}'
s = open(sys.argv[2] if len(sys.argv) > 2 else 'bamboo.svg').read()   # the 4.1.12 panda: git show e34775b:src/assets/panda/bamboo.svg
s = re.sub(r'<style>.*?</style>', '', s, flags=re.S)
root = ET.fromstring(s)
DROP = set(sys.argv[1].split(',')) if len(sys.argv) > 1 else set()
seen = {}
def walk(el, parent):
    for ch in list(el):
        cls = ch.get('class', '')
        names = [c for c in cls.split() if c != 'j']
        if any(n in DROP for n in names):
            el.remove(ch); continue
        if names:
            n = names[0]; seen[n] = seen.get(n, 0) + 1
            ch.set('id', n if seen[n] == 1 else f'{n}_{seen[n]}')
        if 'class' in ch.attrib: del ch.attrib['class']
        if 'style' in ch.attrib: del ch.attrib['style']
        walk(ch, el)
walk(root, None)
open('panda_parts.svg', 'w').write(ET.tostring(root, encoding='unicode'))
print(seen)
