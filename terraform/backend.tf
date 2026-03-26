################################################################################
# BOOTSTRAP INSTRUCTIONS (Run ONCE before `terraform init`)
#
# The S3 bucket for remote state must exist before Terraform can use it.
# Run the following AWS CLI commands to create it:
#
#   export AWS_REGION="us-east-1"
#   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
#   export TF_STATE_BUCKET="flask-app-tfstate-${ACCOUNT_ID}"
#
#   aws s3api create-bucket \
#     --bucket $TF_STATE_BUCKET \
#     --region $AWS_REGION
#
#   aws s3api put-bucket-versioning \
#     --bucket $TF_STATE_BUCKET \
#     --versioning-configuration Status=Enabled
#
#   aws s3api put-bucket-encryption \
#     --bucket $TF_STATE_BUCKET \
#     --server-side-encryption-configuration '{
#       "Rules": [{
#         "ApplyServerSideEncryptionByDefault": {
#           "SSEAlgorithm": "AES256"
#         }
#       }]
#     }'
#
#   aws s3api put-public-access-block \
#     --bucket $TF_STATE_BUCKET \
#     --public-access-block-configuration \
#       "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
#
# Then update the `bucket` value below and run `terraform init`.
################################################################################

terraform {
  backend "s3" {
    # Replace with the bucket name you created above
    bucket  = "flask-app-tfstate-<YOUR_ACCOUNT_ID>"
    key     = "flask-app/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true

    # S3 native state locking — requires Terraform >= 1.10, no DynamoDB needed
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Must be 1.10+ for S3 native locking (use_lockfile)
  # Install via: https://developer.hashicorp.com/terraform/install
  # Or via tfenv: tfenv install 1.10.0 && tfenv use 1.10.0
  required_version = ">= 1.10.0"
}
