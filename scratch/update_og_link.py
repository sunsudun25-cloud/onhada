import io

for filename in ["index.html", "app.html"]:
    with io.open(filename, "r", encoding="utf-8") as f:
        c = f.read()
    
    # Replace OG image link
    old_link = u"https://sunsudun25-cloud.github.io/onhada/전시관 입구.png"
    new_link = u"https://sunsudun25-cloud.github.io/onhada/onhada_og_banner.png"
    
    if old_link in c:
        c = c.replace(old_link, new_link)
        print(f"Updated og:image link in {filename} successfully.")
    else:
        print(f"Warning: old og:image link not found in {filename}.")
        
    with io.open(filename, "w", encoding="utf-8") as f:
        f.write(c)

print("Finished updating OG links!")
