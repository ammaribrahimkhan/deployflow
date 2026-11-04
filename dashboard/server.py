"""Dashboard entry point: the base dashboard plus the cost and resources feature.

Gunicorn runs `server:app`. Locally, run-local.ps1 runs `server.py`.
"""
import os
import threading
import webbrowser

import config
import cost
import main
from main import app

app.register_blueprint(cost.blueprint)


def run_local():
    port = int(os.environ.get("PORT", "8000"))

    threading.Thread(target=main.warm_up_tokens, daemon=True).start()

    if config.AUTH_MODE == "local":
        admin_link = "http://127.0.0.1:%d/login?token=%s" % (port, main.LOCAL_TOKENS["admin"])
        viewer_link = "http://127.0.0.1:%d/login?token=%s" % (port, main.LOCAL_TOKENS["viewer"])

        print("")
        print("DeployFlow dashboard (local mode)")
        print("  Admin sign-in link:  " + admin_link)
        print("  Viewer sign-in link: " + viewer_link)
        print("  Actions enabled: %s" % config.ACTIONS_ENABLED)
        print("")
        print("  Your browser opens by itself. Do NOT select text in this window:")
        print("  Windows pauses the program while text is selected (press Esc to resume).")
        print("  Stop the dashboard with Ctrl+C.")
        print("")

        if os.environ.get("DASHBOARD_OPEN_BROWSER", "true").lower() == "true":
            threading.Timer(2.0, webbrowser.open, args=[admin_link]).start()

    app.run(host="127.0.0.1", port=port, threaded=True, use_reloader=False)


if __name__ == "__main__":
    run_local()