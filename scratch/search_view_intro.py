import io

with io.open("app.html", "r", encoding="utf-8") as f:
    c = f.read()

idx = c.find("id=\"view-intro\"")
if idx != -1:
    print("Found view-intro HTML:")
    print(c[idx-50:idx+650])
else:
    print("view-intro NOT FOUND!")
