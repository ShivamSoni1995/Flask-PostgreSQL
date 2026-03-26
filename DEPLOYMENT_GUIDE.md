# Deployment & Verification Guide
## Production Flask + Nginx + RDS on AWS (Terraform)

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Terraform | **≥ 1.10** | Required for S3 native state locking |
| AWS CLI v2 | latest | Must be configured with appropriate permissions |
| Docker | latest | For building and pushing the Flask image locally |

### Install Terraform 1.10+

```bash
# Option A — tfenv (recommended, manages multiple versions)
tfenv install 1.10.0
tfenv use 1.10.0

# Option B — direct download (Linux)
wget https://releases.hashicorp.com/terraform/1.10.0/terraform_1.10.0_linux_amd64.zip
unzip terraform_1.10.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/
terraform version   # must show >= 1.10.0
```

Configure AWS CLI:
```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output format (json)
```

---

## Project Layout

```
.
├── terraform/
│   ├── backend.tf       # S3 remote state + Terraform version lock
│   ├── main.tf          # All AWS resources (VPC, EC2, RDS, ECR, IAM, Secrets)
│   ├── variables.tf     # Input variables
│   └── outputs.tf       # Key outputs (IP, URL, ECR URL, RDS endpoint...)
├── app/
│   ├── app.py           # Flask application
│   ├── requirements.txt
│   └── Dockerfile       # Multi-stage image (build locally, push to ECR)
├── nginx/
│   └── nginx.conf       # Reverse proxy config
└── docker-compose.yml   # Orchestration (used by EC2 user_data)
```

---

## Step 1 — Bootstrap the S3 Remote State Bucket

> **Run ONCE before `terraform init`.** The bucket must exist before Terraform
> can store state in it.

```bash
export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_STATE_BUCKET="flask-app-tfstate-${ACCOUNT_ID}"

echo "Creating bucket: $TF_STATE_BUCKET"

aws s3api create-bucket \
  --bucket "$TF_STATE_BUCKET" \
  --region "$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
    }]
  }'

aws s3api put-public-access-block \
  --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✅ S3 bucket ready: $TF_STATE_BUCKET"
```

Now update `terraform/backend.tf` — replace the bucket value:
```hcl
bucket = "flask-app-tfstate-<YOUR_ACCOUNT_ID>"
```

---

## Step 2 — Create an EC2 Key Pair

> Skip this step if you already have an existing key pair in your AWS account.

```bash
# Create the key pair and save the private key locally
aws ec2 create-key-pair \
  --key-name flask-app-key \
  --region us-east-1 \
  --query "KeyMaterial" \
  --output text > ~/.ssh/flask-app-key.pem

# Secure the private key file
chmod 400 ~/.ssh/flask-app-key.pem

# Verify the key pair exists in AWS
aws ec2 describe-key-pairs \
  --key-names flask-app-key \
  --query "KeyPairs[0].KeyName" \
  --output text
```

Use `flask-app-key` as the value for `key_pair_name` in `terraform.tfvars`.

---

## Step 3 — Create `terraform.tfvars`

```bash
cd terraform/

cat > terraform.tfvars <<EOF
aws_region        = "us-east-1"
project_name      = "flask-app"
key_pair_name     = "flask-app-key"
db_password       = "$(openssl rand -base64 24 | tr -d '@/+="' | cut -c1-24)"
EOF

cat terraform.tfvars   # review before continuing
```

> **Never commit `terraform.tfvars` to source control** — add it to `.gitignore`.
> Save the generated password somewhere safe (a password manager).

---

## Step 4 — Initialise and Plan

```bash
cd terraform/

terraform init
terraform plan -var-file="terraform.tfvars"
```

Expected resources (~20):
- VPC, 3 subnets, route table, internet gateway
- 2 Security Groups (EC2 + RDS)
- ECR repository
- Secrets Manager secret + version
- IAM Role + Policy + Instance Profile
- RDS Subnet Group + DB Instance (PostgreSQL 16)
- EC2 Instance (Amazon Linux 2023)

---

## Step 5 — Apply the Infrastructure

```bash
terraform apply -var-file="terraform.tfvars"
```

Type `yes` when prompted. Total time: **10–15 minutes** (RDS dominates).

Note the outputs at the end:
```
ecr_repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/flask-app"
ec2_public_ip      = "54.x.x.x"
app_url            = "http://54.x.x.x"
rds_endpoint       = "flask-app-postgres.xxxxxxxx.us-east-1.rds.amazonaws.com"
```

---

## Step 6 — Build and Push the Flask Image to ECR

> **Run on your local machine** (where the `app/` directory is).
> The EC2 instance pulls the pre-built image — no Docker build happens on EC2.

```bash
# Get ECR URL from Terraform output
ECR_URL=$(terraform output -raw ecr_repository_url)
echo $ECR_URL

# Log Docker into ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_URL

# Build the image (from project root)
docker build -t flask-app ./app

# Tag and push
docker tag flask-app:latest $ECR_URL:latest
docker push $ECR_URL:latest

echo "✅ Image pushed to ECR"
```

---

## Step 7 — Wait for EC2 Bootstrap

The EC2 `user_data` script runs automatically on first boot. It installs Docker,
fetches secrets, writes config files, pulls the ECR image, and starts Compose.
This takes **3–5 minutes** after the instance reaches `running` state.

Monitor progress:
```bash
EC2_IP=$(terraform output -raw ec2_public_ip)

# SSH into the instance
ssh -i ~/.ssh/flask-app-key.pem ec2-user@$EC2_IP

# Tail the bootstrap log
sudo tail -f /var/log/user-data.log
```

When complete you'll see: `==> Bootstrap complete.`

Check containers are running:
```bash
sudo docker ps
# Should show flask-app-web-1 (healthy) and flask-app-nginx-1 (running)
```

---

## Step 8 — Verify the Application

```bash
EC2_IP=$(terraform output -raw ec2_public_ip)

# Root endpoint — DB status
curl -s http://$EC2_IP/ | python3 -m json.tool

# Health check
curl -s http://$EC2_IP/health

# Verbose DB check
curl -s http://$EC2_IP/db-check | python3 -m json.tool
```

Expected root response:
```json
{
  "status": "ok",
  "database": {
    "status": "connected",
    "version": "PostgreSQL 16.x ...",
    "error": null
  },
  "request": {
    "host": "54.x.x.x",
    "method": "GET",
    "path": "/",
    "remote_addr": "your.ip.here"
  }
}
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `curl` times out | Bootstrap still running | Wait 5 min, check `user-data.log` |
| `502 Bad Gateway` | Flask container unhealthy | `sudo docker logs flask-app-web-1` |
| `503` on `/` | RDS unreachable | Check RDS SG allows EC2 SG on port 5432 |
| ECR pull fails | IAM policy not applied yet | Re-run `terraform apply`, check instance profile |
| Image not found in ECR | Step 6 skipped | Build and push the image first, then restart compose |

If containers need to be restarted manually after fixing an issue:
```bash
cd /opt/flask-app
sudo docker compose down
sudo docker compose up -d
```

---

## Updating the Application

After making changes to `app.py`:
```bash
# Rebuild and push from local machine
docker build -t flask-app ./app
docker tag flask-app:latest $ECR_URL:latest
docker push $ECR_URL:latest

# On EC2 — pull new image and restart
ssh -i ~/.ssh/flask-app-key.pem ec2-user@$EC2_IP
aws ecr get-login-password --region us-east-1 | \
  sudo docker login --username AWS --password-stdin $ECR_URL
cd /opt/flask-app
sudo docker compose pull web
sudo docker compose up -d
```

---

## Teardown

```bash
cd terraform/
terraform destroy -var-file="terraform.tfvars"
```

The Secrets Manager secret has a 7-day recovery window. To delete immediately:
```bash
aws secretsmanager delete-secret \
  --secret-id flask-app/rds/credentials \
  --force-delete-without-recovery
```

The S3 state bucket is not managed by Terraform and must be deleted manually:
```bash
aws s3 rb s3://$TF_STATE_BUCKET --force
```

---

## Architecture

```
Internet
    │  port 80
    ▼
┌─────────────────────────────────────────────┐
│  Public Subnet (10.0.1.0/24)                │
│                                             │
│  ┌──────────────────────────────────┐       │
│  │  EC2 (Amazon Linux 2023)         │       │
│  │  ┌─────────┐   ┌─────────────┐  │       │
│  │  │  Nginx  │──▶│    Flask    │  │       │
│  │  │  :80    │   │ (Gunicorn)  │  │       │
│  │  └─────────┘   │   :5000     │  │       │
│  │                └─────────────┘  │       │
│  └──────────────────────────────────┘       │
└──────────────────────────┬──────────────────┘
                           │ port 5432
┌──────────────────────────▼──────────────────┐
│  Private Subnets (10.0.10/24, 10.0.11/24)   │
│  ┌──────────────────────────────────┐        │
│  │  RDS PostgreSQL 16               │        │
│  │  (encrypted, not public)         │        │
│  └──────────────────────────────────┘        │
└─────────────────────────────────────────────┘

ECR ◀────────── Local machine (docker build + push)
ECR ──────────▶ EC2 (docker pull on boot)
Secrets Manager ◀── Terraform (writes credentials)
Secrets Manager ──▶ EC2 IAM Role (reads on boot)
S3 ◀──────────────▶ Terraform remote state
```
