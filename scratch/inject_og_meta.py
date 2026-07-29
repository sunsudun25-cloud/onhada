import io

meta_tags = u'''
  <!-- Open Graph / KakaoTalk Preview Meta Tags -->
  <meta property="og:title" content="ONHADA - 온하다 플랫폼">
  <meta property="og:description" content="기술이 세대를 연결하여 사회적 참여와 따뜻한 소통을 켜다(ON)">
  <meta property="og:image" content="https://sunsudun25-cloud.github.io/onhada/전시관 입구.png">
  <meta property="og:url" content="https://sunsudun25-cloud.github.io/onhada/">
  <meta property="og:type" content="website">
'''

# 1. Update index.html
with io.open("index.html", "r", encoding="utf-8") as f:
    content_index = f.read()

if "<head>" in content_index:
    content_index = content_index.replace("<head>", "<head>" + meta_tags)
    print("Injected OG meta tags into index.html head.")
else:
    print("Warning: <head> not found in index.html")

with io.open("index.html", "w", encoding="utf-8") as f:
    f.write(content_index)

# 2. Update app.html
with io.open("app.html", "r", encoding="utf-8") as f:
    content_app = f.read()

if "<head>" in content_app:
    content_app = content_app.replace("<head>", "<head>" + meta_tags)
    print("Injected OG meta tags into app.html head.")
else:
    print("Warning: <head> not found in app.html")

with io.open("app.html", "w", encoding="utf-8") as f:
    f.write(content_app)

print("OG injection script finished successfully!")
