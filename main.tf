locals {
  region             = "ap-northeast-1"
  product            = "example"
  env                = "poc"
  prefix             = "${local.product}-${local.env}-"
  account_id         = data.aws_caller_identity.current.account_id
  firelens_log_group = "firelens-container"
}

provider "aws" {
  region = local.region

  default_tags {
    tags = {
      env     = local.env
      product = local.product
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  cidr_block         = "10.0.0.0/16"
  azs                = toset(data.aws_availability_zones.available.names)
  use_private_subnet = false
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block = local.cidr_block

  tags = {
    Name = "${local.product}-${local.env}"
  }
}

resource "aws_subnet" "public" {
  for_each = local.azs

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(aws_vpc.this.cidr_block, 4, index(tolist(local.azs), each.key))
  availability_zone = each.key

  tags = {
    Name = "${local.prefix}public-${each.value}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "this" {
  vpc_id = aws_vpc.this.id

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "allow_all"
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${local.prefix}app"
}

resource "aws_ecs_service" "this" {
  name            = local.product
  cluster         = aws_ecs_cluster.this.id
  desired_count   = 2
  launch_type     = "FARGATE"
  task_definition = data.aws_ecs_task_definition.current.arn

  network_configuration {
    subnets          = [for x in aws_subnet.public : x.id]
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = true
  }
}

data "aws_ecs_task_definition" "current" {
  task_definition = aws_ecs_task_definition.this.family
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.product
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions    = jsonencode([local.firelens, local.app])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

resource "aws_iam_role_policy_attachment" "task" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task.arn
}

resource "aws_iam_role" "task" {
  name               = "${local.prefix}ecs-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${local.region}:${local.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "task" {
  name   = "${local.prefix}ecs-task"
  policy = data.aws_iam_policy_document.task.json
}

data "aws_iam_policy_document" "task" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log.arn}/*"]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.conf.arn,
      "${aws_s3_bucket.conf.arn}/*.conf"
    ]
  }
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = aws_iam_policy.execution.arn
}

resource "aws_iam_role" "execution" {
  name               = "${local.prefix}ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.execution_assume.json
}

data "aws_iam_policy_document" "execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${local.region}:${local.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "execution" {
  name   = "${local.prefix}ecs-execution"
  policy = data.aws_iam_policy_document.execution.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }
}

locals {
  firelens = {
    essential = true
    image     = "public.ecr.aws/aws-observability/aws-for-fluent-bit:init-2.32.4"
    name      = "log_router"

    environment = [
      {
        name  = "aws_fluent_bit_init_s3_1"
        value = "${aws_s3_bucket.conf.arn}/extra.conf"
      }
    ]

    firelensConfiguration = {
      type = "fluentbit"
    }

    logConfiguration = {
      logDriver = "awslogs"

      options = {
        awslogs-group         = local.firelens_log_group
        awslogs-region        = local.region
        awslogs-create-group  = "true"
        awslogs-stream-prefix = "firelens"
      }
    }

    memoryReservation = 50
  }

  app = {
    essential = true
    image     = "httpd"
    name      = "app"

    logConfiguration = {
      logDriver = "awsfirelens"

      options = {
        Name            = "s3"
        region          = local.region
        bucket          = aws_s3_bucket.log.id
        total_file_size = "1M"
        upload_timeout  = "1m"
        use_put_object  = "On"
        retry_limit     = "2"
      }
    }

    portMappings = [
      {
        containerPort = 80
        hostPort      = 80
        protocol      = "tcp"
      }
    ]

    memoryReservation = 100
  }
}

resource "aws_s3_bucket" "conf" {
  bucket        = "${local.prefix}fluent-bit-conf-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "conf" {
  bucket = aws_s3_bucket.conf.id
  key    = "extra.conf"

  content = templatefile("${path.module}/extra.conf.tftpl", {
    log_group_region  = local.region
    log_group_name    = aws_cloudwatch_log_group.firelens.name
    log_bucket_region = local.region
    log_bucket_name   = aws_s3_bucket.log.id
  })

  content_type = "plain/text"
}

resource "aws_cloudwatch_log_group" "firelens" {
  name              = local.firelens_log_group
  retention_in_days = 3
}

resource "aws_s3_bucket" "log" {
  bucket        = "${local.prefix}ecs-logs-${local.account_id}"
  force_destroy = true
}
