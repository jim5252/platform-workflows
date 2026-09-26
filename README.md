# platform-workflows

The platform team's standard delivery pipeline for Terraform on AWS, plus the one-time AWS setup it depends on.

Product teams don't write their own pipelines. They call this one, so every team gets the same security checks, the same plan-on-PR review and the same approval gate before production, without storing any AWS credentials in GitHub.

## What's here

```text
.github/workflows/terraform.yml   Reusable pipeline: policy → plan → apply
bootstrap/main.tf                 One-time AWS setup: OIDC trust, state bucket, IAM roles
```

## Using the pipeline

A team's entire workflow file:

```yaml
name: deploy
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write
  pull-requests: write

jobs:
  terraform:
    uses: jim5252/platform-workflows/.github/workflows/terraform.yml@v1
    with:
      plan-role-arn: arn:aws:iam::<account-id>:role/<team>-plan
      apply-role-arn: arn:aws:iam::<account-id>:role/<team>-apply
```

### Inputs

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `plan-role-arn` | yes | | Read-only role assumed on pull requests |
| `apply-role-arn` | yes | | Role assumed on `main`, after approval |
| `working-directory` | no | `.` | Folder holding the Terraform |
| `aws-region` | no | `eu-west-2` | AWS region |
| `terraform-version` | no | `1.16.4` | Terraform version to install |

## What the pipeline does

| Job | Runs on | What it does |
| --- | --- | --- |
| **policy** | Every PR and push | Runs Checkov against the platform security baseline. A failure blocks the merge. |
| **plan** | Pull requests | Gets short-lived AWS credentials through OIDC, runs `terraform plan` and posts the result as a PR comment |
| **apply** | Pushes to `main` | Waits for approval on the `production` environment, then gets credentials through OIDC and applies. One apply at a time per repo. |

### Security baseline for S3

| Check | Requirement |
| --- | --- |
| `CKV_AWS_53` | Block public ACLs |
| `CKV_AWS_54` | Block public bucket policies |
| `CKV_AWS_55` | Ignore public ACLs |
| `CKV_AWS_56` | Restrict public buckets |
| `CKV2_AWS_6` | Every bucket has a public access block |
| `CKV_AWS_21` | Versioning enabled |
| `CKV_AWS_145` | Encrypted with KMS by default |

## Security design

- **No stored credentials.** Each job asks GitHub for an OIDC token, and AWS STS swaps it for credentials that last for that one run.
- **Narrow trust.** The plan role only trusts pull requests from the team's repo. The apply role only trusts that repo's `production` environment, so a copied workflow in any other repo is refused.
- **Least privilege per job.** Each job requests only the GitHub token permissions it needs, and only plan and apply can request an OIDC token.
- **Pinned actions.** Every third-party action is pinned to a full commit SHA, with the version in a comment, so a moved tag can't change what runs.
- **Human approval for production.** Required reviewers on the `production` environment, plus branch rules requiring a PR and passing checks.
- **Audit trail.** Every run is in the Actions history, and every role assumption is in CloudTrail with the run ID in the session name.

## Versioning

Teams call a tag, not a branch: `@v1`. Changes to the pipeline are tested and released as a new tag, so teams choose when to upgrade.

## Bootstrap: one-time AWS setup

The pipeline authenticates with OIDC, so the trust it relies on has to exist before it can run. A platform engineer runs `bootstrap/` once, locally, with admin credentials.

| Resource | Purpose |
| --- | --- |
| GitHub OIDC provider | Lets AWS trust tokens issued by GitHub Actions |
| Terraform state bucket | Remote state for team repos: versioned, public access blocked, S3 native locking |
| `gha-payments-infra-plan` | Read-only role for pull requests |
| `gha-payments-infra-apply` | Role for production applies, limited to `payments-statements-*` buckets |

```bash
aws sts get-caller-identity          # confirm the target account
cd bootstrap
echo 'github_owner = "jim5252"' > terraform.tfvars
terraform init && terraform apply
```

If the account already has a GitHub OIDC provider, import it rather than creating a second one:

```bash
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
```

Local state files are git-ignored. For anything beyond a demo, move the bootstrap state to a remote backend too.

## Onboarding a new team

1. Add a plan and apply role pair for the team's repo in `bootstrap/`, scoped to the resources that team owns, then apply.
2. The team adds the workflow file above, with their role ARNs.
3. In the team's repo, add the `production` environment with required reviewers, and a ruleset on `main` requiring the `terraform / policy` and `terraform / plan` checks.