"""Original geometric status artwork; no third-party image inputs.

Run: uv run --with pillow generate.py
80px files target a 20px Slack context-image slot (4x density).
"""
from pathlib import Path
import math
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent
SCALE = 4
SIZE = 20 * SCALE
FRAMES = 24
BLUE = (59, 130, 246)

dot = Image.new('RGBA', (SIZE, SIZE))
ImageDraw.Draw(dot).ellipse((24, 24, 55, 55), fill=BLUE + (255,))
dot.save(OUT / 'completed-dot.png', optimize=True)
(OUT / 'completed-dot.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><circle cx="10" cy="10" r="4" fill="#3b82f6"/></svg>\n')

def spinner_frame(frame):
    im = Image.new('RGBA', (SIZE, SIZE))
    draw = ImageDraw.Draw(im)
    for i in range(24):
        angle = 2 * math.pi * i / 24 - math.pi / 2
        age = (frame - i) % 24
        shade = round(110 + 70 * (1 - age / 23))
        center = (39.5 + 19 * math.cos(angle), 39.5 + 19 * math.sin(angle))
        draw.ellipse((center[0]-2.5, center[1]-2.5, center[0]+2.5, center[1]+2.5), fill=(shade,shade,shade,255))
    return im

def gif_frame(im):
    # One transparent palette entry; no opaque background/matte.
    pal = im.convert('RGB').quantize(colors=255)
    pal.paste(255, mask=im.getchannel('A').point(lambda a: 255 if a < 128 else 0))
    pal.info['transparency'] = 255
    return pal

spinner = [spinner_frame(i) for i in range(FRAMES)]
spinner[0].save(OUT / 'working-spinner-frame.png', optimize=True)
gif = [gif_frame(im) for im in spinner]
gif[0].save(OUT / 'working-spinner.gif', save_all=True, append_images=gif[1:], duration=50, loop=0, transparency=255, disposal=2, optimize=False)

# Two-theme local scale study, not a Slack screenshot. Text uses 13px at 2x.
font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 26)
bold = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 26)
previews = []
for frame in spinner:
    sheet = Image.new('RGB', (1200, 320))
    draw = ImageDraw.Draw(sheet)
    for left, bg, fg, heading, chip, chipfg in [
        (0, '#202124', '#e6e6e6', 'Dark appearance', '#69520d', '#f4d976'),
        (600, '#ffffff', '#303030', 'Light appearance', '#fff0ba', '#755d00')]:
        draw.rectangle((left,0,left+599,319), fill=bg)
        draw.text((left+32,24),heading,font=bold,fill=fg)
        for y,label,icon in [(86,'Working',frame),(150,'Completed',dot)]:
            scaled = icon.resize((40,40), Image.Resampling.LANCZOS)
            sheet.paste(scaled,(left+28,y),scaled)
            draw.text((left+76,y+5),label,font=font,fill=fg)
        draw.rounded_rectangle((left+32,224,left+177,262),radius=6,fill=chip)
        draw.text((left+40,228),'Needs input',font=font,fill=chipfg)
    previews.append(sheet)
previews[0].save(OUT / 'size-preview.png', optimize=True)
previews[0].save(OUT / 'size-preview.gif',save_all=True,append_images=previews[1:],duration=50,loop=0,optimize=True)
for name in ('completed-dot.png','working-spinner.gif'):
    path=OUT/name
    with Image.open(path) as im:
        print(f'{name}: {im.size}, {getattr(im,"n_frames",1)} frame(s), {path.stat().st_size} bytes')
