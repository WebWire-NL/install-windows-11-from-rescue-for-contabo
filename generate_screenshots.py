from PIL import Image, ImageDraw, ImageFont
import os

os.makedirs('docs/screenshots', exist_ok=True)

try:
    font = ImageFont.truetype('arial.ttf', 20)
    font_bold = ImageFont.truetype('arialbd.ttf', 24)
except Exception:
    font = ImageFont.load_default()
    font_bold = ImageFont.load_default()

size = (1280, 720)


def make_window(title, subtitle, lines, filename):
    img = Image.new('RGB', size, '#f3f3f3')
    draw = ImageDraw.Draw(img)
    margin = 80
    inner = (margin, margin, size[0]-margin, size[1]-margin)
    draw.rectangle(inner, fill='#ffffff', outline='#d0d0d0', width=2)
    title_rect = (inner[0], inner[1], inner[2], inner[1]+90)
    draw.rectangle(title_rect, fill='#0f4c81')
    draw.text((inner[0]+20, inner[1]+18), title, font=font_bold, fill='#ffffff')
    draw.text((inner[0]+20, inner[1]+55), subtitle, font=font, fill='#e5f0ff')
    content_top = inner[1]+110
    draw.text((inner[0]+30, content_top), 'Instructions:', font=font_bold, fill='#111111')
    y = content_top + 40
    for line in lines:
        draw.text((inner[0]+40, y), line, font=font, fill='#1b1b1b')
        y += 36
    box = (inner[0]+40, content_top+260, inner[2]-40, content_top+460)
    draw.rectangle(box, fill='#eef3fb', outline='#aac5e0', width=2)
    items = [
        'X:\\sources\\virtio\\amd64\\w11',
        'X:\\sources\\virtio\\viostor\\2k3\\amd64',
        'X:\\sources\\virtio\\NetKVM\\2k3\\amd64',
    ]
    for i, item in enumerate(items):
        draw.text((box[0]+18, box[1]+18+i*40), item, font=font, fill='#0f1f3b')
    btn1 = (inner[2]-260, box[3]+30, inner[2]-160, box[3]+78)
    btn2 = (inner[2]-140, box[3]+30, inner[2]-40, box[3]+78)
    draw.rectangle(btn1, fill='#f3f3f3', outline='#a0a0a0')
    draw.rectangle(btn2, fill='#0f4c81', outline='#0f4c81')
    draw.text((btn1[0]+18, btn1[1]+18), 'Browse', font=font, fill='#111111')
    draw.text((btn2[0]+20, btn2[1]+18), 'Next', font=font, fill='#ffffff')
    img.save(filename)

make_window(
    'Windows 11 Setup',
    'Load driver',
    [
        'Select the driver source containing VirtIO storage drivers.',
        'Choose the folder path and press Next.',
        'If necessary, use the driver from the installer media.',
    ],
    'docs/screenshots/load_driver.png'
)

make_window(
    'Windows 11 Setup',
    'Browse Driver Folder',
    [
        'Navigate to the installer media folder containing VirtIO drivers.',
        'Most commonly use:',
        '    sources\\virtio\\amd64\\w11',
        'Or fallback to:',
        '    sources\\virtio\\viostor\\2k3\\amd64',
    ],
    'docs/screenshots/choose_virtio_path.png'
)

img = Image.new('RGB', size, '#181818')
draw = ImageDraw.Draw(img)
header = (60, 60, size[0]-60, 160)
draw.rectangle(header, fill='#2b2b2b', outline='#4a4a4a', width=2)
draw.text((80, 72), 'Windows Setup', font=font_bold, fill='#ffffff')
draw.text((80, 112), 'Command Prompt - Shift+F10', font=font, fill='#d0d0d0')
text_y = 200
lines = [
    'D:\\sources\\bypass.cmd',
    '',
    '1. Press Shift+F10 to open command prompt.',
    '2. Find the installer media drive letter.',
    '3. Run the bypass script from the sources folder.',
    '',
    'Command:',
    '    cd D:\\sources',
    '    bypass.cmd',
]
for line in lines:
    draw.text((80, text_y), line, font=font, fill='#f0f0f0')
    text_y += 40
img.save('docs/screenshots/run_bypass.png')
print('Images generated.')
