# refresh-cgimages-digests

Scheduled Jenkins job that re-resolves every digest in the [cgImages shared-library catalog](../../shared-libraries/cg-images/vars/cgImage.groovy) every 4 hours, rewriting `repo:tag@sha256:...` entries in place when the upstream tags have moved.

## How it works

| Stage | Image | Purpose |
|-------|-------|---------|
| Refresh digests | `cgr.dev/${CHAINGUARD_ORG}/crane:latest-dev` | Runs [refresh-digests.sh](../../shared-libraries/cg-images/refresh-digests.sh) which calls `crane digest` for each entry. |

The agent container gets:
- `DOCKER_CONFIG=/dockerconfig` pointed at the bind-mounted pull-token config (so `crane` can authenticate to `cgr.dev`)
- `/tmp/cgjenkins-home/shared-libraries` mounted **read-write** at `/sources` so the script can rewrite `vars/cgImage.groovy`

When digests change, the next sample-app pipeline picks them up automatically — the cgImages library is live-loaded from the same bind-mounted dir on every build. No Jenkins restart needed.

## Schedule

`H H/4 * * *` — every 4 hours, with the minute and starting hour randomized per controller (the leading `H` spreads the load so multiple controllers don't all stampede the registry at exactly :00).

To change the schedule, edit the `cron(...)` argument in [jenkins/casc/jobs.groovy](../../jenkins/casc/jobs.groovy) and restart the controller. To disable temporarily, comment out the `triggers` block — the job remains in the dashboard and can still be triggered manually.

## Caveats

- Writes to the shared-libraries dir are visible on the host filesystem (the bind mount is rw). If you have local edits to `vars/cgImage.groovy` that haven't been committed, this job will overwrite the digest fields. Adding/removing tokens from the catalog is fine — those edits live on lines the script doesn't touch.
- The job authenticates as the configured `CHAINGUARD_ORG`'s pull token. Digests for other orgs would need a separate auth path.
- Digest resolution against the registry costs one HEAD per entry (14 today). Cheap, but not free — don't run this every minute.
