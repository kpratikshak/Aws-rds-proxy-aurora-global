# Modular Terraform Setup: AWS RDS Proxy for Aurora Global Database (MySQL)

This guide shows how to organize the Terraform code into reusable modules for a cleaner, production-ready setup. The structure below separates the logic for **RDS Proxy**, **IAM**, and **Secrets Manager**, making it easier to maintain and extend.

---

## 📁 Repository Structure

```
terraform/
│
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars.example
│
├── modules/
│   ├── iam/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── secrets/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── rds-proxy/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
```

---

## 🧩 Root Module (`main.tf`)

```hcl
provider "aws" {
  region = var.region
}

# --- Create Secrets ---
module "secrets" {
  source      = "./modules/secrets"
  db_user_secrets = var.db_user_secrets
  kms_key_id      = var.kms_key_id
}

# --- IAM Role for RDS Proxy ---
module "iam" {
  source       = "./modules/iam"
  region       = var.region
  secrets_arns = module.secrets.secret_arns
  kms_key_id   = var.kms_key_id
}

# --- RDS Proxy Setup ---
module "rds_proxy" {
  source                     = "./modules/rds-proxy"
  region                     = var.region
  proxy_name                 = var.proxy_name
  vpc_id                     = var.vpc_id
  subnet_ids                 = var.subnet_ids
  aurora_cluster_identifier  = var.aurora_cluster_identifier
  secrets_arns               = module.secrets.secret_arns
  rds_proxy_role_arn         = module.iam.role_arn
  proxy_idle_client_timeout  = var.proxy_idle_client_timeout
  proxy_max_connections_pct  = var.proxy_max_connections_percent
}

output "proxy_endpoint" {
  value = module.rds_proxy.proxy_endpoint
}

output "proxy_reader_endpoint" {
  value = module.rds_proxy.proxy_reader_endpoint
}
```

---

## 🧠 Root Variables (`variables.tf`)

```hcl
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "aurora_cluster_identifier" { type = string }

variable "db_user_secrets" {
  description = "Map of DB username => secret name"
  type        = map(string)
}

variable "kms_key_id" { type = string default = "" }
variable "proxy_name" { type = string }
variable "proxy_idle_client_timeout" { type = number default = 1800 }
variable "proxy_max_connections_percent" { type = number default = 50 }
```

---

## 🧱 Module: `modules/secrets`

### `main.tf`

```hcl
resource "aws_secretsmanager_secret" "db_user" {
  for_each  = var.db_user_secrets
  name      = each.value
  kms_key_id = length(var.kms_key_id) > 0 ? var.kms_key_id : null
}

resource "aws_secretsmanager_secret_version" "db_user_secret_values" {
  for_each = aws_secretsmanager_secret.db_user
  secret_id     = each.value.id
  secret_string = jsonencode({ username = each.key, password = "CHANGE_ME_${each.key}" })
}

output "secret_arns" {
  value = [for s in aws_secretsmanager_secret.db_user : s.arn]
}
```

### `variables.tf`

```hcl
variable "db_user_secrets" { type = map(string) }
variable "kms_key_id" { type = string default = "" }
```

### `outputs.tf`

```hcl
output "secret_arns" { value = [for s in aws_secretsmanager_secret.db_user : s.arn] }
```

---

## 🧱 Module: `modules/iam`

### `main.tf`

```hcl
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" identifiers = ["rds.amazonaws.com"] }
  }
}

resource "aws_iam_role" "rds_proxy_role" {
  name               = "rds-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "secrets_policy" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secrets_arns
  }

  dynamic "statement" {
    for_each = length(var.kms_key_id) > 0 ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_id]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_policy" "rds_proxy_secrets_policy" {
  name   = "rds-proxy-secrets-policy"
  policy = data.aws_iam_policy_document.secrets_policy.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.rds_proxy_role.name
  policy_arn = aws_iam_policy.rds_proxy_secrets_policy.arn
}

output "role_arn" {
  value = aws_iam_role.rds_proxy_role.arn
}
```

### `variables.tf`

```hcl
variable "region" { type = string }
variable "secrets_arns" { type = list(string) }
variable "kms_key_id" { type = string default = "" }
```

### `outputs.tf`

```hcl
output "role_arn" { value = aws_iam_role.rds_proxy_role.arn }
```

---

## 🧱 Module: `modules/rds-proxy`

### `main.tf`

```hcl
resource "aws_security_group" "proxy_sg" {
  name   = "rds-proxy-sg"
  vpc_id = var.vpc_id
  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_db_subnet_group" "proxy_subnet_group" {
  name       = "proxy-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_db_proxy" "proxy" {
  name                   = var.proxy_name
  engine_family          = "MYSQL"
  idle_client_timeout    = var.proxy_idle_client_timeout
  role_arn               = var.rds_proxy_role_arn
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = [aws_security_group.proxy_sg.id]

  auth {
    auth_scheme     = "SECRETS"
    secret_arn_list = var.secrets_arns
    iam_auth        = "DISABLED"
  }
}

resource "aws_db_proxy_endpoint" "reader" {
  name                   = "${var.proxy_name}-reader"
  db_proxy_name          = aws_db_proxy.proxy.name
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = [aws_security_group.proxy_sg.id]
  target_role            = "READ_ONLY"
}

resource "aws_db_proxy_target"
```
