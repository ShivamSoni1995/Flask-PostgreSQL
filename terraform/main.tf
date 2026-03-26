################################################################################
# Provider
################################################################################

provider "aws" {
  region = var.aws_region
}

################################################################################
# Data Sources
################################################################################

# Latest Amazon Linux 2023 AMI
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

data "aws_caller_identity" "current" {}

################################################################################
# Networking — VPC
################################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# Public subnet — EC2 lives here
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-subnet" }
}

# Private subnets — RDS subnet group needs 2 AZs
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.project_name}-private-subnet-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

################################################################################
# Security Groups
################################################################################

# EC2 — allow HTTP (80) and SSH (22) from anywhere
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Allow HTTP and SSH inbound to EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}

# RDS — allow PostgreSQL (5432) ONLY from the EC2 security group
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow PostgreSQL inbound from EC2 SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
}

################################################################################
# ECR Repository
################################################################################

resource "aws_ecr_repository" "flask_app" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project_name}-ecr" }
}

################################################################################
# Secrets Manager — RDS credentials
################################################################################

resource "aws_secretsmanager_secret" "rds_credentials" {
  name                    = "${var.project_name}/rds/credentials"
  description             = "Master credentials for the Flask app RDS instance"
  recovery_window_in_days = 7

  tags = { Name = "${var.project_name}-rds-secret" }
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    dbname   = var.db_name
  })
}

################################################################################
# IAM — EC2 Instance Profile (Least Privilege)
################################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = { Name = "${var.project_name}-ec2-role" }
}

# Least-privilege policy:
# - GetSecretValue scoped to the single RDS secret ARN only
# - ECR auth (GetAuthorizationToken cannot be scoped to a resource)
# - ECR pull scoped to the single flask-app repository ARN only
data "aws_iam_policy_document" "ec2_policy" {
  statement {
    sid       = "AllowGetRdsSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.rds_credentials.arn]
  }

  statement {
    sid     = "AllowECRAuth"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    # GetAuthorizationToken is a global action — cannot be scoped to a resource
    resources = ["*"]
  }

  statement {
    sid    = "AllowECRPull"
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
    # Scoped to the single flask-app ECR repository ARN only
    resources = [aws_ecr_repository.flask_app.arn]
  }
}

resource "aws_iam_policy" "ec2_policy" {
  name        = "${var.project_name}-ec2-policy"
  description = "Allow EC2 to read RDS secret and pull from ECR"
  policy      = data.aws_iam_policy_document.ec2_policy.json
}

resource "aws_iam_role_policy_attachment" "ec2_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

################################################################################
# RDS PostgreSQL
################################################################################

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.project_name}-db-subnet-group" }
}

resource "aws_db_instance" "postgres" {
  identifier        = "${var.project_name}-postgres"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = { Name = "${var.project_name}-postgres" }
}

################################################################################
# EC2 — User Data bootstrap script
#
# Key fixes vs original:
# 1. Uses printf instead of heredoc for .env and config files to avoid
#    indentation issues caused by Terraform's local heredoc stripping.
# 2. RDS endpoint is interpolated directly by Terraform (no AWS CLI lookup needed).
# 3. ECR image pull instead of local build (no buildx required on AL2023).
# 4. nginx.conf written as a file explicitly before compose starts.
# 5. docker-compose.yml written without `version` key (obsolete in Compose v2).
################################################################################

locals {
  ecr_image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repository_name}:latest"
  rds_host  = aws_db_instance.postgres.address

  user_data = <<-SCRIPT
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "==> Updating system packages..."
dnf update -y

echo "==> Installing Docker..."
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

echo "==> Installing Docker Compose plugin..."
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version

echo "==> Fetching RDS credentials from Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "${aws_secretsmanager_secret.rds_credentials.arn}" \
  --region "${var.aws_region}" \
  --query SecretString \
  --output text)

DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
DB_NAME=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['dbname'])")

echo "==> Writing application files..."
mkdir -p /opt/flask-app

# Write .env — using printf to avoid heredoc indentation issues
printf 'DATABASE_URL=postgresql://%s:%s@%s:5432/%s\nDB_HOST=%s\nDB_PORT=5432\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\n' \
  "$DB_USER" "$DB_PASS" "${local.rds_host}" "$DB_NAME" \
  "${local.rds_host}" "$DB_NAME" "$DB_USER" "$DB_PASS" \
  > /opt/flask-app/.env
chmod 600 /opt/flask-app/.env

# Write nginx.conf — using printf to guarantee it is created as a file
printf 'worker_processes auto;\n\nevents {\n    worker_connections 1024;\n}\n\nhttp {\n    access_log /var/log/nginx/access.log;\n    error_log  /var/log/nginx/error.log warn;\n\n    upstream flask_app {\n        server web:5000;\n    }\n\n    server {\n        listen 80;\n        server_name _;\n\n        proxy_set_header Host              $host;\n        proxy_set_header X-Real-IP         $remote_addr;\n        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n\n        location / {\n            proxy_pass http://flask_app;\n        }\n\n        location /health {\n            proxy_pass http://flask_app;\n            access_log off;\n        }\n    }\n}\n' \
  > /opt/flask-app/nginx.conf

# Write docker-compose.yml — no `version` key (obsolete in Compose v2)
printf 'services:\n  web:\n    image: %s\n    env_file: .env\n    expose:\n      - "5000"\n    restart: unless-stopped\n    healthcheck:\n      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]\n      interval: 30s\n      timeout: 10s\n      retries: 5\n      start_period: 15s\n    networks:\n      - backend\n\n  nginx:\n    image: nginx:alpine\n    ports:\n      - "80:80"\n    volumes:\n      - ./nginx.conf:/etc/nginx/nginx.conf:ro\n    depends_on:\n      web:\n        condition: service_healthy\n    restart: unless-stopped\n    networks:\n      - backend\n\nnetworks:\n  backend:\n    driver: bridge\n' \
  "${local.ecr_image}" \
  > /opt/flask-app/docker-compose.yml

echo "==> Logging into ECR and pulling image..."
aws ecr get-login-password --region "${var.aws_region}" | \
  docker login --username AWS --password-stdin \
  "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

docker pull "${local.ecr_image}"

echo "==> Starting Docker Compose..."
cd /opt/flask-app
docker compose up -d

echo "==> Bootstrap complete."
SCRIPT
}

################################################################################
# EC2 Instance
################################################################################

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = var.key_pair_name

  user_data = base64encode(local.user_data)

  # Ensure RDS, secret, and ECR image exist before the instance boots
  depends_on = [
    aws_db_instance.postgres,
    aws_secretsmanager_secret_version.rds_credentials,
    aws_ecr_repository.flask_app,
  ]

  root_block_device {
    # AL2023 AMI snapshot is 30GB — volume must be >= 30GB
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = { Name = "${var.project_name}-ec2" }
}
