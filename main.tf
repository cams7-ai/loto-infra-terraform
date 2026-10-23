# CloudFormation mantém a propriedade dos recursos internos; Terraform controla as stacks.
resource "aws_cloudformation_stack" "mail" {
  name               = var.stack_names.mail
  template_body      = file("${path.module}/prepared/mail-sender-aws.yaml")
  parameters         = merge(var.parameters.mail, lookup(var.artifact_parameters, "mail", {}))
  capabilities       = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
  timeout_in_minutes = 45
  lifecycle { prevent_destroy = false }
}

resource "aws_cloudformation_stack" "gmail" {
  name               = var.stack_names.gmail
  template_body      = file("${path.module}/prepared/gmail-reader-aws.yaml")
  parameters         = merge(var.parameters.gmail, lookup(var.artifact_parameters, "gmail", {}))
  capabilities       = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
  timeout_in_minutes = 45
  lifecycle { prevent_destroy = false }
}

resource "aws_cloudformation_stack" "whatsapp" {
  name               = var.stack_names.whatsapp
  template_body      = file("${path.module}/prepared/whatsapp-notify.yaml")
  parameters         = merge(var.parameters.whatsapp, lookup(var.artifact_parameters, "whatsapp", {}))
  capabilities       = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
  timeout_in_minutes = 45
  lifecycle { prevent_destroy = false }
}

resource "aws_cloudformation_stack" "bot" {
  name          = var.stack_names.bot
  template_body = file("${path.module}/prepared/loto-bot.yaml")
  parameters = merge(var.parameters.bot, lookup(var.artifact_parameters, "bot", {}), {
    MailSenderFunctionArn  = aws_cloudformation_stack.mail.outputs["FunctionArn"]
    GmailReaderFunctionArn = aws_cloudformation_stack.gmail.outputs["FunctionArn"]
    WhatsAppNotifyUrl      = aws_cloudformation_stack.whatsapp.outputs["ApiUrl"]
  })
  capabilities       = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
  timeout_in_minutes = 45
  lifecycle { prevent_destroy = false }
}

# A leitura ocorre após a atualização da stack do bot, inclusive se a EC2 for substituída.
data "aws_instance" "bot" {
  instance_id = aws_cloudformation_stack.bot.outputs["InstanceId"]
}

resource "aws_cloudformation_stack" "scheduler" {
  name          = var.stack_names.scheduler
  template_body = file("${path.module}/prepared/loto-scheduler-aws.yaml")
  parameters = merge(var.parameters.scheduler, {
    LotoBotSecurityGroupId = aws_cloudformation_stack.bot.outputs["SecurityGroupId"]
    LotoBotUrl             = "http://${data.aws_instance.bot.private_ip}:80"
    LotoBotPort            = "80"
    MailSenderArn          = aws_cloudformation_stack.mail.outputs["FunctionArn"]
    RunBetState            = var.scheduler_paused ? "DISABLED" : lookup(var.parameters.scheduler, "RunBetState", "DISABLED")
    CheckDrawsState        = var.scheduler_paused ? "DISABLED" : lookup(var.parameters.scheduler, "CheckDrawsState", "DISABLED")
  })
  capabilities       = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
  timeout_in_minutes = 45
  lifecycle { prevent_destroy = false }
}
