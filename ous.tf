resource "aws_organizations_organizational_unit" "Security" {
  name      = "Security"
  parent_id = aws_organizations_organization.organization.roots[0].id
}

resource "aws_organizations_organizational_unit" "Infrastructure" {
  name      = "Infrastructure"
  parent_id = aws_organizations_organization.organization.roots[0].id
}

resource "aws_organizations_organizational_unit" "Workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.organization.roots[0].id
}
