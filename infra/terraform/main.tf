# ── Terraform config ──────────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Remote state: stored in S3 so it's never lost
  backend "s3" {
    bucket = "hotel-rag-terraform-state"   # ← change this
    key    = "hotel-rag/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# Random suffix so resource names are globally unique
resource "random_id" "suffix" {
  byte_length = 4
}

# ── S3: hotel document storage ────────────────────────────────────────────────
resource "aws_s3_bucket" "hotel_docs" {
  bucket = "${var.project_name}-docs-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "hotel_docs" {
  bucket = aws_s3_bucket.hotel_docs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hotel_docs" {
  bucket = aws_s3_bucket.hotel_docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── ECR: Docker image registry ────────────────────────────────────────────────
resource "aws_ecr_repository" "hotel_rag_api" {
  name                 = "${var.project_name}-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true   # Auto-scans images for vulnerabilities
  }
}

# Delete old images automatically (keep only last 5) to save storage costs
resource "aws_ecr_lifecycle_policy" "hotel_rag_api" {
  repository = aws_ecr_repository.hotel_rag_api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ── IAM Role for Lambda ───────────────────────────────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  # Trust policy: allows Lambda service to assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Basic Lambda permissions (write to CloudWatch logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy: allow Lambda to use Bedrock, OpenSearch, and S3
resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowBedrock"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "*"
      },
      {
        Sid      = "AllowOpenSearch"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = "*"
      },
      {
        Sid    = "AllowS3Read"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.hotel_docs.arn,
          "${aws_s3_bucket.hotel_docs.arn}/*"
        ]
      }
    ]
  })
}

# ── Lambda function placeholder ───────────────────────────────────────────────
# We create a dummy zip here; GitHub Actions replaces it with real code
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda_placeholder.zip"

  source {
    content  = "def handler(event, context): return {'statusCode': 200}"
    filename = "lambda_ingest.py"
  }
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${var.project_name}-ingest"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.11"
  handler          = "lambda_ingest.handler"
  timeout          = 300     # 5 minutes max
  memory_size      = 512     # 512 MB RAM

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.vectors.collection_endpoint
      S3_BUCKET           = aws_s3_bucket.hotel_docs.bucket
      REGION              = var.aws_region
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# S3 → Lambda trigger
resource "aws_lambda_permission" "s3_trigger" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.hotel_docs.arn
}

resource "aws_s3_bucket_notification" "trigger_ingest" {
  bucket = aws_s3_bucket.hotel_docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"   # Only trigger on JSON files
  }

  depends_on = [aws_lambda_permission.s3_trigger]
}

# ── OpenSearch Serverless (vector database) ───────────────────────────────────
# Must create encryption + network policies BEFORE the collection

resource "aws_opensearchserverless_encryption_policy" "vectors" {
  name = "${var.project_name}-enc-policy"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${var.project_name}-vectors"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_network_policy" "vectors" {
  name = "${var.project_name}-net-policy"
  type = "network"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${var.project_name}-vectors"]
      },
      {
        ResourceType = "dashboard"
        Resource     = ["collection/${var.project_name}-vectors"]
      }
    ]
    AllowFromPublic = true
  }])
}

# Data access policy: allows your IAM user + Lambda to read/write
data "aws_caller_identity" "current" {}

resource "aws_opensearchserverless_access_policy" "vectors" {
  name = "${var.project_name}-access-policy"
  type = "data"
  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${var.project_name}-vectors/*"]
        Permission   = ["aoss:CreateIndex", "aoss:WriteDocument",
                        "aoss:ReadDocument", "aoss:UpdateIndex",
                        "aoss:DescribeIndex", "aoss:DeleteIndex"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${var.project_name}-vectors"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DescribeCollectionItems",
                        "aoss:UpdateCollectionItems"]
      }
    ]
    Principal = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/pavan_mlops",
      aws_iam_role.lambda_role.arn
    ]
  }])
}

resource "aws_opensearchserverless_collection" "vectors" {
  name = "${var.project_name}-vectors"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_encryption_policy.vectors,
    aws_opensearchserverless_network_policy.vectors,
    aws_opensearchserverless_access_policy.vectors
  ]
}

# ── RDS PostgreSQL: stores evaluation logs ────────────────────────────────────
resource "aws_db_instance" "eval_db" {
  identifier          = "${var.project_name}-eval-db"
  engine              = "postgres"
  engine_version      = "15.4"
  instance_class      = "db.t3.micro"    # Free tier eligible
  allocated_storage   = 20               # GB — free tier max is 20GB
  storage_encrypted   = true

  db_name  = "rageval"
  username = "ragadmin"
  password = var.db_password

  publicly_accessible    = true          # Needed to connect from local machine
  skip_final_snapshot    = true          # For dev — in prod set this to false
  deletion_protection    = false

  # Free tier: no multi-AZ, no read replicas
  multi_az               = false
  backup_retention_period = 7            # Keep 7 days of backups
}

# ── CloudWatch: latency + error alarms ───────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300     # Check every 5 minutes
  statistic           = "Sum"
  threshold           = 5       # Alert if >5 errors in 5 minutes
  alarm_description   = "Lambda ingestion function errors"

  dimensions = {
    FunctionName = aws_lambda_function.ingest.function_name
  }
}

# Billing alert — fires if your AWS bill exceeds $10
resource "aws_budgets_budget" "cost_alert" {
  name         = "${var.project_name}-budget"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80    # Alert at 80% of $10 = $8
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["akhilapavan0715@gmail.com"]   # ← change this
  }
}