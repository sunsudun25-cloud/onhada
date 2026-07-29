import io

with io.open("app.html", "r", encoding="utf-8") as f:
    c = f.read()

idx_start = c.find('<div id="view-intro" class="app-view">')
idx_end = c.find('<!-- VIEW 5:', idx_start)

if idx_start != -1 and idx_end != -1:
    # Find the closing </div> of view-intro before that comment
    idx_div = c.rfind('</div>', idx_start, idx_end)
    new_html = u'''<div id="view-intro" class="app-view">
        <iframe src="index.html" style="width: 100%; height: 82vh; border: none; border-radius: 30px; background: #050510; box-shadow: 0 0 40px rgba(0,0,0,0.5);" allowfullscreen></iframe>
      </div>

      '''
    c = c[:idx_start] + new_html + c[idx_div + 6:]
    print("Embedded index.html in view-intro successfully!")
else:
    print("Could not find start or end index for view-intro!")

with io.open("app.html", "w", encoding="utf-8") as f:
    f.write(c)

print("Update complete!")
