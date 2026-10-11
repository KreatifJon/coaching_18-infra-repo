data "aws_caller_identity" "current" {}

# ---------- Default VPC ----------
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["sctp-vpc-ce13"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  filter {
    name   = "tag:Name"
    values = ["sctp-vpc-ce13-public-*"]
  }
}
# ---------- KMS (shared key for ECR + CloudWatch Logs) ----------
resource "aws_kms_key" "main" {
  description         = "${var.project} encryption key"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------- Security group ----------
resource "aws_security_group" "services" {
  name        = "${var.project}-services"
  description = "Allow inbound to the two demo services"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "Upload service"
    from_port   = var.upload_port
    to_port     = var.upload_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Message service"
    from_port   = var.message_port
    to_port     = var.message_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS only: ECR image pull, CloudWatch Logs, S3 and SQS are all reached over 443
  egress {
    description = "HTTPS outbound to AWS service endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- ECR ----------
resource "aws_ecr_repository" "upload" {
  name                 = "${var.project}-upload"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

resource "aws_ecr_repository" "message" {
  name                 = "${var.project}-message"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

# ---------- S3 + SQS ----------
resource "aws_s3_bucket" "uploads" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not needed for a demo bucket
  #checkov:skip=CKV_AWS_18:Access logging needs a dedicated log bucket; out of scope for the demo
  #checkov:skip=CKV2_AWS_62:No event consumer for this bucket
  bucket        = "${var.project}-uploads-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket     = aws_s3_bucket.uploads.id
  depends_on = [aws_s3_bucket_versioning.uploads]

  rule {
    id     = "cleanup"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_sqs_queue" "messages" {
  name                    = "${var.project}-messages"
  sqs_managed_sse_enabled = true
}

# ---------- Logs ----------
resource "aws_cloudwatch_log_group" "upload" {
  name              = "/ecs/${var.project}-upload"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "message" {
  name              = "/ecs/${var.project}-message"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull images from ECR, write logs
resource "aws_iam_role" "execution" {
  name               = "${var.project}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: upload service -> S3 PutObject only
resource "aws_iam_role" "upload_task" {
  name               = "${var.project}-upload-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "upload_task" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
  }

  statement {
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "upload_task" {
  name   = "s3-put"
  role   = aws_iam_role.upload_task.id
  policy = data.aws_iam_policy_document.upload_task.json
}

# Task role: message service -> SQS SendMessage only
resource "aws_iam_role" "message_task" {
  name               = "${var.project}-message-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "message_task" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.messages.arn]
  }
}

resource "aws_iam_role_policy" "message_task" {
  name   = "sqs-send"
  role   = aws_iam_role.message_task.id
  policy = data.aws_iam_policy_document.message_task.json
}

# ---------- ECS ----------
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "upload" {
  family                   = "${var.project}-upload"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.upload_task.arn

  container_definitions = jsonencode([{
    name         = "upload"
    image        = "${aws_ecr_repository.upload.repository_url}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = var.upload_port, protocol = "tcp" }]
    environment = [
      { name = "BUCKET_NAME", value = aws_s3_bucket.uploads.bucket },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "PORT", value = tostring(var.upload_port) },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.upload.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "upload"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "message" {
  family                   = "${var.project}-message"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.message_task.arn

  container_definitions = jsonencode([{
    name         = "message"
    image        = "${aws_ecr_repository.message.repository_url}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = var.message_port, protocol = "tcp" }]
    environment = [
      { name = "QUEUE_URL", value = aws_sqs_queue.messages.url },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "PORT", value = tostring(var.message_port) },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.message.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "message"
      }
    }
  }])
}

resource "aws_ecs_service" "upload" {
  #checkov:skip=CKV_AWS_333:Demo runs in the default VPC with no NAT; public IP is needed to pull images and receive traffic
  name            = "${var.project}-upload"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.upload.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.services.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_service" "message" {
  #checkov:skip=CKV_AWS_333:Demo runs in the default VPC with no NAT; public IP is needed to pull images and receive traffic
  name            = "${var.project}-message"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.message.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.services.id]
    assign_public_ip = true
  }
}