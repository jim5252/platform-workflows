# Run once, locally, with your own AWS profile. Creates everything the
# pipeline needs so GitHub Actions never holds a stored AWS key.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "github_owner" {
  type        = string
  description = "Your GitHub username"
}

variable "repo" {
  type    = string
  default = "payments-infra"
}

variable "state_bucket" {
  type    = string
  default = "jim-gha-demo-tfstate"
}

locals {
  repo_full     = "${var.github_owner}/${var.repo}"
  managed_arns  = ["arn:aws:s3:::payments-statements-*", "arn:aws:s3:::payments-statements-*/*"]
  state_arns    = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  oidc_provider = aws_iam_openid_connect_provider.github.arn
}

# --- GitHub OIDC identity provider (one per AWS account) ---------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Remote state, locked with S3 native lockfiles -------------------------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Plan role: pull requests only, read-only on infra ------------------------
data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo_full}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "gha-payments-infra-plan"
  assume_role_policy = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadManagedBuckets"
    actions   = ["s3:Get*", "s3:List*"]
    resources = local.managed_arns
  }
  statement {
    sid       = "StateAccess"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.state_arns
  }
}

resource "aws_iam_role_policy" "plan" {
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# --- Apply role: only the production environment of this one repo ------------
data "aws_iam_policy_document" "trust_apply" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo_full}:environment:production"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "gha-payments-infra-apply"
  assume_role_policy = data.aws_iam_policy_document.trust_apply.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ManagePaymentsBuckets"
    actions   = ["s3:*"]
    resources = local.managed_arns
  }
  statement {
    sid       = "StateAccess"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.state_arns
  }
}

resource "aws_iam_role_policy" "apply" {
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

output "plan_role_arn" { value = aws_iam_role.plan.arn }
output "apply_role_arn" { value = aws_iam_role.apply.arn }
output "state_bucket" { value = aws_s3_bucket.state.bucket }

# --- Stand-in for the print vendor's role (for the demo story) ---------------
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "vendor" {
  name = "vendor-print-reader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
    }]
  })
}

output "vendor_role_arn" { value = aws_iam_role.vendor.arn }
