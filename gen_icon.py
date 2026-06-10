from PIL import Image
import os

SIZES = {
    'mipmap-mdpi':    48,
    'mipmap-hdpi':    72,
    'mipmap-xhdpi':   96,
    'mipmap-xxhdpi':  144,
    'mipmap-xxxhdpi': 192,
}

SRC_ICON = os.path.join(os.path.dirname(__file__), 'icon2.png')
BASE_DIR = os.path.join(os.path.dirname(__file__), 'android', 'app', 'src', 'main', 'res')

src = Image.open(SRC_ICON).convert('RGBA')

for folder, size in SIZES.items():
    out_dir = os.path.join(BASE_DIR, folder)
    os.makedirs(out_dir, exist_ok=True)
    resized = src.resize((size, size), Image.LANCZOS)
    # Save as RGB (no alpha) to match existing ic_launcher.png format
    resized.convert('RGB').save(os.path.join(out_dir, 'ic_launcher.png'))
    print(f'  {folder}/ic_launcher.png  ({size}x{size})')

print('Done.')
