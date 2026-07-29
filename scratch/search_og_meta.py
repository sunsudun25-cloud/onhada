import io
import re

for filename in ["index.html", "app.html"]:
    with io.open(filename, "r", encoding="utf-8") as f:
        c = f.read()
    
    print(f"=== OG tags in {filename} ===")
    matches = re.findall(r'<meta property="og:.*?>|<meta name="twitter:.*?>', c)
    for m in matches:
        print(m)
