# ECS Demo – Infrastructure (Terraform)

Owned by the **cloud / DevOps** persona. Provisions, in the default VPC (us-east-1):

- ECS cluster (Fargate) with 2 services: `upload` (port 5000) and `message` (port 5001)
- 2 ECR repositories (`ecs-demo-upload`, `ecs-demo-message`)
- S3 bucket (uploads) and SQS queue (messages)
- IAM: shared task-execution role, plus least-privilege task roles
  (upload → `s3:PutObject` on the bucket; message → `sqs:SendMessage` on the queue)
- CloudWatch log groups

## Remote state

State lives in the existing S3 bucket, configured in `versions.tf`:

| Setting | Value |
|---------|-------|
| Bucket  | `sctp-tfstate-ce13` |
| Region  | `us-east-1` |
| Key     | `ecs-demo/terraform.tfstate` |
| Locking | S3 native (`use_lockfile = true`, requires Terraform 1.10+) |

## One-time setup

1. The Terraform state bucket `sctp-tfstate-ce13` already exists in us-east-1 (enable versioning if it isn't on yet).
2. Create an IAM role for GitHub Actions trusting GitHub OIDC for this repo.
3. In the repo settings add:
   - Secret: `AWS_ROLE_ARN`
   - Variable (optional): `AWS_REGION` (defaults to `us-east-1`)
4. Protect `main`: `./protect-main.sh <owner>/<repo> validate plan`
5. Add the App developer as a collaborator so they can review PRs.

## Workflow

- **CI** (`ci.yml`, on PR to `main`): fmt, validate, TFLint, Checkov, then `terraform plan` posted as a PR comment.
- **CD** (`cd.yml`, manual `workflow_dispatch`): `terraform apply` (or destroy) against the single environment.

Both workflows must use Terraform 1.10 or later and AWS region `us-east-1`.

## First deploy note

Services reference `:latest` in ECR. Until the app repo pushes its first images,
tasks will fail to pull and ECS will keep retrying; this resolves itself once the
app CD pipeline has run. Fetch outputs with `terraform output`: the app repo needs
the cluster name, service names and ECR repo names.

## Local use

With AWS credentials configured for us-east-1:

```bash
terraform init
terraform plan
```

