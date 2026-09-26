# platform-workflows

The platform team's standard delivery pipeline for Terraform on AWS, plus the one-time AWS setup it depends on.

Product teams don't write their own pipelines. They call this one, so every team gets the same security checks, the same plan-on-PR review and the same approval gate before production, without storing any AWS credentials in GitHub.

## What's here

```text
.github/workflows/terraform.yml   Reusable pipeline: policy → plan → apply
.github/dependabot.yml            Weekly update PRs for the pinned actions
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
| **policy** | Every PR and push | Runs Checkov against the platform security baseline. A failure blocks the merge, and plan never runs. |
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

Granting a named AWS role access with a bucket policy is compatible with this baseline. The public access block only stops policies that grant access to everyone.

## Security design

- **No stored credentials.** Each job asks GitHub for an OIDC token, and AWS STS swaps it for credentials that last for that one run.
- **Trust tied to permanent IDs.** GitHub's token identifies the repo by name *and* by its permanent numeric ID, for example `repo:jim5252@43724760/payments-infra@1389707864:environment:production`. The roles trust that exact value, so a renamed repo, or a deleted repo recreated with the same name, can't inherit access.
- **Narrow trust per job.** The plan role only trusts pull requests from the team's repo. The apply role only trusts that repo's `production` environment.
- **Least privilege per job.** Each job requests only the GitHub token permissions it needs, and only plan and apply can request an OIDC token.
- **Pinned, allow-listed actions.** Every third-party action is pinned to a full commit SHA, with the version in a comment. Team repos allow only GitHub-created actions plus the two named actions this pipeline uses. Dependabot raises weekly PRs when a pinned action has an update.
- **Human approval for production.** Required reviewers on the `production` environment, plus a branch ruleset requiring a PR and passing checks, with no bypass.
- **Audit trail.** Every run is in the Actions history, and every role assumption is in CloudTrail with the run ID in the session name (`gha-apply-<run id>`).

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
| `vendor-print-reader` | Example third-party role, granted read access by the Payments team |

### Running it

The roles trust the team repo by its permanent IDs, so look those up first:

```bash
gh api repos/jim5252/payments-infra --jq '"owner_id=\(.owner.id) repo_id=\(.id)"'
```

```bash
aws sts get-caller-identity          # confirm the target account
cd bootstrap
cat > terraform.tfvars <<'EOF'
github_owner    = "jim5252"
github_owner_id = "<owner_id>"
repo_id         = "<repo_id>"
EOF
terraform init && terraform apply
```

If the account already has a GitHub OIDC provider, import it rather than creating a second one:

```bash
terraform import aws_iam_openid_connect_provider.github \
  arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
```

Local state files are git-ignored. For anything beyond a demo, move the bootstrap state to a remote backend too.

### Troubleshooting: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

The token's subject didn't match the role's trust policy. Find what GitHub actually sent in CloudTrail, then compare it with the trust policy:

```bash
aws cloudtrail lookup-events --region eu-west-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --query 'Events[].CloudTrailEvent' --output text \
  | jq '{error: .errorCode, sub: .userIdentity.userName}'
```

## Onboarding a new team

1. Add a plan and apply role pair for the team's repo in `bootstrap/`, using the repo's owner and repo IDs, scoped to the resources that team owns. Then apply.
2. The team adds the workflow file above, with their role ARNs.
3. In the team's repo:
   - add a `production` environment with required reviewers, limited to `main`;
   - add a ruleset on `main` requiring a PR plus the `terraform / policy` and `terraform / plan` checks, with no bypass;
   - add the Actions allow-list.