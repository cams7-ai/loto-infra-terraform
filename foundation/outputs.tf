output "configuration" {
  description = "Dados públicos da fundação usados por scripts/configure-new.sh."
  value = {
    account_id                    = var.account_id
    region                        = var.region
    name                          = var.name
    vpc_id                        = aws_vpc.main.id
    subnet_id                     = aws_subnet.main.id
    route_table_id                = aws_route_table.main.id
    integration_security_group_id = aws_security_group.integration.id
    lambda_endpoint_sg_id         = aws_security_group.endpoints.id
    artifact_bucket               = aws_s3_bucket.artifacts.id
    key_name                      = aws_key_pair.ssh.key_name
    ssh_ipv6_cidr                 = var.ssh_ipv6_cidr
    ami_id                        = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
    application_secret_arn        = aws_secretsmanager_secret.application.arn
    gmail_secret_arn              = aws_secretsmanager_secret.gmail.arn
    bets_table                    = aws_dynamodb_table.bets.name
    executions_table              = aws_dynamodb_table.executions.name
    ses_from                      = var.ses_from
  }
}
