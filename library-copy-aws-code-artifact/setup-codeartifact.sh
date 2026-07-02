#!/bin/bash

# setup-codeartifact.sh
# Helper script to set up AWS CodeArtifact domain and npm repository

set -e

# Configuration (customize these)
DOMAIN_NAME="${CODEARTIFACT_DOMAIN:-npm-mirror-test}"
REPOSITORY_NAME="${CODEARTIFACT_REPOSITORY:-cg-npm-packages}"
AWS_REGION="${AWS_REGION:-us-west-2}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AWS CodeArtifact Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}ERROR: AWS CLI is not installed.${NC}"
    echo "Please install it from: https://aws.amazon.com/cli/"
    exit 1
fi

# Check AWS credentials
echo -e "${YELLOW}Checking AWS credentials...${NC}"
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}ERROR: AWS credentials not configured.${NC}"
    echo "Please run: aws configure"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✓ AWS Account ID: ${ACCOUNT_ID}${NC}"
echo ""

# Create CodeArtifact domain
echo -e "${YELLOW}Creating CodeArtifact domain: ${DOMAIN_NAME}${NC}"
if aws codeartifact describe-domain \
    --domain "$DOMAIN_NAME" \
    --region "$AWS_REGION" &> /dev/null; then
    echo -e "${GREEN}✓ Domain '${DOMAIN_NAME}' already exists${NC}"
else
    aws codeartifact create-domain \
        --domain "$DOMAIN_NAME" \
        --region "$AWS_REGION" > /dev/null
    echo -e "${GREEN}✓ Domain '${DOMAIN_NAME}' created${NC}"
fi
echo ""

# Create CodeArtifact repository
echo -e "${YELLOW}Creating CodeArtifact repository: ${REPOSITORY_NAME}${NC}"
if aws codeartifact describe-repository \
    --domain "$DOMAIN_NAME" \
    --repository "$REPOSITORY_NAME" \
    --region "$AWS_REGION" &> /dev/null; then
    echo -e "${GREEN}✓ Repository '${REPOSITORY_NAME}' already exists${NC}"
else
    aws codeartifact create-repository \
        --domain "$DOMAIN_NAME" \
        --repository "$REPOSITORY_NAME" \
        --description "npm packages mirror from Chainguard" \
        --region "$AWS_REGION" > /dev/null
    echo -e "${GREEN}✓ Repository '${REPOSITORY_NAME}' created${NC}"
fi
echo ""

# Get repository endpoint
REPO_ENDPOINT=$(aws codeartifact get-repository-endpoint \
    --domain "$DOMAIN_NAME" \
    --repository "$REPOSITORY_NAME" \
    --format npm \
    --region "$AWS_REGION" \
    --query repositoryEndpoint \
    --output text)

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Domain: ${GREEN}${DOMAIN_NAME}${NC}"
echo -e "Repository: ${GREEN}${REPOSITORY_NAME}${NC}"
echo -e "Region: ${GREEN}${AWS_REGION}${NC}"
echo -e "Endpoint: ${GREEN}${REPO_ENDPOINT}${NC}"
echo ""
echo -e "${YELLOW}Export these environment variables to use with the mirror script:${NC}"
echo ""
echo -e "${BLUE}export AWS_REGION=\"${AWS_REGION}\"${NC}"
echo -e "${BLUE}export CODEARTIFACT_DOMAIN=\"${DOMAIN_NAME}\"${NC}"
echo -e "${BLUE}export CODEARTIFACT_REPOSITORY=\"${REPOSITORY_NAME}\"${NC}"
echo -e "${BLUE}export CODEARTIFACT_DOMAIN_OWNER=\"${ACCOUNT_ID}\"${NC}"
echo ""
echo -e "${YELLOW}Don't forget to also set your Chainguard credentials:${NC}"
echo -e "${BLUE}export CGR_USER=\"your-chainguard-user\"${NC}"
echo -e "${BLUE}export CGR_TOKEN=\"your-chainguard-token\"${NC}"
echo ""