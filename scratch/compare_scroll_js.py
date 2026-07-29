import io

with io.open("app.html", "r", encoding="utf-8") as f:
    app_content = f.read()

with io.open("index.backup-before-copy-polish.html", "r", encoding="utf-8") as f:
    backup_content = f.read()

# Extract window.addEventListener('scroll') block from both
import re
app_scroll = re.search(r"window\.addEventListener\('scroll'.*?\}\);", app_content, re.DOTALL)
backup_scroll = re.search(r"window\.addEventListener\('scroll'.*?\}\);", backup_content, re.DOTALL)

print("App scroll matches:")
if app_scroll:
    print(app_scroll.group(0)[:1500])
else:
    print("Not found in app.html")

print("\nBackup scroll matches:")
if backup_scroll:
    print(backup_scroll.group(0)[:1500])
else:
    print("Not found in backup")
