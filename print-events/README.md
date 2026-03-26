# print-events

This example deploys an AWS Lambda function that subscribes to events from a
Chainguard organization and logs structured information about each event to
CloudWatch.

```
START RequestId: 4f655d07-0fb9-427d-8d87-f690c816cc5b Version: $LATEST
TYPE: dev.chainguard.api.platform.registry.repo.created.v1
IDENTITY_ID: af2e0885544401049c4b2bbea8d9aaff297a76b2
EMAIL: user.name@your.org
NAME: nginx
BODY: {"actor": {"subject": "af2e08....}
REPORT RequestId: 4f655d07-0fb9-427d-8d87-f690c816cc5b    Duration: 1.38 ms       Billed Duration: 2 ms   Memory Size: 128 MB     Max Memory Used: 83 MB
END RequestId: 4f655d07-0fb9-427d-8d87-f690c816cc5b
```

It is written in Python and demonstrates using the API to resolve useful details
that are not present in the original event.

## Requirements

- [Terraform](https://developer.hashicorp.com/terraform/install)
- [Docker](https://docs.docker.com/get-docker/) with the daemon running
- The `aws` CLI
- An AWS account with credentials configured (e.g. via `aws configure` or
  environment variables)
- A Chainguard account with an organization. You can sign up at
  [console.chainguard.dev](https://console.chainguard.dev).
- The `chainctl` CLI


## Deployment

1. Authenticate to AWS and AWS ECR

  ```
  aws sso login
  aws ecr get-login-password --region <region> | \
    docker login --username AWS --password-stdin \
    <account-id>.dkr.ecr.<region>.amazonaws.com
  ```

2. Authenticate to Chainguard

  ```
  chainctl auth login
  ```

3. Create `iac/terraform.tfvars` and set your Chainguard organization name:

  ```hcl
  org_name = "your.org"

  # Optional. Limit processing to specific CloudEvents types. If omitted, all
  # event types are processed.
  # ce_types = ["dev.chainguard.api.platform.registry.repo.created.v1"]
  ```

2. Initialize Terraform:

   ```
   cd iac
   terraform init
   ```

3. Apply:

   ```
   terraform apply
   ```

   Terraform will build and push the container image, then provision all AWS
   and Chainguard resources. The Lambda function URL is printed as an output:

   ```
   url = "https://<id>.lambda-url.<region>.on.aws/"
   ```

   Chainguard will begin delivering events to this URL immediately after the
   subscription is created.

## Viewing logs

Logs are written to CloudWatch under the log group
`/aws/lambda/print-events`. You can tail them with the AWS CLI:

```
aws logs tail /aws/lambda/print-events --follow
```
