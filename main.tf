################################################################################
# SOC 2 Compliance Starter Kit  - B2B SaaS
#
# Pre-composed infrastructure for B2B SaaS companies preparing for SOC 2.
# All modules are sourced from the compliance.tf registry, which enforces
# SOC 2 controls at terraform plan time.
#
# Controls enforced automatically by compliance.tf:
#   CC6.1  - Logical access security (encryption, IAM auth, no public access)
#   CC6.6  - External threat protection (TLS 1.2+, WAF)
#   CC6.7  - Data transmission restriction (HTTPS/TLS enforced)
#   CC7.1  - Detection and monitoring (CloudWatch, flow logs, access logs)
#   CC7.2  - Anomaly detection (versioning, dead-letter queues, retention)
#   CC8.1  - Change management (infrastructure changes tracked in Terraform)
#   A1.2   - Environmental protections (Multi-AZ, failover, backups, replication)
################################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Compliance  = "soc2"
    }
  }
}

locals {
  name = "${var.project_name}-${var.environment}"
}

################################################################################
# Network
################################################################################

module "vpc" {
  source  = "soc2.compliance.tf/terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr

  azs              = var.availability_zones
  public_subnets   = var.public_subnet_cidrs
  private_subnets  = var.private_subnet_cidrs
  database_subnets = var.database_subnet_cidrs

  create_database_subnet_group = true

  enable_nat_gateway = true
  single_nat_gateway = var.environment != "prod"

  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true

  tags = var.tags
}

################################################################################
# Load Balancer
################################################################################

module "alb" {
  source  = "soc2.compliance.tf/terraform-aws-modules/alb/aws"
  version = "~> 10.0"

  name = local.name

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  enable_deletion_protection = var.environment == "prod"

  security_group_ingress_rules = {
    all_https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
      description = "HTTPS ingress"
    }
  }

  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
      description = "All traffic to VPC"
    }
  }

  listeners = {
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = module.acm.acm_certificate_arn
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"

      fixed_response = {
        content_type = "text/plain"
        message_body = "OK"
        status_code  = "200"
      }
    }
  }

  access_logs = {
    bucket = module.s3_bucket_logs.s3_bucket_id
    prefix = "alb"
  }

  tags = var.tags
}

################################################################################
# WAF - Web Application Firewall
################################################################################

module "waf" {
  source  = "soc2.compliance.tf/terraform-aws-modules/wafv2/aws"
  version = "~> 1.0"

  name  = "${local.name}-waf"
  scope = "REGIONAL"

  default_action = "allow"

  rules = {
    common = {
      priority = 1
      statement = {
        managed_rule_group_statement = {
          name        = "AWSManagedRulesCommonRuleSet"
          vendor_name = "AWS"
        }
      }
      override_action = "none"
      visibility_config = {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-common-rules"
        sampled_requests_enabled   = true
      }
    }
    bad_inputs = {
      priority = 2
      statement = {
        managed_rule_group_statement = {
          name        = "AWSManagedRulesKnownBadInputsRuleSet"
          vendor_name = "AWS"
        }
      }
      override_action = "none"
      visibility_config = {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-bad-inputs"
        sampled_requests_enabled   = true
      }
    }
    ip_reputation = {
      priority = 3
      statement = {
        managed_rule_group_statement = {
          name        = "AWSManagedRulesAmazonIpReputationList"
          vendor_name = "AWS"
        }
      }
      override_action = "none"
      visibility_config = {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-ip-reputation"
        sampled_requests_enabled   = true
      }
    }
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = module.alb.arn
  web_acl_arn  = module.waf.web_acl_arn
}

################################################################################
# Certificate
################################################################################

module "acm" {
  source  = "soc2.compliance.tf/terraform-aws-modules/acm/aws"
  version = "~> 6.0"

  domain_name = var.domain_name
  zone_id     = var.route53_zone_id

  validation_method = "DNS"

  subject_alternative_names = [
    "*.${var.domain_name}"
  ]

  wait_for_validation = true

  tags = var.tags
}

################################################################################
# KMS  - Encryption key for EKS log groups and secrets
################################################################################

module "kms" {
  source  = "soc2.compliance.tf/terraform-aws-modules/kms/aws"
  version = "~> 4.0"

  description = "KMS key for ${local.name} EKS cluster encryption"
  key_usage   = "ENCRYPT_DECRYPT"

  key_administrators = [data.aws_caller_identity.current.arn]
  key_users          = [data.aws_caller_identity.current.arn]

  key_service_roles_for_autoscaling = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
  ]

  key_statements = [
    {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"
      principals = [
        {
          type        = "Service"
          identifiers = ["logs.${var.aws_region}.amazonaws.com"]
        }
      ]
      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]
      conditions = [
        {
          test     = "ArnLike"
          variable = "kms:EncryptionContext:aws:logs:arn"
          values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
        }
      ]
    }
  ]

  aliases = ["${local.name}/eks"]

  tags = var.tags
}

################################################################################
# Compute  - EKS
################################################################################

module "eks" {
  source  = "soc2.compliance.tf/terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = true

  cloudwatch_log_group_kms_key_id = module.kms.key_arn

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.eks_node_instance_types
      min_size       = var.eks_node_min_size
      max_size       = var.eks_node_max_size
      desired_size   = var.eks_node_desired_size
    }
  }

  tags = var.tags
}

################################################################################
# Database  - Aurora PostgreSQL
################################################################################

module "rds_aurora" {
  source  = "soc2.compliance.tf/terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.0"

  name            = "${local.name}-db"
  engine          = "aurora-postgresql"
  engine_version  = var.aurora_engine_version
  master_username = var.aurora_master_username

  instances = {
    writer = {
      instance_class = var.aurora_instance_class
    }
    reader = {
      instance_class = var.aurora_instance_class
    }
  }

  vpc_id               = module.vpc.vpc_id
  db_subnet_group_name = module.vpc.database_subnet_group_name
  subnets              = module.vpc.private_subnets

  security_group_ingress_rules = {
    vpc_ingress = {
      cidr_ipv4 = module.vpc.vpc_cidr_block
    }
  }

  storage_encrypted       = true
  apply_immediately       = var.environment != "prod"
  backup_retention_period = var.environment == "prod" ? 14 : 7
  deletion_protection     = var.environment == "prod"

  enabled_cloudwatch_logs_exports     = ["postgresql"]
  iam_database_authentication_enabled = true

  tags = var.tags
}

################################################################################
# Storage  - S3 (application data)
################################################################################

module "s3_bucket_data" {
  source  = "soc2.compliance.tf/terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket = "${local.name}-data-${data.aws_caller_identity.current.account_id}"

  versioning = {
    enabled = "Enabled"
  }

  logging = {
    target_bucket = module.s3_bucket_logs.s3_bucket_id
    target_prefix = "s3/data/"
  }

  lifecycle_rule = [
    {
      id     = "transition-to-ia"
      status = "Enabled"

      transition = [
        {
          days          = 90
          storage_class = "STANDARD_IA"
        }
      ]
    }
  ]

  # SOC 2 A1.2: cross-region replication for disaster recovery.
  # Replace the destination bucket ARN and IAM role with your DR region resources.
  replication_configuration = {
    role = var.s3_replication_role_arn
    rules = [
      {
        id     = "replicate-all"
        status = "Enabled"
        destination = {
          bucket        = var.s3_replication_destination_bucket_arn
          storage_class = "STANDARD"
        }
      }
    ]
  }

  tags = var.tags
}

################################################################################
# Storage  - S3 (access logs)
################################################################################

module "s3_bucket_logs" {
  source  = "soc2.compliance.tf/terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket = "${local.name}-logs-${data.aws_caller_identity.current.account_id}"

  versioning = {
    enabled = "Enabled"
  }

  logging = {
    target_bucket = module.s3_bucket_logs.s3_bucket_id
    target_prefix = "s3/logs/"
  }

  # SOC 2 A1.2: cross-region replication for log durability.
  replication_configuration = {
    role = var.s3_replication_role_arn
    rules = [
      {
        id     = "replicate-logs"
        status = "Enabled"
        destination = {
          bucket        = var.s3_replication_destination_bucket_arn
          storage_class = "STANDARD_IA"
        }
      }
    ]
  }

  lifecycle_rule = [
    {
      id     = "log-retention"
      status = "Enabled"

      transition = [
        {
          days          = 30
          storage_class = "STANDARD_IA"
        },
        {
          days          = 90
          storage_class = "GLACIER"
        }
      ]

      expiration = {
        days = var.log_retention_days
      }
    }
  ]

  tags = var.tags
}

################################################################################
# DynamoDB
################################################################################

module "dynamodb" {
  source  = "soc2.compliance.tf/terraform-aws-modules/dynamodb-table/aws"
  version = "~> 5.0"

  name     = "${local.name}-table"
  hash_key = "pk"

  attributes = [
    {
      name = "pk"
      type = "S"
    }
  ]

  billing_mode                   = "PAY_PER_REQUEST"
  deletion_protection_enabled    = var.environment == "prod"
  point_in_time_recovery_enabled = true

  server_side_encryption_enabled = true

  tags = var.tags
}

################################################################################
# ElastiCache  - Redis
################################################################################

module "elasticache" {
  source  = "soc2.compliance.tf/terraform-aws-modules/elasticache/aws"
  version = "~> 1.0"

  replication_group_id = "${local.name}-redis"

  engine         = "redis"
  engine_version = var.redis_engine_version
  node_type      = var.redis_node_type

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  automatic_failover_enabled = var.environment == "prod"
  num_cache_clusters         = var.environment == "prod" ? 2 : 1

  subnet_ids = module.vpc.private_subnets

  security_group_rules = {
    vpc_ingress = {
      cidr_ipv4 = module.vpc.vpc_cidr_block
    }
  }

  tags = var.tags
}

################################################################################
# Messaging  - SQS
################################################################################

module "sqs" {
  source  = "soc2.compliance.tf/terraform-aws-modules/sqs/aws"
  version = "~> 5.0"

  name = "${local.name}-queue"

  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 60
  message_retention_seconds  = 1209600 # 14 days

  create_dlq = true
  dlq_name   = "${local.name}-queue-dlq"

  tags = var.tags
}

################################################################################
# Observability  - CloudWatch
################################################################################

module "cloudwatch" {
  source  = "soc2.compliance.tf/terraform-aws-modules/cloudwatch/aws//modules/log-group"
  version = "~> 5.0"

  name              = "/app/${local.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

################################################################################
# Data sources
################################################################################

data "aws_caller_identity" "current" {}
