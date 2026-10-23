# Fundação independente das stacks: não requer templates nem artefatos compilados.
data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
resource "aws_vpc" "main" {
  cidr_block                       = "10.77.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_support               = true
  enable_dns_hostnames             = true
  tags                             = { Name = var.name, Application = "loto-bot" }
  lifecycle { prevent_destroy = false }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}
resource "aws_subnet" "main" {
  vpc_id                          = aws_vpc.main.id
  availability_zone               = data.aws_availability_zones.available.names[0]
  cidr_block                      = "10.77.1.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, 0)
  assign_ipv6_address_on_creation = true
  map_public_ip_on_launch         = false
  tags                            = { Name = var.name }
}
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
}
resource "aws_route" "internet_ipv6" {
  route_table_id              = aws_route_table.main.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.main.id
}
resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}
resource "aws_security_group" "integration" {
  name        = "${var.name}-integration"
  description = "Source identity for bot to WhatsApp integrations"
  vpc_id      = aws_vpc.main.id
  egress {
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}
resource "aws_security_group" "endpoints" {
  name        = "${var.name}-endpoints"
  description = "HTTPS to private AWS endpoints from the application VPC"
  vpc_id      = aws_vpc.main.id
}
# Regra separada: o scheduler adiciona sua própria regra neste SG via CloudFormation.
# Não use ingress inline, para não remover regras de outra stack num apply da fundação.
resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = aws_vpc.main.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["cloudformation", "secretsmanager", "lambda"])
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.main.id]
  security_group_ids  = [aws_security_group.endpoints.id]
}
resource "aws_vpc_endpoint" "gateway" {
  for_each          = toset(["s3", "dynamodb"])
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.main.id]
}
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${var.account_id}-${var.region}"
  force_destroy = true
  lifecycle { prevent_destroy = false }
}
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_key_pair" "ssh" {
  key_name   = "${var.name}-ssh"
  public_key = file(pathexpand(var.ssh_public_key_path))
  lifecycle { prevent_destroy = false }
}
# Somente os contêineres; versões com valores são gravadas via CLI, fora do state.
resource "aws_secretsmanager_secret" "application" {
  name                    = "${var.name}/application"
  recovery_window_in_days = 30
  lifecycle { prevent_destroy = false }
}
resource "aws_secretsmanager_secret" "gmail" {
  name                    = "${var.name}/gmail-oauth-token"
  recovery_window_in_days = 30
  lifecycle { prevent_destroy = false }
}
resource "aws_ses_email_identity" "sender" {
  email = var.ses_from
}
resource "aws_dynamodb_table" "bets" {
  name                        = "${var.name}-bets"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "bet_id"
  deletion_protection_enabled = false
  attribute {
    name = "bet_id"
    type = "S"
  }
  point_in_time_recovery { enabled = true }
  lifecycle { prevent_destroy = false }
}
resource "aws_dynamodb_table" "executions" {
  name                        = "${var.name}-scheduler-executions"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  deletion_protection_enabled = false
  attribute {
    name = "pk"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  point_in_time_recovery { enabled = true }
  lifecycle { prevent_destroy = false }
}
