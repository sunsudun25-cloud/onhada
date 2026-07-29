import io

with io.open("app.html", "r", encoding="utf-8") as f:
    c = f.read()

idx = c.find("<header class=\"app-header\">")
if idx != -1:
    print(c[idx:idx+1200])
else:
    print("header not found")
