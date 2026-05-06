"""
Single-file Django demo app — keeps the project shape minimal for a hello-world
container. Run `python app.py` to serve on 0.0.0.0:8080 (Django's runserver).
"""
import os
import platform
import sys
from django.conf import settings
from django.core.management import execute_from_command_line
from django.http import HttpResponse
from django.urls import path

settings.configure(
    DEBUG=False,
    SECRET_KEY="demo-not-secret",
    ROOT_URLCONF=__name__,
    ALLOWED_HOSTS=["*"],
    INSTALLED_APPS=["django.contrib.contenttypes", "django.contrib.auth"],
    MIDDLEWARE=[],
    DATABASES={},
    USE_TZ=True,
)


def hello(request):
    import django
    body = (
        "<h1>Hello from Django on Chainguard</h1>"
        "<h2>Runtime info</h2>"
        "<table border='1' cellpadding='4'>"
        "<tr><th>property</th><th>value</th></tr>"
        f"<tr><td>django.version</td><td>{django.get_version()}</td></tr>"
        f"<tr><td>python.version</td><td>{platform.python_version()}</td></tr>"
        f"<tr><td>python.implementation</td><td>{platform.python_implementation()}</td></tr>"
        f"<tr><td>os.name</td><td>{platform.system()}</td></tr>"
        f"<tr><td>os.arch</td><td>{platform.machine()}</td></tr>"
        f"<tr><td>HOSTNAME</td><td>{os.environ.get('HOSTNAME', '?')}</td></tr>"
        "</table>"
    )
    return HttpResponse(body)


urlpatterns = [path("", hello)]


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.argv.extend(["runserver", "0.0.0.0:8080", "--noreload"])
    execute_from_command_line(sys.argv)
