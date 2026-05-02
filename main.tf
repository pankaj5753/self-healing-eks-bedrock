# ============================================================
# Self-Healing EKS Cluster with AWS Bedrock Agent
# YouTube: "The Self-Healing EKS Cluster"
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================
# VARIABLES
# ============================================================

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS Cluster name"
  type        = string
  default     = "self-healing-demo"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "demo"
}

# ============================================================
# DATA SOURCES
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

# ============================================================
# VPC & NETWORKING
# ============================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = { Environment = var.environment }
}

# ============================================================
# EKS CLUSTER
# ============================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.29"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # Enable CloudWatch logging for the Bedrock Agent to analyze
  cluster_enabled_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  eks_managed_node_groups = {
    main = {
      min_size       = 1
      max_size       = 5
      desired_size   = 2
      instance_types = ["t3.medium"]

      labels = {
        Environment = var.environment
        Role        = "demo"
      }
    }
  }

  tags = { Environment = var.environment }
}

# ============================================================
# CLOUDWATCH LOG GROUP (Bedrock Agent reads from here)
# ============================================================

resource "aws_cloudwatch_log_group" "eks_agent_logs" {
  name              = "/aws/eks/${var.cluster_name}/agent-events"
  retention_in_days = 7

  tags = { Purpose = "bedrock-agent-input" }
}

resource "aws_cloudwatch_metric_alarm" "pod_crash_loop" {
  alarm_name          = "${var.cluster_name}-pod-crashloop"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 60
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Triggered when pods enter CrashLoopBackOff"
  alarm_actions       = [aws_sns_topic.bedrock_trigger.arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}

# ============================================================
# SNS TOPIC → LAMBDA TRIGGER
# ============================================================

resource "aws_sns_topic" "bedrock_trigger" {
  name = "${var.cluster_name}-bedrock-trigger"
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.bedrock_trigger.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.bedrock_orchestrator.arn
}

# ============================================================
# IAM ROLE: Lambda Orchestrator
# ============================================================

resource "aws_iam_role" "lambda_role" {
  name = "${var.cluster_name}-lambda-bedrock-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "bedrock-eks-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeAgent",
          "bedrock:InvokeModel",
          "bedrock:Retrieve"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogDelivery",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:DescribeLogStreams",
          "logs:FilterLogEvents"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.eks_agent_logs.arn}:*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ]
        Resource = module.eks.cluster_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.bedrock_trigger.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# LAMBDA: Bedrock Orchestrator
# ============================================================

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "/tmp/bedrock_orchestrator.zip"
  source {
    content  = file("${path.module}/lambda/orchestrator.py")
    filename = "orchestrator.py"
  }
}

resource "aws_lambda_function" "bedrock_orchestrator" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.cluster_name}-bedrock-orchestrator"
  role             = aws_iam_role.lambda_role.arn
  handler          = "orchestrator.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      BEDROCK_AGENT_ID      = aws_bedrockagent_agent.sre_agent.agent_id
      BEDROCK_AGENT_ALIAS   = "TSTALIASID"
      EKS_CLUSTER_NAME      = var.cluster_name
      AWS_REGION_NAME       = var.aws_region
      LOG_GROUP_NAME        = aws_cloudwatch_log_group.eks_agent_logs.name
    }
  }

  tags = { Environment = var.environment }
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_orchestrator.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.bedrock_trigger.arn
}

# ============================================================
# IAM ROLE: Bedrock Agent
# ============================================================

resource "aws_iam_role" "bedrock_agent_role" {
  name = "${var.cluster_name}-bedrock-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_agent_policy" {
  name = "bedrock-agent-permissions"
  role = aws_iam_role.bedrock_agent_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:Retrieve"]
        Resource = aws_bedrockagent_knowledge_base.runbook_kb.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.eks_agent_logs.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.eks_action_executor.arn
      }
    ]
  })
}

# ============================================================
# BEDROCK KNOWLEDGE BASE (RAG for Runbooks)
# ============================================================

resource "aws_s3_bucket" "runbooks" {
  bucket = "${var.cluster_name}-runbooks-${data.aws_caller_identity.current.account_id}"
  tags   = { Purpose = "bedrock-rag-source" }
}

resource "aws_s3_bucket_versioning" "runbooks" {
  bucket = aws_s3_bucket.runbooks.id
  versioning_configuration { status = "Enabled" }
}

# Upload runbook files (place your .md/.txt runbooks in ./runbooks/)
resource "aws_s3_object" "crashloop_runbook" {
  bucket = aws_s3_bucket.runbooks.id
  key    = "runbooks/crashloop-backoff.md"
  source = "${path.module}/runbooks/crashloop-backoff.md"
  etag   = filemd5("${path.module}/runbooks/crashloop-backoff.md")
}

resource "aws_s3_object" "oom_runbook" {
  bucket = aws_s3_bucket.runbooks.id
  key    = "runbooks/oom-killed.md"
  source = "${path.module}/runbooks/oom-killed.md"
  etag   = filemd5("${path.module}/runbooks/oom-killed.md")
}

resource "aws_iam_role" "kb_role" {
  name = "${var.cluster_name}-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "kb_policy" {
  name = "kb-s3-access"
  role = aws_iam_role.kb_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.runbooks.arn, "${aws_s3_bucket.runbooks.arn}/*"]
    }]
  })
}

resource "aws_bedrockagent_knowledge_base" "runbook_kb" {
  name     = "${var.cluster_name}-runbook-kb"
  role_arn = aws_iam_role.kb_role.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb_store.arn
      vector_index_name = "bedrock-knowledge-base-default-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }

  tags = { Environment = var.environment }
}

resource "aws_bedrockagent_data_source" "runbooks_ds" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.runbook_kb.id
  name              = "eks-runbooks"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.runbooks.arn
    }
  }
}

# ============================================================
# OPENSEARCH SERVERLESS (Vector Store for KB)
# ============================================================

resource "aws_opensearchserverless_security_policy" "encryption" {
  name   = "${var.cluster_name}-enc-policy"
  type   = "encryption"
  policy = jsonencode({
    Rules = [{ Resource = ["collection/${var.cluster_name}-kb"], ResourceType = "collection" }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name   = "${var.cluster_name}-net-policy"
  type   = "network"
  policy = jsonencode([{
    Rules = [
      { Resource = ["collection/${var.cluster_name}-kb"], ResourceType = "collection" },
      { Resource = ["collection/${var.cluster_name}-kb"], ResourceType = "dashboard" }
    ]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_access_policy" "data_access" {
  name   = "${var.cluster_name}-data-access"
  type   = "data"
  policy = jsonencode([{
    Rules = [
      {
        Resource     = ["collection/${var.cluster_name}-kb"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"]
        ResourceType = "collection"
      },
      {
        Resource     = ["index/${var.cluster_name}-kb/*"]
        Permission   = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
        ResourceType = "index"
      }
    ]
    Principal = [
      aws_iam_role.bedrock_agent_role.arn,
      aws_iam_role.kb_role.arn
    ]
  }])
}

resource "aws_opensearchserverless_collection" "kb_store" {
  name = "${var.cluster_name}-kb"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}

# ============================================================
# BEDROCK AGENT (The SRE Brain)
# ============================================================

resource "aws_bedrockagent_agent" "sre_agent" {
  agent_name              = "${var.cluster_name}-sre-agent"
  agent_resource_role_arn = aws_iam_role.bedrock_agent_role.arn
  foundation_model        = "anthropic.claude-3-5-sonnet-20241022-v2:0"
  idle_session_ttl_in_seconds = 600

  instruction = <<-INSTRUCTION
    You are an expert Site Reliability Engineer (SRE) AI agent for a Kubernetes EKS cluster.
    
    Your mission: Automatically diagnose and remediate pod failures with zero human intervention.
    
    When triggered with an alert:
    1. FETCH the CloudWatch logs for the failing pod using the get_pod_logs action
    2. SEARCH the knowledge base for matching runbooks (CrashLoopBackOff, OOMKilled, ImagePullBackOff, etc.)
    3. REASON step-by-step about root cause (show your chain-of-thought)
    4. EXECUTE the appropriate remediation action via execute_kubectl
    5. VERIFY the fix worked by checking pod status
    6. REPORT a structured summary with: RootCause, ActionTaken, Outcome
    
    Always prefer the LEAST disruptive action first:
    - First: restart the specific pod
    - Then: scale the deployment
    - Last resort: increase resource limits and redeploy
    
    NEVER delete persistent volumes or stateful resources without explicit escalation.
    If you cannot determine root cause with >80% confidence, escalate to human via SNS.
  INSTRUCTION

  tags = { Environment = var.environment }
}

resource "aws_bedrockagent_agent_knowledge_base_association" "runbook_assoc" {
  agent_id             = aws_bedrockagent_agent.sre_agent.agent_id
  description          = "EKS operational runbooks for diagnosis and remediation"
  knowledge_base_id    = aws_bedrockagent_knowledge_base.runbook_kb.id
  knowledge_base_state = "ENABLED"
}

# ============================================================
# ACTION GROUP: kubectl executor Lambda
# ============================================================

resource "aws_iam_role" "executor_role" {
  name = "${var.cluster_name}-executor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "executor_basic" {
  role       = aws_iam_role.executor_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "executor_eks" {
  name = "eks-access"
  role = aws_iam_role.executor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:AccessKubernetesApi",
        "logs:FilterLogEvents",
        "logs:GetLogEvents"
      ]
      Resource = "*"
    }]
  })
}

data "archive_file" "executor_zip" {
  type        = "zip"
  output_path = "/tmp/executor.zip"
  source {
    content  = file("${path.module}/lambda/executor.py")
    filename = "executor.py"
  }
}

resource "aws_lambda_function" "eks_action_executor" {
  filename         = data.archive_file.executor_zip.output_path
  function_name    = "${var.cluster_name}-eks-executor"
  role             = aws_iam_role.executor_role.arn
  handler          = "executor.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  source_code_hash = data.archive_file.executor_zip.output_base64sha256

  environment {
    variables = {
      EKS_CLUSTER_NAME = var.cluster_name
      AWS_REGION_NAME  = var.aws_region
    }
  }
}

resource "aws_lambda_permission" "bedrock_invoke" {
  statement_id  = "AllowBedrockInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.eks_action_executor.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = aws_bedrockagent_agent.sre_agent.agent_arn
}

resource "aws_bedrockagent_agent_action_group" "kubectl_actions" {
  agent_id          = aws_bedrockagent_agent.sre_agent.agent_id
  agent_version     = "DRAFT"
  action_group_name = "KubectlActions"
  description       = "Execute kubectl commands on the EKS cluster"

  action_group_executor {
    lambda = aws_lambda_function.eks_action_executor.arn
  }

  api_schema {
    payload = jsonencode({
      openapi = "3.0.0"
      info    = { title = "EKS Actions", version = "1.0" }
      paths = {
        "/get_pod_logs" = {
          post = {
            summary     = "Get logs for a specific pod"
            operationId = "getPodLogs"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      namespace   = { type = "string", description = "Kubernetes namespace" }
                      pod_name    = { type = "string", description = "Pod name" }
                      tail_lines  = { type = "integer", description = "Number of log lines", default = 100 }
                    }
                    required = ["namespace", "pod_name"]
                  }
                }
              }
            }
            responses = { "200" = { description = "Pod logs returned" } }
          }
        }
        "/restart_pod" = {
          post = {
            summary     = "Delete a pod to trigger restart"
            operationId = "restartPod"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      namespace = { type = "string" }
                      pod_name  = { type = "string" }
                    }
                    required = ["namespace", "pod_name"]
                  }
                }
              }
            }
            responses = { "200" = { description = "Pod restarted" } }
          }
        }
        "/scale_deployment" = {
          post = {
            summary     = "Scale a deployment replicas"
            operationId = "scaleDeployment"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      namespace   = { type = "string" }
                      deployment  = { type = "string" }
                      replicas    = { type = "integer" }
                    }
                    required = ["namespace", "deployment", "replicas"]
                  }
                }
              }
            }
            responses = { "200" = { description = "Deployment scaled" } }
          }
        }
        "/update_resource_limits" = {
          post = {
            summary     = "Patch resource requests/limits on a deployment"
            operationId = "updateResourceLimits"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      namespace      = { type = "string" }
                      deployment     = { type = "string" }
                      memory_limit   = { type = "string", description = "e.g. 512Mi" }
                      cpu_limit      = { type = "string", description = "e.g. 500m" }
                    }
                    required = ["namespace", "deployment"]
                  }
                }
              }
            }
            responses = { "200" = { description = "Resources updated" } }
          }
        }
      }
    })
  }
}

# ============================================================
# OUTPUTS
# ============================================================

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS cluster API endpoint"
}

output "bedrock_agent_id" {
  value       = aws_bedrockagent_agent.sre_agent.agent_id
  description = "Bedrock SRE Agent ID"
}

output "orchestrator_lambda_arn" {
  value       = aws_lambda_function.bedrock_orchestrator.arn
  description = "Bedrock orchestrator Lambda ARN"
}

output "runbook_bucket" {
  value       = aws_s3_bucket.runbooks.bucket
  description = "S3 bucket for runbooks — upload your .md files here"
}

output "sns_trigger_arn" {
  value       = aws_sns_topic.bedrock_trigger.arn
  description = "SNS topic to trigger the Bedrock agent"
}
