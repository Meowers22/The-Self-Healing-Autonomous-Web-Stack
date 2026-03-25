data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  common_tags = {
    Project   = "Autonomous-Web"
    ManagedBy = "Terraform"
    Pattern   = "Self-Healing"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  # DNS support enables health-aware service discovery and resilient private-to-public dependency resolution.
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-${count.index + 1}"
    Tier = "Public"
  })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index + 8)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-${count.index + 1}"
    Tier = "Private"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  # Single NAT is a deliberate trade-off for baseline cost; private workloads still preserve outbound-only patch/update paths.
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow internet HTTP to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-sg"
  })
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Allow HTTP only from ALB SG"
  vpc_id      = aws_vpc.main.id

  # Enforcing least privilege by restricting ASG ingress strictly to the ALB security group.
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2-sg"
  })
}

resource "aws_lb" "web" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb"
  })
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-tg"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-listener-http"
  })
}

resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2-ssm-role"
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_ssm.name

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2-instance-profile"
  })
}

resource "aws_launch_template" "web" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]
  user_data              = base64encode(file("${path.module}/scripts/userdata.sh"))

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-web"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-web-volume"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-launch-template"
  })
}

resource "aws_autoscaling_group" "web" {
  name                = "${var.project_name}-asg"
  desired_capacity    = 2
  min_size            = 2
  max_size            = 4
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.web.arn]
  health_check_type   = "ELB"

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances"
  ]
  metrics_granularity = "1Minute"

  # Lifecycle controls reduce service churn during updates and force replacement before retirement.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 75
      instance_warmup        = 60
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = local.common_tags.Project
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = local.common_tags.ManagedBy
    propagate_at_launch = true
  }

  tag {
    key                 = "Pattern"
    value               = local.common_tags.Pattern
    propagate_at_launch = true
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_sns_topic" "latency_alerts" {
  name = "${var.project_name}-latency-alert"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-latency-alert"
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.latency_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.project_name}-alb-unhealthy-hosts"
  alarm_description   = "Autonomous remediation trigger when ALB reports more than one unhealthy target."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  period              = 10
  statistic           = "Maximum"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-unhealthy-hosts-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.project_name}-alb-latency-high"
  alarm_description   = "Latency SLO alert for proactive performance triage."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 0.2
  period              = 60
  statistic           = "Average"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.latency_alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-latency-alarm"
  })
}

resource "aws_iam_role" "ssm_automation" {
  name = "${var.project_name}-ssm-automation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ssm-automation-role"
  })
}

resource "aws_iam_role_policy" "ssm_automation_refresh" {
  name = "${var.project_name}-ssm-automation-refresh-policy"
  role = aws_iam_role.ssm_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeInstanceRefreshes",
          "autoscaling:StartInstanceRefresh"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_ssm_document" "asg_instance_refresh" {
  name            = "${var.project_name}-asg-instance-refresh"
  document_type   = "Automation"
  document_format = "JSON"

  # Event-driven remediation uses a runbook to preserve auditability and safe, repeatable recovery semantics.
  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Start a safe ASG instance refresh when unhealthy host alarm fires."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      AutoScalingGroupName = {
        type        = "String"
        description = "ASG name to refresh"
      }
      AutomationAssumeRole = {
        type        = "String"
        description = "IAM role ARN assumed by automation"
      }
    }
    mainSteps = [
      {
        name   = "startInstanceRefresh"
        action = "aws:executeAwsApi"
        inputs = {
          Service              = "AutoScaling"
          Api                  = "StartInstanceRefresh"
          AutoScalingGroupName = "{{ AutoScalingGroupName }}"
          Preferences = {
            MinHealthyPercentage = 75
            InstanceWarmup       = 60
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-asg-instance-refresh-doc"
  })
}

resource "aws_iam_role" "eventbridge_start_automation" {
  name = "${var.project_name}-eventbridge-automation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-eventbridge-automation-role"
  })
}

resource "aws_iam_role_policy" "eventbridge_start_automation" {
  name = "${var.project_name}-eventbridge-start-automation-policy"
  role = aws_iam_role.eventbridge_start_automation.id

  # EventBridge is scoped to starting only the intended automation and passing only the approved execution role.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartAutomationExecution"
        ]
        Resource = aws_ssm_document.asg_instance_refresh.arn
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = aws_iam_role.ssm_automation.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "unhealthy_alarm_to_ssm" {
  name        = "${var.project_name}-unhealthy-alarm-remediation"
  description = "Invoke SSM automation when unhealthy host alarm enters ALARM state."

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.alb_unhealthy_hosts.alarm_name]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-unhealthy-alarm-remediation-rule"
  })
}

resource "aws_cloudwatch_event_target" "ssm_automation" {
  rule     = aws_cloudwatch_event_rule.unhealthy_alarm_to_ssm.name
  arn      = aws_ssm_document.asg_instance_refresh.arn
  role_arn = aws_iam_role.eventbridge_start_automation.arn

  input = jsonencode({
    AutoScalingGroupName = [aws_autoscaling_group.web.name]
    AutomationAssumeRole = [aws_iam_role.ssm_automation.arn]
  })
}
