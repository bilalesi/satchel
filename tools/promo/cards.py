"""Title, extension and outro cards, and the captions, as PNGs (1920x1080 cards, RGBA captions)."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math

W, H = 1920, 1080
FONT = '/System/Library/Fonts/SFNS.ttf'

def font(size, weight='Semibold'):
    f = ImageFont.truetype(FONT, size); f.set_variation_by_name(weight); return f

def backdrop():
    """Dark, with a warm glow where the icon sits (the leather of the icon)."""
    img = Image.new('RGB', (W, H), (12, 12, 14))
    glow = Image.new('RGB', (W, H), (0, 0, 0))
    d = ImageDraw.Draw(glow)
    cx, cy = W // 2, 400
    for r in range(760, 0, -8):
        t = 1 - r / 760
        d.ellipse((cx - r, cy - r * 0.8, cx + r, cy + r * 0.8), fill=(int(70 * t * t), int(40 * t * t), int(14 * t * t)))
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    return Image.blend(img, Image.eval(glow, lambda v: v), 1).convert('RGB') if False else Image.composite(img, img, Image.new('L', (W, H), 255)).point(lambda v: v) if False else _add(img, glow)

def _add(a, b):
    from PIL import ImageChops
    return ImageChops.add(a, b)

def paste_icon(img, path, cx, cy, size, shadow=True):
    ic = Image.open(path).convert('RGBA').resize((size, size), Image.LANCZOS)
    if shadow:
        sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        m = Image.new('L', (size, size), 0)
        ImageDraw.Draw(m).rounded_rectangle((0, 0, size, size), size * 0.22, fill=150)
        sh.paste((0, 0, 0, 255), (cx - size // 2, cy - size // 2 + size // 14), m)
        sh = sh.filter(ImageFilter.GaussianBlur(size // 14))
        img.paste(sh, (0, 0), sh)
    img.paste(ic, (cx - size // 2, cy - size // 2), ic)

def centered(d, text, y, f, fill):
    w = d.textlength(text, font=f)
    d.text(((W - w) / 2, y), text, font=f, fill=fill)

def title():
    img = backdrop()
    paste_icon(img, 'assets/satchel.png', W // 2, 380, 380)
    d = ImageDraw.Draw(img)
    centered(d, 'Satchel', 640, font(150, 'Bold'), (250, 246, 240))
    centered(d, "Your secrets. Your Mac. Nobody else's.", 830, font(54, 'Regular'), (201, 195, 188))
    img.save('card_title.png')

def outro():
    img = backdrop()
    paste_icon(img, 'assets/satchel.png', W // 2, 330, 300)
    d = ImageDraw.Draw(img)
    centered(d, 'Free. Open source. Yours.', 560, font(104, 'Bold'), (250, 246, 240))
    centered(d, 'github.com/bilalesi/satchel', 720, font(58, 'Medium'), (247, 194, 122))
    centered(d, 'macOS 15 or later  ·  signed updates', 820, font(40, 'Regular'), (160, 154, 148))
    img.save('card_outro.png')

def extension():
    img = backdrop()
    d = ImageDraw.Draw(img)
    centered(d, 'Your browser fills it in.', 190, font(96, 'Bold'), (250, 246, 240))
    centered(d, 'Logins from your own vault, nothing in the cloud.', 320, font(46, 'Regular'), (201, 195, 188))
    names = [('Dia', 'Dia'), ('Arc', 'Arc'), ('GoogleChrome', 'Chrome'), ('Firefox', 'Firefox')]
    gap, size = 120, 230
    total = len(names) * size + (len(names) - 1) * gap
    x0 = (W - total) // 2 + size // 2
    for i, (f, label) in enumerate(names):
        cx = x0 + i * (size + gap)
        paste_icon(img, f'assets/{f}.png', cx, 620, size)
        lf = font(42, 'Medium'); w = d.textlength(label, font=lf)
        d.text((cx - w / 2, 770), label, font=lf, fill=(222, 216, 208))
    # a small satchel badge on each browser: the extension's mark
    centered(d, 'The Satchel extension', 900, font(40, 'Medium'), (247, 194, 122))
    img.save('card_extension.png')

def pill(text, sub=None, name='cap'):
    """White text on a dark translucent rounded pill, centred."""
    f = font(58, 'Semibold'); sf = font(36, 'Regular')
    tmp = ImageDraw.Draw(Image.new('RGBA', (10, 10)))
    tw = tmp.textlength(text, font=f)
    sw = tmp.textlength(sub, font=sf) if sub else 0
    w = int(max(tw, sw) + 100); h = 104 + (56 if sub else 0)
    img = Image.new('RGBA', (w + 60, h + 60), (0, 0, 0, 0))
    sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((30, 40, 30 + w, 40 + h), 44, fill=(0, 0, 0, 120))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((30, 30, 30 + w, 30 + h), 44, fill=(14, 14, 18, 240))
    d.text((30 + (w - tw) / 2, 30 + 22), text, font=f, fill=(255, 255, 255, 255))
    if sub: d.text((30 + (w - sw) / 2, 30 + 94), sub, font=sf, fill=(210, 204, 196, 255))
    img.save(f'{name}.png')

def chips(labels, name):
    f = font(46, 'Semibold'); pad = 34; gap = 18
    tmp = ImageDraw.Draw(Image.new('RGBA', (10, 10)))
    widths = [int(tmp.textlength(t, font=f)) + 2 * pad for t in labels]
    w = sum(widths) + gap * (len(labels) - 1) + 60; h = 150
    img = Image.new('RGBA', (w + 60, h + 60), (0, 0, 0, 0))
    sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((30, 40, 30 + w, 40 + h), 44, fill=(0, 0, 0, 120))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((30, 30, 30 + w, 30 + h), 44, fill=(14, 14, 18, 240))
    x = 30 + 30
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    for t, cw in zip(labels, widths):
        ld.rounded_rectangle((x, 30 + 38, x + cw, 30 + 112), 37, fill=(255, 255, 255, 46))
        x += cw + gap
    img.alpha_composite(layer)          # blended: drawing a translucent fill would replace the pixels
    d = ImageDraw.Draw(img)
    x = 30 + 30
    for t, cw in zip(labels, widths):
        d.text((x + pad, 30 + 52), t, font=f, fill=(255, 255, 255, 255))
        x += cw + gap
    img.save(f'{name}.png')

if __name__ == '__main__':
    title(); outro(); extension()
    pill('Every secret. One place.', name='cap_tour1')
    pill('Separate workspaces. Separate passwords.', name='cap_tour2')
    pill('Logins, API keys, databases, SSH keys.', name='cap_tour3')
    pill('Sync to your own storage.', name='cap_sync1')
    chips(['Folder', 'GitHub', 'Git (SSH)', 'WebDAV', 'S3'], 'cap_sync2')
    pill('Finished? The notch tells you.', name='cap_sync3')
    pill('Signed updates. You decide.', name='cap_upd1')
    pill('A new version shows up in the menu.', name='cap_upd2')
    pill('Make it yours.', 'Icons and colours for every entry', name='cap_cus1')
    pill('Categories in seconds.', name='cap_cus2')
    pill('Quick Access, from anywhere.', '⌥ Space: find, copy, type', name='cap_quick')
    print('cards ok')
