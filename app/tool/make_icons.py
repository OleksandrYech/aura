"""Иконки AURA для Web, Android и iOS из знака «сфера» (как AuraLogo в app/lib/screens/auth.dart).

Запуск из папки app: python3 tool/make_icons.py  (нужен Pillow)
"""
from pathlib import Path
from PIL import Image, ImageDraw

TILE = (0x40, 0x3B, 0x55)  # Ink: тёмная плитка, на ней пастельные круги видны и в светлой, и в тёмной теме
DOTS = [  # cx, cy, r в системе 120×120, цвет
    (50, 46, 30, (0xE6, 0xE6, 0xFA, 255)),  # Lavender
    (68, 66, 23, (0xD8, 0xBF, 0xD8, 255)),  # Thistle
    (58, 56, 8, (0xBD, 0xB5, 0xD5, 255)),  # GrayPurple
    (40, 37, 6, (0xFF, 0xFF, 0xF0, 153)),  # Cream 60%
]


def icon(size, mark=0.72, radius=0.0, alpha=True, tile=True):
    """mark — доля стороны под знак, radius — скругление плитки (0 — квадрат на всю площадь), tile=False — знак без плитки."""
    k = 4  # рисуем крупнее и уменьшаем: гладкие края
    n = size * k
    img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if tile:
        d.rounded_rectangle((0, 0, n - 1, n - 1), radius=radius * n, fill=TILE + (255,))
    s = n * mark / 120
    off = (n - 120 * s) / 2
    for cx, cy, r, color in DOTS:
        layer = Image.new('RGBA', (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse((off + (cx - r) * s, off + (cy - r) * s, off + (cx + r) * s, off + (cy + r) * s), fill=color)
        img = Image.alpha_composite(img, layer)
    img = img.resize((size, size), Image.LANCZOS)
    return img if alpha else img.convert('RGB')


def save(img, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)


# Web
save(icon(32, mark=0.85, radius=0.2), 'web/favicon.png')
for n in (192, 512):
    save(icon(n, radius=0.27), f'web/icons/Icon-{n}.png')
    save(icon(n, mark=0.6), f'web/icons/Icon-maskable-{n}.png')

# Android: обычная иконка для старых версий и адаптивная (фон + знак) для Android 8+
res = 'android/app/src/main/res'
for dpi, m in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
    save(icon(int(48 * m), radius=0.27), f'{res}/mipmap-{dpi}/ic_launcher.png')
    save(icon(int(108 * m), mark=0.6, tile=False),  # знак в безопасной зоне 66 из 108
          f'{res}/mipmap-{dpi}/ic_launcher_foreground.png')

# iOS: квадрат без прозрачности, скругляет система
ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
for f in Path(ios).glob('Icon-App-*.png'):
    pt, scale = f.stem.removeprefix('Icon-App-').split('@')
    save(icon(round(float(pt.split('x')[0]) * int(scale[:-1])), alpha=False), f)
