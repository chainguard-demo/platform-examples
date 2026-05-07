# syntax=docker/dockerfile:1
# Stage 1: install Django into the system site-packages with pip. The default
# uid (65532) on python:3.12-dev can't write there, so switch to root for the
# install. Stage 2 then copies the populated site-packages into the shell-less
# python:3.12 runtime image — same Python minor version on both sides keeps
# the packages compatible.
ARG CHAINGUARD_ORG

FROM cgr.dev/${CHAINGUARD_ORG}/python:3.12-dev AS build
USER 0
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

FROM cgr.dev/${CHAINGUARD_ORG}/python:3.12
COPY --from=build /usr/lib/python3.12/site-packages /usr/lib/python3.12/site-packages
COPY app.py /app/app.py
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["python", "/app/app.py"]
