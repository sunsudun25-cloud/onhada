import io

with io.open("app.html", "r", encoding="utf-8") as f:
    c = f.read()

print("Contains openExternalIframeModal:", "openExternalIframeModal" in c)
print("Count of openExternalIframeModal:", c.count("openExternalIframeModal"))
print("Contains matchedHall.externalUrl:", "matchedHall.externalUrl" in c)
print("Contains iframe-modal-overlay:", "iframe-modal-overlay" in c)
