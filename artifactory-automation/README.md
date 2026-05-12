# Automate Artifactory Pull Tokens

Workflow that will automate the creation and updating of pull tokens to allow customers to authenticate with their artifactory instance

For this workflow to run properly, you will need to create an [assumable identity](https://edu.chainguard.dev/chainguard/administration/custom-idps/custom-idps/) beforehand. It will need a role with the correctly scoped permissions.

## Creating the Role and Identity
Create a role for artifactory that can create and delete pull tokens.
> [!IMPORTANT]
> If you want to enable pruning of expired pull tokens, you must add identity.list and identity.delete capabilities.

1. Create a role with identity.delete capabilities:

`chainctl iam roles create token-delete --parent <your-organization> --capabilities identity.delete`

2. Create the assumable identity and bind the token-delete role:

`chainctl iam identities create github artifactory --github-repo=<your-repository> --parent=<your-organization> --role=token-delete,registry.pull_token_creator`


## Example Workflow

```
name: Create Pull Token

on:
  workflow_dispatch:
  schedule:
    - cron: "0 0 * * 0"

permissions:
  contents: read

jobs:
  authentication:
    name: Auth
    runs-on: ubuntu-latest

    permissions:
      contents: read
      id-token: write

    steps:
      - name: "Setup Artifactory Token"
        uses: <where-your-action-lives>
        with:
          identity: "some-chainguard/assumable-identity"
          organization: test.com
          artifactory_url: https://your-artifactory.com
          artifactory_user: test_user@test.com
          artifactory_repository_name: test_repository
          artifactory_token: ${{ secrets.ARTIFACTORY_TOKEN }}
          prune_expired: true
```
