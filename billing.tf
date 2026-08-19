resource "aws_iam_policy" "billing_read_write" {
  name        = "BillingReadWriteAccess"
  description = "Allows read and write access to billing and cost management in the management account"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BillingRead"
        Effect = "Allow"
        Action = [
          "aws-portal:ViewBilling",
          "aws-portal:ViewUsage",
          "aws-portal:ViewPaymentMethods",
          "aws-portal:ViewAccount",
          "budgets:ViewBudget",
          "budgets:DescribeBudgetActionsForBudget",
          "budgets:DescribeBudgets",
          "budgets:DescribeBudgetAction",
          "ce:GetCostAndUsage",
          "ce:GetCostForecast",
          "ce:GetUsageForecast",
          "ce:GetDimensionValues",
          "ce:GetTags",
          "ce:GetCostAndUsageWithResources",
          "ce:DescribeReport",
          "ce:ListCostCategoryDefinitions",
          "ce:GetCostCategories"
        ]
        Resource = "*"
      },
      {
        Sid    = "BillingWrite"
        Effect = "Allow"
        Action = [
          "budgets:CreateBudget",
          "budgets:UpdateBudget",
          "budgets:DeleteBudget",
          "budgets:CreateBudgetAction",
          "budgets:UpdateBudgetAction",
          "budgets:DeleteBudgetAction",
          "budgets:ExecuteBudgetAction",
          "budgets:TagResource",
          "budgets:UntagResource",
          "aws-portal:ModifyBilling",
          "aws-portal:ModifyPaymentMethods"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "billing_read_write" {
  name = "BillingReadWriteRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "billing_read_write" {
  role       = aws_iam_role.billing_read_write.name
  policy_arn = aws_iam_policy.billing_read_write.arn
}
