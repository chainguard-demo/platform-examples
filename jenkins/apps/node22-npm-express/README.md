# node22-npm-express

Hello-world Express web app on Chainguard's Node 22, with `npm` as the package manager. Pipeline artifact is an OCI image pushed to `ttl.sh/smalls-nodetest:22`.

> Note: PLAN.md originally called for Node 21, but that line is EOL and not in the smalls.xyz catalog. We use Node 22 LTS (the natural successor) instead.

## Pipeline images

| Stage       | Image |
|-------------|-------|
| Build deps  | `cgr.dev/smalls.xyz/node:22-dev` (ships `npm`) |
| Image build | host docker daemon (multi-stage build) |
| Test        | runs the just-built image |
| Push        | `ttl.sh/smalls-nodetest:22` |

## npm libraries used

- `express` (web server)
- `picocolors` (terminal coloring for the startup banner — included to satisfy PLAN.md's "include some kind of npm library" requirement with something visibly small and fun)

## Smoke test

The runtime image is shell-less (just `/usr/bin/node`), so the Test stage runs the image with `--entrypoint=/usr/bin/node` and an inline `-e` script that:

1. `require()`s the express app
2. binds to an ephemeral loopback port
3. issues a self-`http.get('/')`
4. asserts status 200 + greeting present
5. exits

This avoids opening any host port or routing across docker networks.

## Pull and run

```sh
docker pull ttl.sh/smalls-nodetest:22
docker run --rm -p 8080:8080 ttl.sh/smalls-nodetest:22
# Visit http://localhost:8080/
```

ttl.sh tags expire (default 24 hours). Re-run the pipeline to refresh.
