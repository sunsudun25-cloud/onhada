import io
import os
from PIL import Image, ImageDraw, ImageFont

bg_path = r"C:\Users\내pc\.gemini\antigravity\brain\0785c1fd-5555-4a31-afcf-461388e13b3d\onhada_portal_bg_1785332036722.png"
out_path = r"c:\Users\내pc\Desktop\on하다 웹사이트\onhada_og_banner.png"

# Load background
img = Image.open(bg_path).convert("RGBA")
width, height = img.size

# Transparent text layer
text_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(text_layer)

# Draw central navy backdrop card to pop the text
draw.rounded_rectangle(
    [width * 0.12, height * 0.22, width * 0.88, height * 0.78],
    radius=25,
    fill=(9, 9, 22, 180), # Dark Translucent Navy
    outline=(255, 215, 0, 80), # Soft Gold Outline
    width=2
)

# Load fonts
font_dir = r"C:\Windows\Fonts"
title_font_path = os.path.join(font_dir, "malgunbd.ttf")
sub_font_path = os.path.join(font_dir, "malgun.ttf")

if not os.path.exists(title_font_path):
    title_font_path = "arial.ttf"
if not os.path.exists(sub_font_path):
    sub_font_path = "arial.ttf"

# Load TrueType fonts
try:
    title_font = ImageFont.truetype(title_font_path, 80)
    sub_font = ImageFont.truetype(sub_font_path, 30)
except Exception:
    title_font = ImageFont.load_default()
    sub_font = ImageFont.load_default()

title_text = "ONHADA"
sub_text = "기술이 세대를 연결하는 연합 전시 플랫폼"

# Text bounds
title_bbox = draw.textbbox((0, 0), title_text, font=title_font)
title_w = title_bbox[2] - title_bbox[0]
title_h = title_bbox[3] - title_bbox[1]

sub_bbox = draw.textbbox((0, 0), sub_text, font=sub_font)
sub_w = sub_bbox[2] - sub_bbox[0]
sub_h = sub_bbox[3] - sub_bbox[1]

# Calculations
title_x = (width - title_w) / 2
title_y = (height - title_h) / 2 - 45

sub_x = (width - sub_w) / 2
sub_y = title_y + title_h + 40

# Render glow and text
draw.text((title_x + 3, title_y + 3), title_text, fill=(138, 43, 226, 120), font=title_font) # Purple drop shadow glow
draw.text((title_x, title_y), title_text, fill=(255, 215, 0, 255), font=title_font) # Crisp Gold Text

# Render subtitle
draw.text((sub_x + 1, sub_y + 1), sub_text, fill=(0, 0, 0, 160), font=sub_font) # Black drop shadow
draw.text((sub_x, sub_y), sub_text, fill=(255, 255, 255, 255), font=sub_font) # Pure White Text

# Composite and Save
final_img = Image.alpha_composite(img, text_layer).convert("RGB")
final_img.save(out_path, "PNG")
print("Saved final banner image successfully at:", out_path)
