import os
import platform
import sys
from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/")
def index():
    return (
        "<h1>Hello from Flask on Chainguard</h1>"
        "<h2>Runtime info</h2>"
        "<table border='1' cellpadding='4'>"
        f"<tr><th>property</th><th>value</th></tr>"
        f"<tr><td>python.version</td><td>{platform.python_version()}</td></tr>"
        f"<tr><td>python.implementation</td><td>{platform.python_implementation()}</td></tr>"
        f"<tr><td>os.name</td><td>{platform.system()}</td></tr>"
        f"<tr><td>os.arch</td><td>{platform.machine()}</td></tr>"
        f"<tr><td>HOSTNAME</td><td>{os.environ.get('HOSTNAME', '?')}</td></tr>"
        "</table>"
    )


@app.route("/healthz")
def healthz():
    return jsonify(status="ok", python=sys.version.split()[0])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
