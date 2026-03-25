output "alb_dns_name" {
  description = "Public DNS name of the application load balancer."
  value       = aws_lb.web.dns_name
}

output "asg_name" {
  description = "Auto Scaling Group name hosting the private web tier."
  value       = aws_autoscaling_group.web.name
}

output "target_group_arn" {
  description = "Target group ARN used by ALB and ASG."
  value       = aws_lb_target_group.web.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for latency alerts."
  value       = aws_sns_topic.latency_alerts.arn
}

output "ssm_automation_document_name" {
  description = "SSM Automation document name used for autonomous remediation."
  value       = aws_ssm_document.asg_instance_refresh.name
}
