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
    description             = "PostgreSQL from EC2"
    from_port               = 5432
    to_port                 = 5432
    protocol                = "tcp"
    security_groups         = [aws_security_group.ec2.id]
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

# Least-privilege policy: GetSecretValue on the single RDS secret ARN only
data "aws_iam_policy_document" "ec2_secrets_policy" {
  statement {
    sid     = "AllowGetRdsSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    # Scoped to the exact ARN of the RDS secret — no wildcards
    resources = [aws_secretsmanager_secret.rds_credentials.arn]
  }
}

resource "aws_iam_policy" "ec2_secrets_policy" {
  name        = "${var.project_name}-ec2-secrets-policy"
  description = "Allow EC2 to read only the Flask app RDS secret"
  policy      = data.aws_iam_policy_document.ec2_secrets_policy.json
}

resource "aws_iam_role_policy_attachment" "ec2_secrets" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_secrets_policy.arn
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
  identifier             = "${var.project_name}-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true

  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password

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
################################################################################

locals {
  user_data = <<-EOF
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

    echo "==> Fetching RDS credentials from Secrets Manager..."
    SECRET_JSON=$(aws secretsmanager get-secret-value \
      --secret-id "${aws_secretsmanager_secret.rds_credentials.arn}" \
      --region "${var.aws_region}" \
      --query SecretString \
      --output text)

    DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
    DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
    DB_NAME=$(echo "$SECRET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['dbname'])")

    echo "==> Writing .env file..."
    mkdir -p /opt/flask-app
    cat > /opt/flask-app/.env <<ENVFILE
    DATABASE_URL=postgresql://$${DB_USER}:$${DB_PASS}@${aws_db_instance.postgres.address}:5432/$${DB_NAME}
    DB_HOST=${aws_db_instance.postgres.address}
    DB_PORT=5432
    DB_NAME=$${DB_NAME}
    DB_USER=$${DB_USER}
    DB_PASSWORD=$${DB_PASS}
    ENVFILE
    chmod 600 /opt/flask-app/.env

    echo "==> Pulling application files from S3 (if configured) or using inline compose..."
    # --- Inline docker-compose.yml ---
    cat > /opt/flask-app/docker-compose.yml <<'COMPOSE'
    version: "3.9"
    services:
      web:
        image: flask-app:latest
        build: .
        env_file: .env
        expose:
          - "5000"
        restart: unless-stopped
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
          interval: 30s
          timeout: 10s
          retries: 3

      nginx:
        image: nginx:alpine
        ports:
          - "80:80"
        volumes:
          - ./nginx.conf:/etc/nginx/nginx.conf:ro
        depends_on:
          - web
        restart: unless-stopped
    COMPOSE

    echo "==> Starting Docker Compose..."
    cd /opt/flask-app
    docker compose up -d

    echo "==> Bootstrap complete."
  EOF
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

  # Ensure RDS and the secret exist before the instance boots
  depends_on = [
    aws_db_instance.postgres,
    aws_secretsmanager_secret_version.rds_credentials,
  ]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = { Name = "${var.project_name}-ec2" }
}
