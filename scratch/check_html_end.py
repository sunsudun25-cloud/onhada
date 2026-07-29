import io

with io.open("index.html", "r", encoding="utf-8") as f:
    c = f.read()

print("File length:", len(c))
print("Last 1500 chars:")
print(c[-1500:])
