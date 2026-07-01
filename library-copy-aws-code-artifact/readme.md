# npm-codeartifact-mirror.sh

A bash script that mirrors npm packages from Chainguard Libraries to AWS CodeArtifact. This tool reads an npm `package-lock.json` **or** a pnpm `pnpm-lock.yaml` lockfile, downloads each package from Chainguard's curated npm registry (with fallback to public npm), and publishes them to your private CodeArtifact repository.

If you need to set up code artifact, refer to [code-artifact-setup.md](code-artifact-setup.md).

## Overview

This script automates the process of:
1. Parsing a lockfile to extract all package dependencies (ensure your lockfile has all dependencies and transitives defined, which is the standard behavior if `npm install` / `pnpm install` was run to create it).
2. Checking if packages already exist in CodeArtifact (to avoid duplicates)
3. Downloading packages from Chainguard Libraries registry
4. Publishing packages to AWS CodeArtifact
5. Retrying packages that Chainguard has not yet ingested, across multiple passes
6. Writing a report of anything that remained unavailable

The script handles both regular and scoped packages (e.g., `@types/node`, `@isaacs/fs-minipass`).

### Supported lockfiles

| Lockfile | Tool | Parser | Notes |
|----------|------|--------|-------|
| `package-lock.json` | npm | `jq` | Reads the `.packages` map |
| `pnpm-lock.yaml` / `*.yaml` / `*.yml` | pnpm | `yq` + `jq` | Supports lockfileVersion v5, v6, and v9 key formats |

The parser is chosen automatically from the file extension (`.yaml`/`.yml` → pnpm, anything else → npm).

## Disclaimer

This script is provided as an example without warranty of any kind, either expressed or implied, including but not limited to the implied warranties of merchantability and fitness for a particular purpose. Use at your own risk. No support is provided.

## Prerequisites

Before running this script, ensure you have the following tools installed:

- **jq** - JSON processor for parsing lockfiles
- **yq** - YAML processor, **required only for pnpm lockfiles**. Must be the Go [mikefarah](https://github.com/mikefarah/yq) build (v4), *not* the Python (kislyuk) `yq` — the script verifies this and aborts if the wrong one is found.
- **curl** - HTTP client
- **npm** - Node package manager (used for `npm pack` / `npm publish`)
- **aws-cli** - AWS Command Line Interface
- **bash** - Unix shell (version 4.0 or higher recommended)

### Installation Examples

```bash
# macOS (using Homebrew)
brew install jq yq awscli node
```

## Required Environment Variables

Set these environment variables before running the script:

### Chainguard Registry Authentication
- `CGR_USER` - Your Chainguard user/identity
- `CGR_TOKEN` - Your Chainguard authentication token

### AWS CodeArtifact Configuration
- `AWS_REGION` - AWS region where your CodeArtifact repository is located (e.g., `us-east-1`)
- `CODEARTIFACT_DOMAIN` - Your CodeArtifact domain name
- `CODEARTIFACT_REPOSITORY` - Your CodeArtifact repository name
- `CODEARTIFACT_DOMAIN_OWNER` - (Optional) AWS account ID. If not set, will use your current AWS account

### Optional Configuration
- `PACKAGE_LOCK_FILE` - Path to the lockfile to mirror. Overridden by a path passed as the first CLI argument; if neither is set the script auto-detects `package-lock.json` then `pnpm-lock.yaml` in the current directory.
- `TEMP_DIR` - Directory for temporary package downloads (default: `./temp_packages`)
- `LOG_FILE` - Path to log file (default: `./mirror.log`)
- `UNRESOLVED_REPORT` - Path for the report of packages that could not be mirrored (default: `./chainguard-unresolved.txt`)

#### Tuning the on-demand ingestion retry
Chainguard ingests upstream packages **on demand and asynchronously**, so the first request for an un-cached package often returns 404/ETARGET while it is fetched in the background. These variables control the retry behavior (see [How It Works](#how-it-works)):

- `INGEST_MAX_PASSES` - Maximum number of passes over the still-unavailable packages (default: `4`)
- `INGEST_RETRY_DELAY` - Seconds to wait between passes while Chainguard ingests (default: `30`)

#### Tuning npm transport robustness
These tune npm's own retry behavior for **transient** transport failures (network blips, socket timeouts, 429/5xx). They do **not** retry 404/ETARGET — that is handled by the multi-pass loop above.

- `NPM_FETCH_RETRIES` - Passed to `npm pack`/`npm publish` as `--fetch-retries` (default: `5`)
- `NPM_FETCH_TIMEOUT` - Passed as `--fetch-timeout`, in milliseconds (default: `60000`)

### Example Configuration

```bash
# Chainguard credentials
export CGR_USER="your-chainguard-user"
export CGR_TOKEN="your-chainguard-token"

# AWS CodeArtifact settings
export AWS_REGION="us-east-1"
export CODEARTIFACT_DOMAIN="my-company"
export CODEARTIFACT_REPOSITORY="npm-packages"
export CODEARTIFACT_DOMAIN_OWNER="123456789012"  # Optional

# Optional: Custom paths
export TEMP_DIR="./temp_packages"
export LOG_FILE="./mirror.log"

# Optional: tune retries for slow/large mirrors
export INGEST_MAX_PASSES="6"
export INGEST_RETRY_DELAY="45"
```

## Usage

### Basic Usage

```bash
# Auto-detect package-lock.json or pnpm-lock.yaml in the current directory
./npm-codeartifact-mirror.sh

# Specify an npm lockfile
./npm-codeartifact-mirror.sh /path/to/package-lock.json

# Specify a pnpm lockfile
./npm-codeartifact-mirror.sh /path/to/pnpm-lock.yaml
```

### Complete Example

```bash
# 1. Set required environment variables
export CGR_USER="your-user"
export CGR_TOKEN="your-token"
export AWS_REGION="us-east-1"
export CODEARTIFACT_DOMAIN="my-domain"
export CODEARTIFACT_REPOSITORY="my-repo"

# 2. Make script executable (if not already)
chmod +x npm-codeartifact-mirror.sh

# 3. Run the script
./npm-codeartifact-mirror.sh ./package-lock.json
```

## How It Works

1. **Prerequisite & environment validation**: Checks that the required CLI tools and environment variables are present. For pnpm lockfiles it also verifies that the `yq` on `PATH` is the mikefarah (Go) v4 build.
2. **Authentication setup**:
   - Configures Chainguard registry authentication using provided credentials
   - Obtains a temporary AWS CodeArtifact authentication token and repository endpoint
3. **Package parsing**: Extracts all packages and versions from the lockfile (`jq` for npm, `yq` + `jq` for pnpm). If a populated lockfile yields zero packages, the script fails loudly rather than silently reporting "nothing to mirror".
4. **Multi-pass mirroring**: Chainguard's upstream fallback ingests packages on demand and asynchronously, so a package that 404s on the first request is often downloadable moments later. The script therefore works in passes:
   - **Pass 1**: For each package, skip it if the version already exists in CodeArtifact; otherwise download it from Chainguard via `npm pack` and publish it to CodeArtifact. Misses (404/ETARGET/transient) are queued for retry. The first request also *primes* Chainguard's ingestion.
   - **Retry passes**: Wait `INGEST_RETRY_DELAY` seconds, then retry the still-missing packages with `--prefer-online` (to defeat npm's 5-minute packument cache). Repeat up to `INGEST_MAX_PASSES` times.
   - Auth/permission failures are recorded immediately and **not** retried, since they won't resolve on their own.
5. **Summary report & unresolved list**: Prints statistics, and if anything could not be mirrored, writes a `reason<tab>name@version` report to `UNRESOLVED_REPORT`.

## Features

### Scoped Package Support
The script fully supports scoped npm packages (e.g., `@types/node`, `@babel/core`). These are stored in CodeArtifact with separate namespace fields.

### pnpm Lockfile Support
In addition to npm's `package-lock.json`, the script parses pnpm's `pnpm-lock.yaml`. Because pnpm encodes a package's identity in the map key (and the format differs across lockfileVersion v5/v6/v9), the parser normalizes all three shapes so the result is identical regardless of which pnpm wrote the lockfile.

### Duplicate Prevention
Before downloading, the script checks if a package version already exists in CodeArtifact to avoid unnecessary downloads and duplicate upload attempts.

### Chainguard Fallback & On-Demand Ingestion Retry
When using Chainguard Libraries with fallback enabled, packages not already cached in Chainguard's registry are fetched from public npm. Because that ingestion is asynchronous, the first request can fail with 404/ETARGET. The script makes multiple passes (with a configurable delay) so packages that were still ingesting on an earlier pass get picked up once available.

### Failure Classification
Packages that remain unavailable after all passes are classified in the summary and the unresolved report:
- **ETARGET** — the requested version is still not served
- **404** — the package/version is still not served
- **Auth/permission errors** — 401/403 from Chainguard (not retried)
- **Other failures** — network or unexpected errors
- **Publish failures** — downloaded successfully but failed to publish to CodeArtifact

### Transport Robustness
`npm pack` and `npm publish` are run with configurable `--fetch-retries` and `--fetch-timeout` so transient network/socket/429/5xx errors are retried automatically within npm.

### Attestation Preservation
- **npm packages**: Standard npm attestations (embedded in tarballs) are preserved during mirroring
- **Chainguard packages**: Chainguard-specific registry metadata is not preserved, but the packages themselves are functionally identical

## Output and Logging

The script provides color-coded console output and writes detailed logs to the specified log file:

- **Green**: Informational messages
- **Yellow**: Warnings (e.g., package not yet available in Chainguard)
- **Red**: Errors

### Example Output

```
[2026-05-11 10:30:15] Starting npm package mirror to AWS CodeArtifact...
[2026-05-11 10:30:15] Package lock file: ./package-lock.json
[2026-05-11 10:30:16] Environment variables validated
[2026-05-11 10:30:16] Setting up Chainguard registry authentication...
[2026-05-11 10:30:17] Setting up AWS CodeArtifact authentication...
[2026-05-11 10:30:18] === Pass 1/4: attempting 41 package(s) ===
[2026-05-11 10:30:18] Processing express@4.18.2...
[2026-05-11 10:30:19] Downloading express@4.18.2...
[2026-05-11 10:30:21] Successfully published express@4.18.2
...
[2026-05-11 10:32:05] Pass 1 done; 3 still unavailable — waiting 30s for Chainguard fallback to ingest, then retrying...
[2026-05-11 10:32:35] === Pass 2/4: attempting 3 package(s) ===
...
==========================================
Mirror Summary:
  Total packages:                 41
  Already in CodeArtifact:        5
  Downloaded from Chainguard:     36
  Published to CodeArtifact:      36
  Unavailable after 4 passes:     0
    - ETARGET (version still not served):   0
    - 404 (still not served):               0
    - Auth/permission errors:               0
    - Other failures:                       0
  Publish failures:               0
==========================================
```

### Unresolved Packages Report

If any packages could not be mirrored, a report is written to `UNRESOLVED_REPORT` (default `./chainguard-unresolved.txt`) with one `reason<tab>name@version` line per package, e.g.:

```
404	left-pad@9.9.9
ETARGET	some-pkg@2.0.0
AUTH	@private/thing@1.0.0
```

Re-running the script later may pick up packages that were within Chainguard's ingestion cooldown window on the previous run.

## Troubleshooting

### Authentication Errors

**Problem**: `Failed to get CodeArtifact authorization token`

**Solution**: Ensure your AWS credentials are configured correctly:
```bash
aws configure
# or
aws sts get-caller-identity  # Verify current credentials
```

### Wrong `yq` detected (pnpm lockfiles)

**Problem**: `Wrong yq detected — this script needs the Go 'mikefarah' yq v4` or a populated pnpm lockfile reporting 0 packages.

**Solution**: Install the Go (mikefarah) build of `yq` v4. The Python (kislyuk) `yq` uses different argument semantics and will parse nothing:
```bash
brew install yq
yq --version   # should mention "mikefarah"
```

### Package Not Mirrored / Still Unavailable

**Problem**: Packages appear under "Unavailable after N passes" (ETARGET/404) in the summary or in the unresolved report.

**Solution**: This usually means Chainguard had not finished ingesting the package within the retry window — it may be in a cooldown period, malware-blocked, have no verifiable source, or simply not exist. Try:
- Increasing `INGEST_MAX_PASSES` and/or `INGEST_RETRY_DELAY`
- Re-running the script later (packages past their cooldown will be picked up)

### Permission Denied

**Problem**: `Error: 403 Forbidden` when publishing to CodeArtifact

**Solution**: Verify your AWS IAM permissions include:
- `codeartifact:PublishPackageVersion`
- `codeartifact:PutPackageMetadata`
- `codeartifact:GetAuthorizationToken`
- `codeartifact:GetRepositoryEndpoint`

### Scoped Packages Not Found

**Problem**: Scoped packages (e.g., `@types/node`) not appearing in CodeArtifact

**Solution**: Scoped packages are stored with namespaces. Use the AWS CLI with `--namespace` parameter:
```bash
aws codeartifact list-packages \
  --domain my-domain \
  --repository my-repo \
  --format npm \
  --namespace types  # For @types/* packages
```

## Verifying Mirrored Packages

### Check Package in CodeArtifact

```bash
# List all packages
aws codeartifact list-packages \
  --domain $CODEARTIFACT_DOMAIN \
  --repository $CODEARTIFACT_REPOSITORY \
  --format npm

# Check specific package version
aws codeartifact list-package-versions \
  --domain $CODEARTIFACT_DOMAIN \
  --repository $CODEARTIFACT_REPOSITORY \
  --package express \
  --format npm

# Check scoped package
aws codeartifact list-package-versions \
  --domain $CODEARTIFACT_DOMAIN \
  --repository $CODEARTIFACT_REPOSITORY \
  --package fs-minipass \
  --namespace isaacs \
  --format npm
```

### Verify Package Attestations

For packages that originated from npm (via Chainguard fallback), you can verify attestations using cosign:

```bash
# Download package
npm pack express@4.18.2 --registry=https://your-codeartifact-url

# Verify attestations
cosign verify-attestation express-4.18.2.tgz \
  --type slsaprovenance \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/.*/.github/workflows"
```

## Using Mirrored Packages

Configure your project to use CodeArtifact as the registry:

```bash
# Login to CodeArtifact
aws codeartifact login \
  --tool npm \
  --domain $CODEARTIFACT_DOMAIN \
  --repository $CODEARTIFACT_REPOSITORY \
  --region $AWS_REGION

# Install packages
npm install
```

Or configure `.npmrc` manually:

```
registry=https://your-domain-123456789012.d.codeartifact.us-east-1.amazonaws.com/npm/your-repo/
//your-domain-123456789012.d.codeartifact.us-east-1.amazonaws.com/npm/your-repo/:_authToken=${CODEARTIFACT_TOKEN}
```

## Limitations

- **Chainguard-specific attestations**: Registry-specific metadata from Chainguard Libraries is not preserved during mirroring, though the packages themselves are functionally identical
- **Asynchronous ingestion**: Packages not yet cached by Chainguard are ingested on demand, so some may remain unavailable within a single run's retry window and require a later re-run
- **Rate limiting**: Large lockfiles may encounter rate limits from source or destination registries
- **Storage costs**: CodeArtifact charges for storage. Monitor repository size and clean up unused package versions

## Support

For issues related to:
- **Script functionality**: Review the log file for detailed error messages
- **Chainguard Libraries**: Contact Chainguard support
- **AWS CodeArtifact**: Consult AWS documentation or support

## License

This script is provided as-is without warranty. See disclaimer at the top of this document.
