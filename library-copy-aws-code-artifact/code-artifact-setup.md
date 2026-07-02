# AWS CodeArtifact Setup Guide

This guide will help you set up AWS CodeArtifact to test the npm mirroring script.

## Prerequisites

1. **AWS CLI installed**
   ```bash
   # Check if installed
   aws --version

   # If not installed, visit: https://aws.amazon.com/cli/
   ```

2. **AWS credentials configured**
   ```bash
   # Configure AWS CLI with your credentials
   aws configure

   # Enter:
   # - AWS Access Key ID
   # - AWS Secret Access Key
   # - Default region (e.g., us-east-1)
   # - Default output format (json)
   ```

3. **Chainguard credentials**
   - You need a Chainguard account with access to Chainguard Libraries
   - Get your authentication token from Chainguard

## Quick Setup

### Option 1: Automated Setup (Recommended)

Use the provided setup script:

```bash
# Make it executable
chmod +x setup-codeartifact.sh

# Run the setup
./setup-codeartifact.sh
```

The script will:
- Create a CodeArtifact domain named `npm-mirror-test`
- Create a repository named `cg-npm-packages`
- Display the environment variables you need to export

### Option 2: Manual Setup

If you prefer to set it up manually:

```bash
# Set your region
export AWS_REGION="us-east-1"

# Create a CodeArtifact domain
aws codeartifact create-domain \
  --domain npm-mirror-test \
  --region $AWS_REGION

# Create a repository
aws codeartifact create-repository \
  --domain npm-mirror-test \
  --repository cg-npm-packages \
  --description "npm packages mirror from Chainguard" \
  --region $AWS_REGION
```

## Configure Environment Variables

After setup, export these environment variables:

```bash
# AWS CodeArtifact settings
export AWS_REGION="us-east-1"
export CODEARTIFACT_DOMAIN="npm-mirror-test"
export CODEARTIFACT_REPOSITORY="cg-npm-packages"
# CODEARTIFACT_DOMAIN_OWNER is optional - will auto-detect your AWS account ID

# Chainguard credentials
export CGR_USER="your-chainguard-identity"
export CGR_TOKEN="your-chainguard-token"
```

## Test the Mirror Script

### 1. Create a test package-lock.json

Create a simple test project:

```bash
# Create test directory
mkdir test-mirror
cd test-mirror

# Initialize npm project
npm init -y

# Install a small package to generate package-lock.json
npm install lodash@4.17.21
```

### 2. Run the mirror script

```bash
# Run the mirror script from the code-artifact directory
cd ../code-artifact
./npm-codeartifact-mirror.sh ../test-mirror/package-lock.json
```

### 3. Verify packages in CodeArtifact

```bash
# List packages in your repository
aws codeartifact list-packages \
  --domain npm-mirror-test \
  --repository cg-npm-packages \
  --format npm \
  --region $AWS_REGION

# List versions of a specific package
aws codeartifact list-package-versions \
  --domain npm-mirror-test \
  --repository cg-npm-packages \
  --format npm \
  --package lodash \
  --region $AWS_REGION

# For scoped packages, use the --namespace parameter
aws codeartifact list-package-versions \
  --domain npm-mirror-test \
  --repository cg-npm-packages \
  --format npm \
  --package fs-minipass \
  --namespace isaacs \
  --region $AWS_REGION
```

## Features

The mirroring script supports:
- **Regular npm packages** (e.g., `lodash`, `express`)
- **Scoped packages** (e.g., `@types/node`, `@babel/core`, `@isaacs/fs-minipass`)
- **Duplicate detection** - skips packages already in CodeArtifact
- **Attestation preservation** - npm package attestations are preserved during mirroring

## Test npm install from CodeArtifact

Configure npm to use your CodeArtifact repository:

```bash
# Get auth token
export CODEARTIFACT_AUTH_TOKEN=$(aws codeartifact get-authorization-token \
  --domain npm-mirror-test \
  --query authorizationToken \
  --output text \
  --region $AWS_REGION)

# Get repository endpoint
export CODEARTIFACT_REGISTRY=$(aws codeartifact get-repository-endpoint \
  --domain npm-mirror-test \
  --repository cg-npm-packages \
  --format npm \
  --query repositoryEndpoint \
  --output text \
  --region $AWS_REGION)

# Configure npm to use CodeArtifact
npm config set registry $CODEARTIFACT_REGISTRY
npm config set //$(echo $CODEARTIFACT_REGISTRY | sed 's|https://||')/:_authToken $CODEARTIFACT_AUTH_TOKEN

# Test install
npm install lodash
```

## Cleanup (Optional)

When you're done testing:

```bash
# Delete the repository
aws codeartifact delete-repository \
  --domain npm-mirror-test \
  --repository cg-npm-packages \
  --region $AWS_REGION

# Delete the domain
aws codeartifact delete-domain \
  --domain npm-mirror-test \
  --region $AWS_REGION
```

## Troubleshooting

### "Access Denied" errors
- Ensure your AWS IAM user/role has CodeArtifact permissions
- Required permissions: `codeartifact:*`, `sts:GetServiceBearerToken`

### "Package not found" in Chainguard
- Not all npm packages are available in Chainguard Libraries
- Chainguard curates packages for security
- Check the Chainguard catalog for available packages

### Authentication failures
- CodeArtifact tokens expire after 12 hours
- Re-run the auth token command if needed
- Ensure Chainguard credentials are correct

## Cost Considerations

AWS CodeArtifact pricing (as of 2024):
- **Storage**: $0.05 per GB per month
- **Requests**: $0.05 per 10,000 requests

For testing with a few packages, costs should be minimal (typically < $1/month).
