variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix applied to all resources"
  type        = string
  default     = "flask-app"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (EC2)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidrs" {
  description = "CIDRs for the two private subnets (RDS requires a subnet group spanning 2 AZs)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "availability_zones" {
  description = "Two AZs used for the private subnet group"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "ec2_instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 Key Pair for SSH access"
  type        = string
}

variable "db_name" {
  description = "Name of the initial PostgreSQL database"
  type        = string
  default     = "flaskdb"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "flaskadmin"
}

variable "db_password" {
  description = "Master password for the RDS instance — stored in Secrets Manager"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}
