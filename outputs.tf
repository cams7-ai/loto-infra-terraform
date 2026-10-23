output "stack_outputs" {
  value = {
    mail      = aws_cloudformation_stack.mail.outputs
    gmail     = aws_cloudformation_stack.gmail.outputs
    whatsapp  = aws_cloudformation_stack.whatsapp.outputs
    bot       = aws_cloudformation_stack.bot.outputs
    scheduler = aws_cloudformation_stack.scheduler.outputs
  }
}

output "scheduler_states" {
  description = "Estados efetivos dos agendamentos, incluindo a pausa de manutenção."
  value = {
    RunBetState     = aws_cloudformation_stack.scheduler.parameters["RunBetState"]
    CheckDrawsState = aws_cloudformation_stack.scheduler.parameters["CheckDrawsState"]
  }
  sensitive = true
}
