# syntax=docker/dockerfile:1
# Stage 1: install Flask into the system site-packages with uv (the -dev image
# ships uv pre-installed). Stage 2 then copies the populated site-packages
# directory into the shell-less runtime python image — same Python minor
# version on both sides keeps the packages compatible.
ARG CHAINGUARD_ORG=smalls.xyz

FROM cgr.dev/${CHAINGUARD_ORG}/python:3.14-dev AS build
USER 0
WORKDIR /app
COPY pyproject.toml ./
RUN uv pip install --system --no-cache flask

FROM cgr.dev/${CHAINGUARD_ORG}/python:3.14
COPY --from=build /usr/lib/python3.14/site-packages /usr/lib/python3.14/site-packages
COPY app.py /app/app.py
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
