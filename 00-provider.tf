terraform {
  # Remote state in S3 (backend blocks cannot use variables, so the bucket is written here)
  # This tells Terraform to keep its state file in S3 instead of on your laptop. The state lives at k3s/terraform.tfstate in your bucket.
  backend "s3" {
    bucket       = "terrformstate-060647991203"
    key          = "k3s/terraform.tfstate"
    region       = "us-west-1"
    encrypt      = true
    use_lockfile = true # S3-native state locking, no DynamoDB table needed
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source = "hashicorp/tls"
    }
    local = {
      source = "hashicorp/local"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# ---- k3s cluster access for Helm and Kubernetes, read from the kubeconfig stored in S3 ----
data "aws_s3_object" "kubeconfig" {
  bucket     = var.s3_bucket
  key        = aws_s3_object.kubeconfig.key
  depends_on = [aws_s3_object.kubeconfig]
}

locals {
  kubeconfig = yamldecode(data.aws_s3_object.kubeconfig.body)
}

provider "helm" {
  kubernetes = {
    host                   = local.kubeconfig.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
    client_key             = base64decode(local.kubeconfig.users[0].user["client-key-data"])
  }
}

provider "kubernetes" {
  host                   = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kubeconfig.users[0].user["client-certificate-data"])
  client_key             = base64decode(local.kubeconfig.users[0].user["client-key-data"])
}

# Configure the AWS Provider.
# Credentials are NOT stored here: locally they come from `aws configure`,
# in GitHub Actions from the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY secrets.
provider "aws" {
  region = "us-west-1"
}
