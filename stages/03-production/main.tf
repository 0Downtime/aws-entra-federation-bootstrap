resource "aws_secretsmanager_secret" "production" {
  name                    = var.secret_name
  description             = "Baseline secret container for production workloads. Secret values are managed outside this repository."
  recovery_window_in_days = 30

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

data "aws_iam_policy_document" "production_secrets" {
  statement {
    sid    = "ReadSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]

    resources = [aws_secretsmanager_secret.production.arn]
  }

  statement {
    sid    = "WriteSecretValue"
    effect = "Allow"

    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]

    resources = [aws_secretsmanager_secret.production.arn]
  }
}

resource "aws_iam_policy" "production_secrets" {
  count = length(var.production_trusted_principal_arns) == 0 ? 0 : 1

  name        = "ProductionSecretAccess"
  description = "Least-privilege access to the baseline production secret."
  policy      = data.aws_iam_policy_document.production_secrets.json
}

resource "aws_iam_role" "production_secrets" {
  count = length(var.production_trusted_principal_arns) == 0 ? 0 : 1

  name = "ProductionSecretAccess"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.production_trusted_principal_arns }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "production_secrets" {
  count = length(var.production_trusted_principal_arns) == 0 ? 0 : 1

  role       = aws_iam_role.production_secrets[0].name
  policy_arn = aws_iam_policy.production_secrets[0].arn
}
