# python312-pip-django

Hello-world Django site on Chainguard's Python 3.12, with `pip` as the package manager. The pipeline's archived artifact is an OCI image pushed to `$PUSH_REGISTRY/pytest:3-12`.

> `$CHAINGUARD_ORG` below stands in for your configured Chainguard org — see the top-level [README](../../README.md#configuration) for how that gets set.

## Pipeline images

| Stage       | Image |
|-------------|-------|
| Build deps  | `cgr.dev/$CHAINGUARD_ORG/python:3.12-dev` |
| Image build | host docker daemon (multi-stage build) |
| Test        | runs the just-built image |
| Push        | `$PUSH_REGISTRY/pytest:3-12` |

## Single-file Django

The whole site is one `app.py` — `settings.configure()` instead of a `settings.py`, one URL pattern, one view. This keeps the demo focused on packaging+containerization rather than Django project scaffolding. `python app.py` defaults to `runserver 0.0.0.0:8080 --noreload`.

## Smoke test

Same trick as the Flask sibling: the runtime image is shell-less, so the Test stage runs the image with `--entrypoint=python` and exercises the Django **test client** (`Client().get('/')`) in-process. No port exposure, no network plumbing.

## Pull and run

```sh
docker pull $PUSH_REGISTRY/pytest:3-12
docker run --rm -p 8080:8080 $PUSH_REGISTRY/pytest:3-12
# Visit http://localhost:8080/
```

If `$PUSH_REGISTRY` points at ttl.sh (Modes A/B), tags expire after the default 24 hours — re-run the pipeline to refresh. In Mode C the push goes to the local Harbor (`localhost/library/...`) and persists until teardown.
