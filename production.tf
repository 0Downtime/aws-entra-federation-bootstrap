
data "aws_caller_identity" "production" {
  provider = aws.production
}

resource "aws_iam_policy" "production_secretsmanager_rw" {
  provider    = aws.production
  name        = "ProductionSecretsManagerReadWrite"
  description = "Allows read and write access to Secrets Manager in the production account"
  tags = {
    Environment = "production"
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListAndRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:ListSecrets",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = "*"
      },
      {
        Sid    = "WriteSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:RestoreSecret",
          "secretsmanager:TagResource",
          "secretsmanager:UntagResource"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.production.account_id}:secret:*"
      }
    ]
  })
}

resource "aws_iam_role" "production_secretsmanager_rw" {
  provider = aws.production
  name     = "ProductionSecretsManagerReadWriteRole"
  tags = {
    Environment = "production"
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.production.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "production_secretsmanager_rw" {
  provider   = aws.production
  role       = aws_iam_role.production_secretsmanager_rw.name
  policy_arn = aws_iam_policy.production_secretsmanager_rw.arn
}

resource "aws_secretsmanager_secret" "production_secret_manager" {
  provider    = aws.production
  name        = "production-secrets-manager"
  description = "Provision a Secrets Manager secret in the production account to enable AWS Secrets Manager usage."
  tags = {
    Environment = "production"
  }
}
