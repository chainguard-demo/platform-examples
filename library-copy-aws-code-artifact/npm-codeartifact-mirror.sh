#!/bin/bash

# npm-codeartifact-mirror.sh
# Mirrors npm packages from Chainguard Libraries to AWS CodeArtifact
# This script reads package-lock.json or pnpm-lock.yaml, checks availability in
# Chainguard Libraries, downloads packages with proper authentication, and publishes
# them to CodeArtifact.
#
# DISCLAIMER:
# This script is provided as an example without warranty of any kind, either expressed
# or implied, including but not limited to the implied warranties of merchantability
# and fitness for a particular purpose. Use at your own risk. No support is provided.
#
# Usage: ./npm-codeartifact-mirror.sh [path-to-lock-file]
#   Supports package-lock.json (npm) and pnpm-lock.yaml (pnpm)
#   Auto-detects the lock file if no argument is provided

set -e

# Configuration
CHAINGUARD_REGISTRY="https://libraries.cgr.dev/javascript/"
TEMP_DIR="${TEMP_DIR:-./temp_packages}"
LOG_FILE="${LOG_FILE:-./mirror.log}"
NPM_CONFIG_CHAINGUARD=".npmrc.chainguard"
NPM_CONFIG_CODEARTIFACT=".npmrc.codeartifact"

# npm transport robustness. These handle TRANSIENT failures (network blips,
# socket timeouts, 429/5xx) — note they do NOT retry 404/ETARGET, which npm
# treats as definitive; that case is handled by the multi-pass retry loop in
# process_packages instead.
NPM_FETCH_RETRIES="${NPM_FETCH_RETRIES:-5}"
NPM_FETCH_TIMEOUT="${NPM_FETCH_TIMEOUT:-60000}"

# Required environment variables (set these before running)
# CGR_USER - Chainguard user/identity
# CGR_TOKEN - Chainguard authentication token
# AWS_REGION (e.g., us-east-1)
# CODEARTIFACT_DOMAIN
# CODEARTIFACT_REPOSITORY
# CODEARTIFACT_DOMAIN_OWNER (optional, will use AWS account ID if not set)

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
}

# Check required environment variables
check_env() {
    local missing=0

    if [ -z "$CGR_USER" ]; then
        error "CGR_USER is not set"
        missing=1
    fi

    if [ -z "$CGR_TOKEN" ]; then
        error "CGR_TOKEN is not set"
        missing=1
    fi

    if [ -z "$AWS_REGION" ]; then
        error "AWS_REGION is not set"
        missing=1
    fi

    if [ -z "$CODEARTIFACT_DOMAIN" ]; then
        error "CODEARTIFACT_DOMAIN is not set"
        missing=1
    fi

    if [ -z "$CODEARTIFACT_REPOSITORY" ]; then
        error "CODEARTIFACT_REPOSITORY is not set"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        error "Missing required environment variables. Please set them and try again."
        exit 1
    fi

    log "Environment variables validated"
}

# Setup authentication for Chainguard registry
setup_chainguard_auth() {
    log "Setting up Chainguard registry authentication..."

    # Create base64 encoded token for direct API calls
    export CHAINGUARD_AUTH_TOKEN=$(echo -n "${CGR_USER}:${CGR_TOKEN}" | base64)

    # Configure npm to use Chainguard registry for downloads (in local .npmrc)
    local cgr_host=$(echo "$CHAINGUARD_REGISTRY" | sed 's|^http://||' | sed 's|^https://||' | sed 's|/.*$||')
    local cgr_path=$(echo "$CHAINGUARD_REGISTRY" | sed 's|^http://[^/]*||' | sed 's|^https://[^/]*||')

    # Create Chainguard npm config file in temp directory
    mkdir -p "$TEMP_DIR"
    echo "//${cgr_host}${cgr_path}:_auth=$CHAINGUARD_AUTH_TOKEN" > "${TEMP_DIR}/${NPM_CONFIG_CHAINGUARD}"

    log "Chainguard authentication configured"
}

# Setup authentication for CodeArtifact
setup_codeartifact_auth() {
    log "Setting up AWS CodeArtifact authentication..."

    # Get domain owner (AWS account ID) if not provided
    if [ -z "$CODEARTIFACT_DOMAIN_OWNER" ]; then
        CODEARTIFACT_DOMAIN_OWNER=$(aws sts get-caller-identity --query Account --output text)
        log "Using AWS account ID: $CODEARTIFACT_DOMAIN_OWNER"
    fi

    # Get CodeArtifact auth token
    local ca_token=$(aws codeartifact get-authorization-token \
        --domain "$CODEARTIFACT_DOMAIN" \
        --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" \
        --region "$AWS_REGION" \
        --query authorizationToken \
        --output text)

    if [ -z "$ca_token" ]; then
        error "Failed to get CodeArtifact authorization token"
        exit 1
    fi

    # Get CodeArtifact repository endpoint
    export CODEARTIFACT_REGISTRY=$(aws codeartifact get-repository-endpoint \
        --domain "$CODEARTIFACT_DOMAIN" \
        --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" \
        --repository "$CODEARTIFACT_REPOSITORY" \
        --format npm \
        --region "$AWS_REGION" \
        --query repositoryEndpoint \
        --output text)

    if [ -z "$CODEARTIFACT_REGISTRY" ]; then
        error "Failed to get CodeArtifact repository endpoint"
        exit 1
    fi

    # Create CodeArtifact npm config file in temp directory
    # Extract registry URL without protocol, keep trailing slash
    local ca_registry_path=$(echo "$CODEARTIFACT_REGISTRY" | sed 's|^http://||' | sed 's|^https://||')
    # Ensure exactly one trailing slash before the colon
    ca_registry_path=$(echo "$ca_registry_path" | sed 's|/*$|/|')
    echo "//${ca_registry_path}:_authToken=$ca_token" > "${TEMP_DIR}/${NPM_CONFIG_CODEARTIFACT}"

    log "CodeArtifact authentication configured"
    log "CodeArtifact registry: $CODEARTIFACT_REGISTRY"
}

# Check if a specific package version already exists in CodeArtifact.
check_package_in_codeartifact() {
    local package_name=$1
    local version=$2

    # CodeArtifact stores an npm scope as a separate namespace.
    local ns_args=()
    local pkg="$package_name"
    if [[ "$package_name" == @*/* ]]; then
        local scope="${package_name%%/*}"
        scope="${scope#@}"
        pkg="${package_name#*/}"
        ns_args=(--namespace "$scope")
    fi

    if aws codeartifact describe-package-version \
        --domain "$CODEARTIFACT_DOMAIN" \
        --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" \
        --repository "$CODEARTIFACT_REPOSITORY" \
        --format npm \
        "${ns_args[@]}" \
        --package "$pkg" \
        --package-version "$version" \
        --region "$AWS_REGION" \
        --output text > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Download a package from the Chainguard registry via `npm pack`.
# Return codes let the caller react to the specific npm failure:
#   0 = downloaded (tarball path on stdout)
#   2 = ETARGET (version not currently served)
#   3 = 404 (package/version not currently served)
#   4 = auth/permission error (401/403)
#   1 = other failure (network, tarball-name mismatch, etc.)
download_package_from_chainguard() {
    local package_name=$1
    local version=$2
    local output_dir=$3
    local prefer_online=$4   # non-empty -> add --prefer-online (used on retry passes)

    log "Downloading ${package_name}@${version}..." >&2

    cd "$output_dir" || return 1

    # --prefer-online revalidates cached metadata (registry sends max-age=300),
    # so retry passes see freshly-ingested versions instead of a stale packument.
    local online_flag=()
    [ -n "$prefer_online" ] && online_flag=(--prefer-online)

    # Capture npm's output so we can classify the failure reason.
    local npm_output
    npm_output=$(npm pack "${package_name}@${version}" \
        --registry="${CHAINGUARD_REGISTRY}" \
        --userconfig="$NPM_CONFIG_CHAINGUARD" \
        --fetch-retries="$NPM_FETCH_RETRIES" \
        --fetch-timeout="$NPM_FETCH_TIMEOUT" \
        "${online_flag[@]}" 2>&1)
    local npm_exit=$?

    cd - > /dev/null || return 1

    # If npm pack succeeded, find the tarball that was created
    if [ $npm_exit -eq 0 ]; then
        # The tarball name follows the pattern: packagename-version.tgz
        # For scoped packages: @scope/packagename becomes scope-packagename
        local expected_name=$(echo "${package_name}" | sed 's/@//' | sed 's/\//-/')
        local tarball_path="${output_dir}/${expected_name}-${version}.tgz"

        if [ -f "$tarball_path" ]; then
            echo "$tarball_path"
            return 0
        fi
        warn "Package ${package_name}@${version}: npm pack succeeded but tarball not found at expected path" >&2
        return 1
    fi

    # Classify the npm failure so the caller can retry transient ones (2/3).
    if echo "$npm_output" | grep -q 'code ETARGET'; then
        warn "${package_name}@${version}: not yet available (ETARGET)" >&2
        return 2
    elif echo "$npm_output" | grep -Eq 'code E404|404 Not Found'; then
        warn "${package_name}@${version}: not yet available (404)" >&2
        return 3
    elif echo "$npm_output" | grep -Eq 'code E401|code E403|EAUTHUNKNOWN|Unauthorized|Forbidden'; then
        error "${package_name}@${version}: auth/permission error from Chainguard" >&2
        return 4
    else
        warn "${package_name}@${version}: npm pack failed: $(echo "$npm_output" | grep -m1 'npm error' || echo 'unknown error')" >&2
        return 1
    fi
}

# Publish package to CodeArtifact
publish_to_codeartifact() {
    local tarball_file=$1
    local package_name=$2
    local version=$3

    log "Publishing ${package_name}@${version} to CodeArtifact..."

    # Verify tarball exists
    if [ ! -f "$tarball_file" ]; then
        error "Tarball file not found: $tarball_file"
        return 1
    fi

    # Publish tarball directly to CodeArtifact
    local publish_output=$(npm publish "$tarball_file" \
        --registry="$CODEARTIFACT_REGISTRY" \
        --userconfig="${TEMP_DIR}/${NPM_CONFIG_CODEARTIFACT}" \
        --fetch-retries="$NPM_FETCH_RETRIES" \
        --fetch-timeout="$NPM_FETCH_TIMEOUT" 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log "Successfully published ${package_name}@${version}"
        return 0
    else
        error "Failed to publish ${package_name}@${version}: $publish_output"
        return 1
    fi
}

# Extract packages from package-lock.json (npm)
extract_packages_npm() {
    local lock_file=$1

    log "Parsing package-lock.json..." >&2

    # Output format: NAME|VERSION (using | as delimiter to handle scoped packages with @)
    jq -r '
        .packages // {} |
        to_entries[] |
        select(.key != "") |
        select(.value.version != null) |
        {
            path: .key,
            name: (if (.value.name != null) then .value.name else (.key | split("node_modules/") | last) end),
            version: .value.version
        } |
        "\(.name)|\(.version)"
    ' "$lock_file" | sort -u
}

# Extract packages from a pnpm lockfile (pnpm-lock.yaml / package-lock.yaml)
#
# Unlike npm, pnpm stores a package's identity in the map KEY as name@version
# (there are no separate name/version fields), and the key format varies by
# lockfileVersion:
#   v9: "name@version"            / "@scope/name@version"
#   v6: "/name@version"           (leading slash; peer deps as "(dep@1.0.0)")
#   v5: "/name/version"           (slash separator, no @ before version)
# We convert the .packages map to JSON once and normalize all three shapes in
# jq, so the result is identical regardless of which pnpm wrote the lockfile.
extract_packages_pnpm() {
    local lock_file=$1

    log "Parsing pnpm lockfile (YAML)..." >&2

    # How many packages does the lockfile claim to have?
    local pkg_count
    pkg_count=$(yq e '.packages | length' "$lock_file" 2>/dev/null)
    [ -z "$pkg_count" ] && pkg_count=0

    local extracted
    extracted=$(yq -o=json '.packages // {}' "$lock_file" | jq -r '
        keys[]
        | sub("^/"; "")                       # v6: strip leading slash
        | sub("\\(.*$"; "")                   # strip "(peer@x)" suffix
        | . as $k
        | (ltrimstr("@") | test("@")) as $hasAt   # ignore a leading scope "@"
        | (if $hasAt
             then ($k | capture("^(?<name>.+)@(?<version>[^@]+)$"))   # v6/v9
             else ($k | capture("^(?<name>.+)/(?<version>[^/]+)$"))   # v5
           end)
        | select(.name != "" and .version != "")
        | select(.version | test("://") | not)   # drop tarball/git "versions"
        | "\(.name)|\(.version)"
    ' | sort -u)

    local extracted_count=0
    [ -n "$extracted" ] && extracted_count=$(printf '%s\n' "$extracted" | grep -c '|')

    # Fail loud: a populated lockfile that yields nothing is a tooling/format
    # mismatch (wrong yq flavor, unsupported lockfileVersion) — NOT "nothing to
    # mirror". Silently reporting 0 here is the bug we're guarding against.
    # NOTE: this exit only aborts the script because process_packages captures
    # our output in the main shell (see the call site), not via a subshell.
    if [ "$pkg_count" -gt 0 ] && [ "$extracted_count" -eq 0 ]; then
        error "Lockfile lists ${pkg_count} packages but extraction produced none." >&2
        error "Verify yq is the mikefarah build (v4) and the lockfileVersion is supported." >&2
        exit 1
    fi

    printf '%s\n' "$extracted"
}

# Extract packages — dispatches to the right parser based on file extension
extract_packages() {
    local lock_file=$1

    if [ ! -f "$lock_file" ]; then
        error "Lock file not found at: $lock_file"
        exit 1
    fi

    case "$lock_file" in
        *.yaml|*.yml)
            extract_packages_pnpm "$lock_file"
            ;;
        *)
            extract_packages_npm "$lock_file"
            ;;
    esac
}


# Main processing function
process_packages() {
    local lock_file=$1
    local temp_dir=$2

    mkdir -p "$temp_dir"

    local downloaded=0
    local published=0
    local already_exists=0
    local failed=0
    # Final breakdown of packages still unavailable after all retry passes.
    local version_gap=0
    local pkg_missing=0
    local auth_err=0
    local other_fail=0
    local unresolved=""   # "REASON<tab>name@version" lines for the report

    # Chainguard's upstream fallback ingests packages ON DEMAND and
    # ASYNCHRONOUSLY, so the first request for an un-cached package/version returns
    # 404/ETARGET while Chainguard fetches it from npm in the background, and it
    # becomes downloadable moments later. A single npm pack call works too fast for this process. 
    # Accordingly, make multiple passes where the first pass primes ingestion for every miss, and 
    # subsequent passes (after a short wait) pick up the now-populated packages. Tunable via env vars.
    local max_passes="${INGEST_MAX_PASSES:-4}"
    local retry_delay="${INGEST_RETRY_DELAY:-30}"

    # Extract into a variable in THIS shell first. Capturing here (rather than
    # feeding the loop via process substitution) lets a fail-loud exit inside
    # extract_packages abort the whole run under `set -e`, instead of dying
    # silently in a subshell and leaving the loop to report 0.
    local pkg_list
    pkg_list=$(extract_packages "$lock_file")
    local total
    total=$(printf '%s\n' "$pkg_list" | grep -c '|' || true)

    # Work queue. First pass holds "name|version"; retry passes hold
    # "rc|name|version" so each miss carries its last classification forward.
    local pending="$pkg_list"
    local pass=0

    while [ -n "$(printf '%s' "$pending" | tr -d '[:space:]')" ] && [ "$pass" -lt "$max_passes" ]; do
        pass=$((pass + 1))
        local is_first=0; [ "$pass" -eq 1 ] && is_first=1
        local count_this; count_this=$(printf '%s\n' "$pending" | grep -c '|' || true)
        log "=== Pass ${pass}/${max_passes}: attempting ${count_this} package(s) ==="
        local next_pending=""

        while IFS='|' read -r f1 f2 f3; do
            local package_name package_version
            if [ "$is_first" -eq 1 ]; then
                package_name="$f1"; package_version="$f2"
            else
                package_name="$f2"; package_version="$f3"   # f1 is the carried rc
            fi
            [ -z "$package_name" ] && continue

            # Only check CodeArtifact (and count already-exists) on the first pass;
            # retry queue only ever holds packages we already know aren't there.
            if [ "$is_first" -eq 1 ]; then
                log "Processing ${package_name}@${package_version}..."
                if check_package_in_codeartifact "$package_name" "$package_version"; then
                    log "${package_name}@${package_version} already exists in CodeArtifact, skipping"
                    already_exists=$((already_exists + 1))
                    continue
                fi
            else
                log "Retry ${package_name}@${package_version}..."
            fi

            # On retry passes, force fresh metadata (--prefer-online) so the
            # registry's 5-minute packument cache doesn't keep returning ETARGET
            # for a version that has since been ingested.
            local prefer_online=""
            [ "$is_first" -eq 0 ] && prefer_online="1"

            # `&& rc=0 || rc=$?` keeps this in a tested context so a non-zero
            # return doesn't trip `set -e`.
            local tarball_file rc
            tarball_file=$(download_package_from_chainguard "$package_name" "$package_version" "$temp_dir" "$prefer_online") && rc=0 || rc=$?

            case $rc in
                0)
                    downloaded=$((downloaded + 1))
                    if publish_to_codeartifact "$tarball_file" "$package_name" "$package_version"; then
                        published=$((published + 1))
                        rm -f "$tarball_file"
                    else
                        failed=$((failed + 1))
                        unresolved+="PUBLISH"$'\t'"${package_name}@${package_version}"$'\n'
                    fi
                    ;;
                4)  # auth won't resolve by retrying — record now, don't re-queue
                    auth_err=$((auth_err + 1))
                    unresolved+="AUTH"$'\t'"${package_name}@${package_version}"$'\n'
                    ;;
                *)
                    # 1/2/3: not served yet — may still be ingesting. Re-queue,
                    # carrying the rc so we can classify it if it never resolves.
                    next_pending+="${rc}|${package_name}|${package_version}"$'\n'
                    ;;
            esac
        done <<< "$pending"

        pending="$next_pending"
        local remaining; remaining=$(printf '%s\n' "$pending" | grep -c '|' || true)
        if [ "$remaining" -gt 0 ] && [ "$pass" -lt "$max_passes" ]; then
            log "Pass ${pass} done; ${remaining} still unavailable — waiting ${retry_delay}s for Chainguard fallback to ingest, then retrying..."
            sleep "$retry_delay"
        fi
    done

    # Whatever is still pending after the final pass is genuinely unavailable
    # (truly nonexistent, malware-blocked, still in cooldown, or no verifiable
    # source). Classify by the last rc each carried.
    while IFS='|' read -r rc package_name package_version; do
        [ -z "$package_name" ] && continue
        case $rc in
            2) version_gap=$((version_gap + 1)); unresolved+="ETARGET"$'\t'"${package_name}@${package_version}"$'\n' ;;
            3) pkg_missing=$((pkg_missing + 1));  unresolved+="404"$'\t'"${package_name}@${package_version}"$'\n' ;;
            *) other_fail=$((other_fail + 1));    unresolved+="OTHER"$'\t'"${package_name}@${package_version}"$'\n' ;;
        esac
    done <<< "$pending"

    # Summary
    local not_mirrored=$((version_gap + pkg_missing + auth_err + other_fail))
    log "=========================================="
    log "Mirror Summary:"
    log "  Total packages:                 $total"
    log "  Already in CodeArtifact:        $already_exists"
    log "  Downloaded from Chainguard:     $downloaded"
    log "  Published to CodeArtifact:      $published"
    log "  Unavailable after ${max_passes} passes:  $not_mirrored"
    log "    - ETARGET (version still not served):   $version_gap"
    log "    - 404 (still not served):               $pkg_missing"
    log "    - Auth/permission errors:               $auth_err"
    log "    - Other failures:                       $other_fail"
    log "  Publish failures:               $failed"
    log "=========================================="
    if [ -n "$unresolved" ]; then
        local report="${UNRESOLVED_REPORT:-./chainguard-unresolved.txt}"
        printf '%s' "$unresolved" | sort > "$report"
        log "Unresolved packages (reason<tab>name@version) written to: $report"
    fi
    if [ "$not_mirrored" -gt 0 ]; then
        log "NOTE: still unavailable after ${max_passes} passes — likely within the cooldown"
        log "window, malware-blocked, no verifiable source, or nonexistent. Re-running"
        log "later may pick up packages past cooldown. Tune: INGEST_MAX_PASSES / INGEST_RETRY_DELAY."
    fi
}

# Main script execution
main() {
    # Parse command line arguments
    if [ $# -gt 0 ]; then
        PACKAGE_LOCK_FILE="$1"
    elif [ -n "$PACKAGE_LOCK_FILE" ]; then
        : # Use value from environment
    elif [ -f "./package-lock.json" ]; then
        PACKAGE_LOCK_FILE="./package-lock.json"
    elif [ -f "./pnpm-lock.yaml" ]; then
        PACKAGE_LOCK_FILE="./pnpm-lock.yaml"
    else
        PACKAGE_LOCK_FILE="./package-lock.json"
    fi

    log "Starting npm package mirror to AWS CodeArtifact..."
    log "Package lock file: $PACKAGE_LOCK_FILE"
    log "Chainguard registry: $CHAINGUARD_REGISTRY"

    # Check if lock file exists
    if [ ! -f "$PACKAGE_LOCK_FILE" ]; then
        error "Lock file not found: $PACKAGE_LOCK_FILE"
        echo ""
        echo "Usage: $0 [path-to-lock-file]"
        echo ""
        echo "Examples:"
        echo "  $0                              # Auto-detects package-lock.json or pnpm-lock.yaml"
        echo "  $0 /path/to/package-lock.json  # Uses npm lock file"
        echo "  $0 /path/to/pnpm-lock.yaml     # Uses pnpm lock file"
        exit 1
    fi

    # Check prerequisites
    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed. Please install jq and try again."
        exit 1
    fi

    # yq is required for pnpm lockfiles — and it MUST be the Go (mikefarah) v4
    # build. The Python (kislyuk) yq uses different argument semantics, so
    # `yq e '...'` silently parses nothing and the run reports 0 packages.
    case "$PACKAGE_LOCK_FILE" in
        *.yaml|*.yml)
            if ! command -v yq &> /dev/null; then
                error "yq is required for pnpm lockfiles but not installed. Install mikefarah yq v4 (e.g. brew install yq)."
                exit 1
            fi
            if ! yq --version 2>&1 | grep -qi 'mikefarah'; then
                error "Wrong yq detected — this script needs the Go 'mikefarah' yq v4, not the Python (kislyuk) yq."
                error "Found: $(yq --version 2>&1). Install the correct one with: brew install yq"
                exit 1
            fi
            ;;
    esac

    if ! command -v curl &> /dev/null; then
        error "curl is required but not installed. Please install curl and try again."
        exit 1
    fi

    if ! command -v npm &> /dev/null; then
        error "npm is required but not installed. Please install npm and try again."
        exit 1
    fi

    if ! command -v aws &> /dev/null; then
        error "AWS CLI is required but not installed. Please install aws-cli and try again."
        exit 1
    fi

    # Validate environment
    check_env

    # Setup authentication
    setup_chainguard_auth
    setup_codeartifact_auth

    # Process packages
    process_packages "$PACKAGE_LOCK_FILE" "$TEMP_DIR"

    # Cleanup
    rmdir "$TEMP_DIR" 2>/dev/null || true

    log "Mirror process completed!"
}

# Run main function
main "$@"
