"""Layers, captions and the shot list for the promo; writes timeline.json and renders it with ./render."""
import json, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from cards import backdrop, font, W, H

OUT = 'satchel-promo-v2.mp4'

# ---------- image helpers ----------
def text_png(text, size, weight, color, name, pad=24):
    f = font(size, weight)
    tmp = ImageDraw.Draw(Image.new('RGBA', (10, 10)))
    box = tmp.textbbox((0, 0), text, font=f)
    w, h = box[2] - box[0] + 2 * pad, box[3] - box[1] + 2 * pad
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((pad - box[0], pad - box[1]), text, font=f, fill=color)
    p = f'layers/{name}.png'; img.save(p); return p, w, h

def icon_png(path, size, name, label=None, shadow=True, margin=60):
    ic = Image.open(path).convert('RGBA').resize((size, size), Image.LANCZOS)
    lab_h = 90 if label else 0
    img = Image.new('RGBA', (size + 2 * margin, size + 2 * margin + lab_h), (0, 0, 0, 0))
    if shadow:
        m = Image.new('L', ic.size, 0)
        ImageDraw.Draw(m).rounded_rectangle((0, 0, size, size), size * 0.22, fill=150)
        sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
        sh.paste((0, 0, 0, 255), (margin, margin + size // 14), m)
        img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(size // 14)))
    img.alpha_composite(ic, (margin, margin))
    if label:
        d = ImageDraw.Draw(img); f = font(42, 'Medium'); w = d.textlength(label, font=f)
        d.text(((img.width - w) / 2, size + margin + 28), label, font=f, fill=(222, 216, 208, 255))
    p = f'layers/{name}.png'; img.save(p); return p, img.width, img.height

def bg_png(name):
    p = f'layers/{name}.png'; backdrop().save(p); return p

def lens_assets(name, w, h, m=36, radius=34):
    """Mask, shadow and border for a magnifier: an inner w x h rounded rectangle inside a canvas with margin m."""
    w, h = int(round(w)), int(round(h))
    cw, ch = w + 2 * m, h + 2 * m
    mask = Image.new('L', (cw, ch), 0)
    ImageDraw.Draw(mask).rounded_rectangle((m, m, m + w, m + h), radius, fill=255)
    mask.convert('RGB').save(f'layers/{name}_mask.png')
    sh = Image.new('RGBA', (cw, ch), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((m, m + 14, m + w, m + h + 14), radius, fill=(0, 0, 0, 150))
    sh = sh.filter(ImageFilter.GaussianBlur(18)); sh.save(f'layers/{name}_shadow.png')
    ring = Image.new('RGBA', (cw, ch), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle((m, m, m + w, m + h), radius, outline=(255, 255, 255, 235), width=5)
    ring.save(f'layers/{name}_ring.png')
    return cw, ch

def caption(name):  # cards.pill/chips wrote these already
    p = f'{name}.png'; im = Image.open(p); return p, im.width, im.height

# ---------- overlays ----------
def cap(name, t0, t1, anim='slideUp'):
    p, w, h = caption(name)
    return dict(kind='image', png=p, rect=[0, H - h - 14, 0, 0], t0=t0, t1=t1, anim=anim)

def lens(name, src, dest, t0, t1, m=36):
    """src: [x, y, w, h] region of the cropped frame; dest: [x, y, w] where the magnified picture sits."""
    sx, sy, sw, sh = src
    k = dest[2] / sw
    dh = sh * k
    cw, ch = lens_assets(name, dest[2], dh, m)
    msrc = m / k
    return dict(kind='lens', t0=t0, t1=t1, anim='pop', rect=[dest[0] - m, dest[1] - m, cw, ch],
                lensSrc=[sx - msrc, sy - msrc, sw + 2 * msrc, sh + 2 * msrc],
                mask=f'layers/{name}_mask.png', frame=f'layers/{name}_shadow.png', ring=f'layers/{name}_ring.png')

def clip(src, ss, to, speed, cam, overlays=(), top=True, transition=None):
    cams = [dict(t=c[0], zoom=c[1], u=c[2], v=c[3], ease=(c[4] if len(c) > 4 else None)) for c in cam]
    shot = dict(kind='clip', src=f'{src}.mov', ss=ss, speed=speed, cropTop=66 if top else 133,
                dur=round((to - ss) / speed, 3), cam=cams, overlays=list(overlays))
    if transition: shot['transition'] = dict(kind=transition[0], dur=transition[1])
    return shot

def card(bg, layers, dur, transition=None):
    shot = dict(kind='card', bg=bg, dur=dur, layers=layers)
    if transition: shot['transition'] = dict(kind=transition[0], dur=transition[1])
    return shot

# ---------- title, extension, outro ----------
bg = bg_png('bg')
ic, iw, ih = icon_png('assets/satchel.png', 380, 'icon_big')
t1, t1w, t1h = text_png('Satchel', 150, 'Bold', (250, 246, 240, 255), 'title')
t2, t2w, t2h = text_png("Your secrets. Your Mac. Nobody else's.", 54, 'Regular', (201, 195, 188, 255), 'tagline')
title = card(bg, [
    dict(png=ic, x=(W - iw) / 2, y=170, t0=0.15, anim='spring', dur=0.8),
    dict(png=t1, x=(W - t1w) / 2, y=610, t0=0.55, anim='slideUp'),
    dict(png=t2, x=(W - t2w) / 2, y=815, t0=0.95, anim='slideUp')], 2.7)

h1, h1w, h1h = text_png('Your browser fills it in.', 96, 'Bold', (250, 246, 240, 255), 'ext_head')
h2, h2w, h2h = text_png('Logins from your own vault, nothing in the cloud.', 46, 'Regular', (201, 195, 188, 255), 'ext_sub')
h3, h3w, h3h = text_png('The Satchel extension', 40, 'Medium', (247, 194, 122, 255), 'ext_tag')
browsers = [('Dia', 'Dia'), ('Arc', 'Arc'), ('GoogleChrome', 'Chrome'), ('Firefox', 'Firefox')]
ext_layers = [dict(png=h1, x=(W - h1w) / 2, y=130, t0=0.05, anim='slideUp'), dict(png=h2, x=(W - h2w) / 2, y=265, t0=0.3, anim='slideUp')]
size, gap = 230, 70
tot = len(browsers) * (size + 120) + (len(browsers) - 1) * gap
x0 = (W - tot) / 2
for i, (f, label) in enumerate(browsers):
    p, w, h = icon_png(f'assets/{f}.png', size, f'br_{f}', label)
    ext_layers.append(dict(png=p, x=x0 + i * (w + gap), y=400, t0=0.5 + 0.14 * i, anim='spring', dur=0.7))
ext_layers.append(dict(png=h3, x=(W - h3w) / 2, y=860, t0=1.35, anim='slideUp'))
ext = card(bg, ext_layers, 2.9, ('zoom', 0.35))

ic2, i2w, i2h = icon_png('assets/satchel.png', 300, 'icon_small')
o1, o1w, o1h = text_png('Free. Open source. Yours.', 104, 'Bold', (250, 246, 240, 255), 'out_head')
o2, o2w, o2h = text_png('github.com/bilalesi/satchel', 58, 'Medium', (247, 194, 122, 255), 'out_url')
o3, o3w, o3h = text_png('macOS 15 or later  ·  signed updates', 40, 'Regular', (160, 154, 148, 255), 'out_note')
outro = card(bg, [
    dict(png=ic2, x=(W - i2w) / 2, y=120, t0=0.1, anim='spring', dur=0.8),
    dict(png=o1, x=(W - o1w) / 2, y=540, t0=0.5, anim='slideUp'),
    dict(png=o2, x=(W - o2w) / 2, y=700, t0=0.85, anim='slideUp'),
    dict(png=o3, x=(W - o3w) / 2, y=800, t0=1.15, anim='slideUp')], 3.5, ('dissolve', 0.5))

# ---------- the shots ----------
shots = [
    title,
    clip('tourA', 3.6, 9.8, 3.0, [(0, 1.0, .5, .5), (2.07, 1.5, .28, .4, 'expo')], [cap('cap_tour1', .3, 1.9)], transition=('zoom', .4)),
    clip('tourA', 10.8, 13.8, 1.0, [(0, 1.0, .5, .45), (.7, 1.8, .5, .10, 'expo'), (2.3, 1.8, .5, .12), (3.0, 1.25, .5, .42)],
         [cap('cap_tour2', .5, 2.9)], transition=('whipLeft', .35)),
    clip('tourA', 15.0, 31.6, 5.0, [(0, 1.1, .30, .35), (1.7, 1.25, .56, .45), (3.32, 1.15, .36, .56)], [cap('cap_tour3', .3, 3.0)], transition=('slideLeft', .35)),
    clip('iconsG', 3.8, 20.5, 5.5, [(0, 1.55, .12, .18), (3.04, 1.55, .12, .72)], [cap('cap_icons', .25, 2.8)], transition=('slideUp', .35)),
    clip('iconsG', 23.2, 31.6, 3.5, [(0, 1.7, .05, .2), (2.4, 1.7, .05, .34)], [cap('cap_rail', .2, 2.2)], transition=('whipLeft', .3)),
    clip('syncB', 4.7, 7.6, 3.0, [(0, 1.0, .5, .5), (.97, 1.8, .5, .3, 'expo')], [cap('cap_sync1', .1, .95)], transition=('zoom', .35)),
    clip('syncB', 9.0, 15.0, 2.0, [(0, 1.75, .56, .34), (3.0, 1.95, .62, .43)], [cap('cap_sync2', .2, 2.9)], transition=('slideLeft', .3)),
    clip('syncB', 15.6, 24.6, 4.5, [(0, 1.7, .55, .40), (2.0, 1.6, .55, .46)], transition=('slideLeft', .3)),
    clip('syncB', 27.3, 31.3, 1.6, [(0, 1.4, .5, .3), (.6, 1.9, .5, .09, 'expo'), (1.8, 1.9, .5, .1), (2.5, 1.5, .62, .4)], [cap('cap_sync3', .3, 2.4)], transition=('dissolve', .25)),
    clip('selectiveF', 3.0, 7.4, 2.0, [(0, 1.0, .5, .5), (2.2, 1.45, .22, .3, 'expo')],
         [cap('cap_sel1', .3, 2.1), lens('lens_locks', [640, 214, 620, 180], [900, 470, 980], 1.0, 2.15)], transition=('whipLeft', .35)),
    clip('selectiveF', 7.6, 14.4, 2.0, [(0, 1.7, .74, .12), (3.4, 1.8, .72, .16)], [cap('cap_sel2', .3, 3.3)], transition=('slideLeft', .3)),
    clip('selectiveF', 14.8, 22.8, 2.5, [(0, 1.4, .45, .3), (1.6, 1.75, .72, .15), (3.2, 1.4, .3, .35)], [cap('cap_sel3', .3, 3.1)], transition=('slideLeft', .3)),
    clip('selectiveF', 27.3, 34.5, 3.0, [(0, 1.8, .5, .55), (2.4, 1.8, .5, .62)], [cap('cap_sel4', .2, 2.3)], transition=('zoom', .35)),
    clip('updateD', 8.6, 11.6, 1.0, [(0, 1.0, .5, .35), (.6, 1.9, .5, .09, 'expo'), (3.0, 1.9, .5, .10)], [cap('cap_upd1', .4, 2.9)], transition=('whipLeft', .35)),
    clip('updateD', 14.4, 20.4, 3.5, [(0, 1.5, .14, .9), (1.7, 1.6, .12, .8)], [cap('cap_upd2', .2, 1.7)], top=False, transition=('slideLeft', .3)),
    clip('customC', 4.2, 17.0, 3.8, [(0, 1.6, .16, .22), (3.4, 1.6, .16, .3)], [cap('cap_cus1', .25, 3.2)], transition=('slideUp', .35)),
    clip('quickE', 4.3, 13.6, 3.0, [(0, 1.3, .12, .85), (1.0, 1.3, .12, .85), (1.5, 1.5, .5, .32, 'expo'), (3.1, 1.5, .5, .32)], [cap('cap_quick', .3, 3.0)], top=False, transition=('whipLeft', .35)),
    ext,
    outro,
]

timeline = dict(out=OUT, fps=60, shots=shots)
json.dump(timeline, open('timeline.json', 'w'), indent=1)
total = 0
for i, s in enumerate(shots):
    total += s['dur'] - (s.get('transition', {}).get('dur', 0) if i else 0)
print(f'{len(shots)} shots, about {total:.1f} s')
if len(sys.argv) > 1 and sys.argv[1] == 'render':
    subprocess.run(['./render', 'timeline.json'], check=True)
