# Deployment & Verification Guide
## Production Flask + Nginx + RDS on AWS (Terraform)

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.10 | https://developer.hashicorp.com/terraform/install |
| AWS CLI v2 | latest | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Docker + Compose | latest | https://docs.docker.com/engine/install/ |

Ensure `aws configure` is set up with a profile that has permissions to create
IAM roles, EC2, RDS, VPC, Secrets Manager resources, and S3.

---

## Project Layout

```
.
├── terraform/
│   ├── backend.tf       # S3 remote state + provider lock
│   ├── main.tf          # All AWS resources
│   ├── variables.tf     # Input variables
│   └── outputs.tf       # Key outputs (IP, URL, ARN...)
├── app/
│   ├── app.py           # Flask application
│   ├── requirements.txt
│   └── Dockerfile       # Multi-stage image
├── nginx/
│   └── nginx.conf       # Reverse proxy config
└── docker-compose.yml   # Orchestration
```

---

## Step 1 — Bootstrap the S3 Remote State Bucket

> **This step must be completed ONCE before `terraform init`.**
> The bucket must exist before Terraform can store state in it.

```bash
# Set variables (adjust region as needed)
export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_STATE_BUCKET="flask-app-tfstate-${ACCOUNT_ID}"

echo "Creating bucket: $TF_STATE_BUCKET"

# 1. Create the bucket
aws s3api create-bucket \
  --bucket "$TF_STATE_BUCKET" \
  --region "$AWS_REGION"

# 2. Enable versioning (allows state rollback)
aws s3api put-bucket-versioning \
  --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled

# 3. Enable default encryption
aws s3api put-bucket-encryption \
  --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
    }]
  }'

# 4. Block all public access
aws s3api put-public-access-block \
  --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✅ S3 bucket ready: $TF_STATE_BUCKET"
```

Now **update `terraform/backend.tf`**:
```hcl
bucket = "flask-app-tfstate-<YOUR_ACCOUNT_ID>"   # paste real bucket name here
```

---

## Step 2 — Create a `terraform.tfvars` File

```bash
cd terraform/
cat > terraform.tfvars <<EOF
aws_region        = "us-east-1"
project_name      = "flask-app"
key_pair_name     = "<YOUR_EXISTING_KEY_PAIR_NAME>"   # must already exist in EC2
db_password       = "<STRONG_RANDOM_PASSWORD>"         # min 8 chars, no @ or /
EOF
```

> **Never commit `terraform.tfvars` to source control** — add it to `.gitignore`.

---

## Step 3 — Initialise and Plan

```bash
cd terraform/

# Download providers and configure the S3 backend
terraform init

# Preview what Terraform will create (~18 resources)
terraform plan -var-file="terraform.tfvars"
```

Expected resource summary (approximate):
- 1 VPC + 3 subnets + route tables
- 2 Security Groups
- 1 Secrets Manager secret + version
- 1 IAM Role + Policy + Instance Profile
- 1 RDS DB Subnet Group + 1 DB Instance (PostgreSQL 16)
- 1 EC2 Instance (Amazon Linux 2023)

---

## Step 4 — Apply the Infrastructure

```bash
terraform apply -var-file="terraform.tfvars"
```

Type `yes` when prompted. Total deployment time: **8–15 minutes**
(RDS provisioning dominates).

At the end, note the outputs:

```
Outputs:
  app_url        = "http://54.x.x.x"
  ec2_public_ip  = "54.x.x.x"
  rds_endpoint   = "flask-app-postgres.xxxxxxxx.us-east-1.rds.amazonaws.com:5432"
  rds_secret_arn = "arn:aws:secretsmanager:us-east-1:..."
```

---

## Step 5 — Wait for EC2 Bootstrap

The EC2 `user_data` script installs Docker, fetches secrets, and starts the
containers. This takes ~3–5 minutes after the instance is in `running` state.

**Monitor progress:**
```bash
# SSH into the instance
ssh -i ~/.ssh/<your-key>.pem ec2-user@<EC2_PUBLIC_IP>

# Tail the bootstrap log
sudo tail -f /var/log/user-data.log

# Check Docker containers (run after bootstrap completes)
docker ps
```

Expected `docker ps` output:
```
CONTAINER ID   IMAGE               PORTS                NAMES
xxxxxxxxxxxx   nginx:1.27-alpine   0.0.0.0:80->80/tcp   flask-app-nginx-1
xxxxxxxxxxxx   flask-app:latest                         flask-app-web-1
```

---

## Step 6 — Verify the Application

### 6a. Root endpoint (DB status)
```bash
curl -s http://<EC2_PUBLIC_IP>/ | python3 -m json.tool
```

Expected response:
```json
{
  "status": "ok",
  "database": {
    "status": "connected",
    "version": "PostgreSQL 16.x on x86_64-pc-linux-gnu...",
    "error": null
  },
  "request": {
    "method": "GET",
    "path": "/",
    "remote_addr": "your.ip.here",
    "host": "54.x.x.x"
  }
}
```

### 6b. Health check
```bash
curl -s http://<EC2_PUBLIC_IP>/health
# → {"status": "healthy"}
```

### 6c. Verbose DB check
```bash
curl -s http://<EC2_PUBLIC_IP>/db-check | python3 -m json.tool
# → {"connected": true, "database": "flaskdb", "user": "flaskadmin", ...}
```

### 6d. Verify Nginx headers are forwarded
```bash
curl -sv http://<EC2_PUBLIC_IP>/ 2>&1 | grep -E "Host|X-Real"
# Nginx should be passing Host and X-Real-IP headers to Flask
```

---

## Step 7 — Verify Security Configuration

### Confirm RDS is NOT publicly accessible
```bash
aws rds describe-db-instances \
  --db-instance-identifier flask-app-postgres \
  --query "DBInstances[0].PubliclyAccessible"
# → false
```

### Confirm IAM policy is least-privilege
```bash
aws iam get-policy-version \
  --policy-arn $(terraform output -raw rds_secret_arn | \
    sed 's|secret:.*|policy/flask-app-ec2-secrets-policy|') \
  --version-id v1
```
The policy should show `secretsmanager:GetSecretValue` scoped to a single ARN.

### Confirm secret is accessible from EC2 (SSH in first)
```bash
aws secretsmanager get-secret-value \
  --secret-id flask-app/rds/credentials \
  --region us-east-1 \
  --query SecretString \
  --output text
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `curl` times out | Bootstrap still running | Wait 5 min, check `user-data.log` |
| `502 Bad Gateway` | Flask container not healthy | `docker logs flask-app-web-1` |
| `503` on `/` | RDS unreachable | Check RDS SG allows EC2 SG on 5432 |
| Docker not found | `dnf` install failed | Check `user-data.log` for errors |
| Secret not found | IAM role not attached | Verify instance profile in EC2 console |

---

## Teardown

```bash
cd terraform/
terraform destroy -var-file="terraform.tfvars"
```

> Note: The Secrets Manager secret has a 7-day recovery window before permanent deletion.
> To delete immediately:
> ```bash
> aws secretsmanager delete-secret \
>   --secret-id flask-app/rds/credentials \
>   --force-delete-without-recovery
> ```

The S3 state bucket is **not** managed by Terraform (by design) and must be
deleted manually if desired:
```bash
aws s3 rb s3://$TF_STATE_BUCKET --force
```

---

## Architecture Diagram (Text)

```
Internet
    │  port 80
    ▼
┌─────────────────────────────────────────────┐
│  Public Subnet (10.0.1.0/24)                │
│                                             │
│  ┌──────────────────────────────────┐       │
│  │  EC2 (Amazon Linux 2023)         │       │
│  │  ┌────────┐    ┌──────────────┐  │       │
│  │  │ Nginx  │───▶│ Flask/Gunicorn│  │       │
│  │  │  :80   │    │    :5000      │  │       │
│  │  └────────┘    └──────────────┘  │       │
│  └──────────────────────────────────┘       │
└──────────────────────────┬──────────────────┘
                           │ port 5432
┌──────────────────────────▼──────────────────┐
│  Private Subnets (10.0.10.0/24, /11.0/24)   │
│                                             │
│  ┌──────────────────────────────────┐       │
│  │  RDS PostgreSQL 16               │       │
│  │  (encrypted, not public)         │       │
│  └──────────────────────────────────┘       │
└─────────────────────────────────────────────┘

AWS Secrets Manager ◀── EC2 IAM Role (least-privilege)
S3 (tfstate bucket) ◀── Terraform backend
```
