import io

with io.open("index.html", "r", encoding="utf-8") as f:
    c = f.read()

idx = c.find("<style>")
if idx != -1:
    print("Found style tag in index.html at index:", idx)
    print(c[idx:idx+350])
else:
    print("style tag not found")
