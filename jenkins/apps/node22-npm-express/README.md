# node22-npm-express

Hello-world Express web app on Chainguard's Node 22, with `npm` as the package manager. Pipeline artifact is an OCI image pushed to `$PUSH_REGISTRY/nodetest:22`.

> `$CHAINGUARD_ORG` below stands in for your configured Chainguard org — see the top-level [README](../../README.md#configuration) for how that gets set.

> Why Node 22 and not 21? Node 21 is EOL and not in the Chainguard catalog; 22 is the current LTS and the natural successor.

## Pipeline images

| Stage       | Image |
|-------------|-------|
| Build deps  | `cgr.dev/$CHAINGUARD_ORG/node:22-dev` (ships `npm`) |
| Image build | host docker daemon (multi-stage build) |
| Test        | runs the just-built image |
| Push        | `$PUSH_REGISTRY/nodetest:22` |

## npm libraries used

- `express` (web server)
- `picocolors` (terminal coloring for the startup banner — small, dependency-free, and visibly demonstrates that npm package install is wired up)

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
docker pull $PUSH_REGISTRY/nodetest:22
docker run --rm -p 8080:8080 $PUSH_REGISTRY/nodetest:22
# Visit http://localhost:8080/
```

If `$PUSH_REGISTRY` points at ttl.sh (Modes A/B), tags expire after the default 24 hours — re-run the pipeline to refresh. In Mode C the push goes to the local Harbor (`localhost/library/...`) and persists until teardown.
