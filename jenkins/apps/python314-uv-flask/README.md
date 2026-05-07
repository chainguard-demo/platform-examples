# python314-uv-flask

Hello-world Flask web app on Chainguard's Python 3.14, with `uv` as the package manager. The pipeline's archived artifact is an OCI image pushed to `ttl.sh/smalls-pytest:3-14` — not a file checked into Jenkins' archive store.

> `$CHAINGUARD_ORG` below stands in for your configured Chainguard org — see the top-level [README](../../README.md#configuration) for how that gets set.

## Pipeline images

| Stage       | Image |
|-------------|-------|
| Build deps  | `cgr.dev/$CHAINGUARD_ORG/python:3.14-dev` (ships `uv` pre-installed) |
| Image build | host docker daemon (multi-stage build) |
| Test        | runs the just-built image |
| Push        | `ttl.sh/smalls-pytest:3-14` |

The runtime image (final stage of the Dockerfile) is the shell-less `cgr.dev/$CHAINGUARD_ORG/python:3.14`. Site-packages from the build stage are copied across — same Python minor version on both sides keeps the packages compatible.

## Smoke test

Because the runtime image has no shell, the Test stage runs the image with `--entrypoint=python` and an in-process Flask test client (`from app import app; app.test_client().get('/')`). This avoids any need to open a port, set up cross-container networking, or install HTTP tools in the runtime image.

## Pull and run

```sh
docker pull ttl.sh/smalls-pytest:3-14
docker run --rm -p 8080:8080 ttl.sh/smalls-pytest:3-14
# Visit http://localhost:8080/
```

Note: ttl.sh tags expire (default 24 hours). Re-run the pipeline to refresh.
