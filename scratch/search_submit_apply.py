import io

with io.open("app.html", "r", encoding="utf-8") as f:
    c = f.read()

idx = c.find("function submitPlatformApply()")
if idx != -1:
    print(c[idx:idx+800])
else:
    print("submitPlatformApply not found")
