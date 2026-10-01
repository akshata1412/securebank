from flask import Flask, render_template_string

app = Flask(__name__)

HOME_PAGE = """
<!DOCTYPE html>
<html>
<head>
    <title>SecureBank</title>
    <style>
        body { font-family: sans-serif; background: #0F1B2D; color: #F4EFE6; text-align: center; padding: 60px; }
        h1 { font-size: 54px; margin-bottom: 10px; }
        .tagline { color: #C5583E; font-size: 18px; }
        .status { margin-top: 40px; padding: 20px; background: #1A2942; border-radius: 8px; display: inline-block; }
    </style>
</head>
<body>
    <h1>🏦 SecureBank</h1>
    <p class="tagline">Cloud-native banking platform</p>
    <div class="status">
        <p>Status: Phase 1 — Foundation</p>
        <p>Deployed on: AWS EC2 (coming soon)</p>
    </div>
</body>
</html>
"""

@app.route("/")
def home():
    return render_template_string(HOME_PAGE)

@app.route("/health")
def health():
    return {"status": "healthy", "service": "securebank"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
