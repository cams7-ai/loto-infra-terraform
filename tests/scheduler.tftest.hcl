# Sem credenciais ou chamadas AWS: as cinco stacks e a consulta EC2 são simuladas.
mock_provider "aws" {
  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        FunctionArn     = "arn:aws:lambda:us-east-1:123456789012:function:mail"
        ApiUrl          = "http://whatsapp.internal"
        InstanceId      = "i-0123456789abcdef0"
        SecurityGroupId = "sg-0123456789abcdef0"
      }
    }
  }
  mock_data "aws_instance" {
    defaults = {
      private_ip = "10.77.1.42"
    }
  }
}

variables {
  account_id  = "123456789012"
  stack_names = { mail = "mail", gmail = "gmail", whatsapp = "whatsapp", bot = "bot", scheduler = "scheduler" }
  parameters = {
    mail     = {}
    gmail    = {}
    whatsapp = {}
    bot      = {}
    scheduler = {
      RunBetState       = "ENABLED"
      CheckDrawsState   = "DISABLED"
      DynamoDbTableName = "existing-executions"
      RunBetCron        = "cron(30 10 ? * TUE,THU,SAT *)"
    }
  }
}

run "pause_and_wire_dependencies" {
  command = apply
  variables {
    scheduler_paused = true
  }
  assert {
    condition     = aws_cloudformation_stack.scheduler.parameters["RunBetState"] == "DISABLED" && aws_cloudformation_stack.scheduler.parameters["CheckDrawsState"] == "DISABLED"
    error_message = "A pausa deve desabilitar ambos os schedules."
  }
  assert {
    condition = (
      aws_cloudformation_stack.scheduler.parameters["LotoBotUrl"] == "http://10.77.1.42:80" &&
      aws_cloudformation_stack.scheduler.parameters["LotoBotSecurityGroupId"] == aws_cloudformation_stack.bot.outputs["SecurityGroupId"] &&
      aws_cloudformation_stack.scheduler.parameters["MailSenderArn"] == aws_cloudformation_stack.mail.outputs["FunctionArn"]
    )
    error_message = "O scheduler deve usar as dependências atuais do bot e mail-sender."
  }
}

run "resume_preserves_configured_states_and_table" {
  command = apply
  override_data {
    target = data.aws_instance.bot
    values = {
      private_ip = "10.77.1.99"
    }
  }
  variables {
    scheduler_paused = false
  }
  assert {
    condition     = output.scheduler_states.RunBetState == "ENABLED" && output.scheduler_states.CheckDrawsState == "DISABLED"
    error_message = "Liberar a pausa deve restaurar cada estado configurado, sem ativar ambos indiscriminadamente."
  }
  assert {
    condition     = aws_cloudformation_stack.scheduler.parameters["DynamoDbTableName"] == "existing-executions" && aws_cloudformation_stack.scheduler.parameters["RunBetCron"] == "cron(30 10 ? * TUE,THU,SAT *)"
    error_message = "Tabela e cron com espaços/vírgulas devem ser preservados."
  }
  assert {
    condition     = aws_cloudformation_stack.scheduler.parameters["LotoBotUrl"] == "http://10.77.1.99:80"
    error_message = "A URL deve acompanhar a troca do IP privado do bot."
  }
}

run "missing_states_default_to_disabled" {
  command = apply
  variables {
    parameters = {
      mail      = {}, gmail = {}, whatsapp = {}, bot = {}
      scheduler = { DynamoDbTableName = "existing-executions" }
    }
  }
  assert {
    condition     = output.scheduler_states.RunBetState == "DISABLED" && output.scheduler_states.CheckDrawsState == "DISABLED"
    error_message = "Parâmetros de estado ausentes devem manter os schedules desabilitados."
  }
}
