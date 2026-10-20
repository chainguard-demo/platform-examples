# Automate Cloudsmith Pull Tokens

Action that creates a new Chainguard pull token and updates an existing Cloudsmith Docker upstream with it, so the upstream's credentials rotate automatically.

For this action to run properly, you will need to create an [assumable identity](https://edu.chainguard.dev/chainguard/administration/custom-idps/custom-idps/) beforehand. It will need a role with the correctly scoped permissions.

## Creating the Role and Identity
Create a role for Cloudsmith that can create and delete pull tokens.
> [!IMPORTANT]
> If you want to enable pruning of expired pull tokens, you must add identity.list and identity.delete capabilities.

1. Create a role with identity.list and identity.delete capabilities:

`chainctl iam roles create token-delete --parent <your-organization> --capabilities identity.list,identity.delete`

2. Create the assumable identity and bind the token-delete role:

`chainctl iam identities create github cloudsmith --github-repo=<your-repository> --parent=<your-organization> --role=token-delete,registry.pull_token_creator`

## Cloudsmith Prerequisites
- A Docker upstream pointing at `https://cgr.dev` must already exist in your Cloudsmith repository. The action looks it up by `cloudsmith_upstream_name` and updates its credentials.
- Store a Cloudsmith API key as a GitHub secret named `CLOUDSMITH_API_KEY`. The key needs permission to manage upstreams on the repository.

## Usage
Choose one of two options. Both do the same thing.

| File | What it is | Use it when |
|---|---|---|
| [standalone-workflow.yaml](standalone-workflow.yaml) | A complete workflow with all steps inline | You want one file to copy into a single repository |
| [action.yaml](action.yaml) + [example-workflow.yaml](example-workflow.yaml) | A composite action, and a short workflow that calls it | You want several repositories to share one versioned copy of the logic |

Both workflows run manually (`workflow_dispatch`) by default. To rotate on a schedule, uncomment the `schedule` block. Keep the schedule shorter than the token `ttl` (default `168h`), so the upstream never holds an expired token.

### Option 1: Standalone workflow
1. Copy [standalone-workflow.yaml](standalone-workflow.yaml) to your repository's `.github/workflows/` folder.
2. Add the secret `CLOUDSMITH_API_KEY`.
3. Add these repository variables (Settings > Secrets and variables > Actions > Variables):

| Variable | Value |
|---|---|
| `CHAINGUARD_IDENTITY` | The assumable identity ID |
| `CHAINGUARD_ORGANIZATION` | Your Chainguard organization |
| `CLOUDSMITH_ORG_NAME` | Your Cloudsmith organization slug |
| `CLOUDSMITH_REPOSITORY_NAME` | Your Cloudsmith repository slug |
| `CLOUDSMITH_UPSTREAM_NAME` | The name of the Docker upstream |

### Option 2: Composite action
1. Copy [example-workflow.yaml](example-workflow.yaml) to your repository's `.github/workflows/` folder.
2. Set `uses:` to the location of this action, for example `<owner>/<repo>/cloudsmith-automation@<ref>`.
3. Replace the placeholder values under `with:`, and add the secret `CLOUDSMITH_API_KEY`.

#### Inputs

| Input | Required | Description |
|---|---|---|
| `identity` | yes | Chainguard assumable identity |
| `organization` | yes | Chainguard organization |
| `cloudsmith_url` | yes | Cloudsmith API URL (`https://api.cloudsmith.io`) |
| `cloudsmith_org_name` | yes | Cloudsmith organization slug |
| `cloudsmith_repository_name` | yes | Cloudsmith repository slug |
| `cloudsmith_upstream_name` | yes | Name of the Docker upstream to update |
| `cloudsmith_user` | yes | Cloudsmith username |
| `cloudsmith_token` | yes | Cloudsmith API key (pass from a secret) |
| `ttl` | no | Pull token TTL (default `168h`) |
| `prune_expired` | no | Delete expired pull tokens for this upstream (default `false`) |
