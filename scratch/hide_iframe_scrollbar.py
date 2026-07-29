import io

with io.open("index.html", "r", encoding="utf-8") as f:
    content = f.read()

scrollbar_hide_css = u'''
    /* Hide scrollbar completely for seamless iframe embedding */
    html::-webkit-scrollbar, body::-webkit-scrollbar {
      width: 0px !important;
      height: 0px !important;
      background: transparent !important;
    }
    html, body {
      scrollbar-width: none !important;
      -ms-overflow-style: none !important;
    }
'''

if "<style>" in content:
    content = content.replace("<style>", "<style>" + scrollbar_hide_css)
    print("Injected scrollbar hiding styles into index.html.")
else:
    print("Warning: <style> tag not found in index.html")

with io.open("index.html", "w", encoding="utf-8") as f:
    f.write(content)

print("Update complete!")
