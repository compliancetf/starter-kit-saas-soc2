################################################################################
# General
################################################################################

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "Project name must be 2-21 lowercase alphanumeric characters or hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Set to null to use default credential chain."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# Network
################################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use. Must match the configured aws_region."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets (one per AZ). Isolated from public subnets."
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

################################################################################
# DNS & TLS
################################################################################

variable "domain_name" {
  description = "Primary domain name for the ACM certificate"
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for DNS validation"
  type        = string
}

################################################################################
# EKS
################################################################################

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_min_size" {
  description = "Minimum number of nodes in the EKS node group"
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "Maximum number of nodes in the EKS node group"
  type        = number
  default     = 6
}

variable "eks_node_desired_size" {
  description = "Desired number of nodes in the EKS node group"
  type        = number
  default     = 2
}

################################################################################
# Database  - Aurora PostgreSQL
################################################################################

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "aurora_instance_class" {
  description = "Instance class for Aurora DB instances"
  type        = string
  default     = "db.r6g.large"
}

variable "aurora_master_username" {
  description = "Master username for the Aurora cluster"
  type        = string
  default     = "app_admin"
}

################################################################################
# ElastiCache  - Redis
################################################################################

variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "redis_node_type" {
  description = "ElastiCache node type for Redis"
  type        = string
  default     = "cache.t4g.micro"
}

################################################################################
# S3 Replication (SOC 2 A1.2  - cross-region replication)
################################################################################

variable "s3_replication_role_arn" {
  description = "IAM role ARN for S3 cross-region replication. Create this role in your DR region setup."
  type        = string
}

variable "s3_replication_destination_bucket_arn" {
  description = "ARN of the destination S3 bucket for cross-region replication (must be in a different region)."
  type        = string
}

################################################################################
# Observability
################################################################################

variable "log_retention_days" {
  description = "Number of days to retain logs in CloudWatch and S3"
  type        = number
  default     = 365
}
