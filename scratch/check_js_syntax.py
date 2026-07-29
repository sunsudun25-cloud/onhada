import io

with io.open("app.html", "r", encoding="utf-8") as f:
    content = f.read()

# Extract script blocks
import re
scripts = re.findall(r'<script>(.*?)</script>', content, re.DOTALL)
print(f"Found {len(scripts)} script blocks.")

for i, script in enumerate(scripts):
    print(f"Block {i} length: {len(script)}")
    # Check braces balance
    open_braces = script.count("{")
    close_braces = script.count("}")
    print(f"Braces: {open_braces} open, {close_braces} close")
    if open_braces != close_braces:
        print("ERROR: Braces are UNBALANCED!")
        # Let's find where it might be unbalanced
        
    # Check parentheses balance
    open_parens = script.count("(")
    close_parens = script.count(")")
    print(f"Parentheses: {open_parens} open, {close_parens} close")
    if open_parens != close_parens:
        print("ERROR: Parentheses are UNBALANCED!")

    # Check brackets balance
    open_brackets = script.count("[")
    close_brackets = script.count("]")
    print(f"Brackets: {open_brackets} open, {close_brackets} close")
    if open_brackets != close_brackets:
        print("ERROR: Brackets are UNBALANCED!")
