# Databricks on AWS — Security Reference Architecture (Terraform)

This provisions a Databricks E2 workspace into your own AWS account using
Databricks' official [Security Reference Architecture (SRA)](https://github.com/databricks/terraform-databricks-sra)
Terraform templates, vendored unmodified into [databricks-sra/](databricks-sra/).

SRA's own AWS README ([databricks-sra/UPSTREAM_README.md](databricks-sra/UPSTREAM_README.md))
is the authoritative reference for every variable and component below.

## Why two directories

SRA supports two network modes:

- **isolated** (SRA's default): SRA builds its own VPC with **no internet
  egress at all** from clusters — locked down to AWS PrivateLink only.
- **custom**: you bring an existing VPC, subnets, security group, and
  PrivateLink endpoints to the Databricks control plane; SRA wires them in
  instead of building its own.

This project uses **custom**, because a fully internet-locked cluster can't
`pip install` packages or hit external APIs, which gets in the way of
general exercises. That means the VPC + PrivateLink endpoints SRA would
otherwise build for you have to exist first — that's what [network/](network/)
does. It creates the same backend PrivateLink connectivity SRA's isolated
mode would (so cluster-to-control-plane traffic stays off the public
internet), but adds a NAT gateway so clusters can still reach the internet
for everything else.

## Prerequisites

1. **AWS account** with credentials available to the AWS provider (e.g.
   `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, or `AWS_PROFILE`).
2. **Databricks account** — sign up for the free trial at databricks.com
   (requires linking the AWS account above). From the Account Console, note
   your **Account ID** and create a **service principal** with account admin
   rights for `DATABRICKS_CLIENT_ID`/`DATABRICKS_CLIENT_SECRET`.
3. Terraform ~> 1.3 (this machine has 1.16.2 installed via
   `hashicorp/tap/terraform`).

## Usage

### 1. Provision the network prerequisites

```sh
cd network
cp terraform.tfvars.example terraform.tfvars
# Edit region/resource_prefix/vpc_cidr, and look up
# general_access_service_name / scc_relay_service_name for your region
# in ../databricks-sra/variables.tf (general_access_config / scc_relay_config).

terraform init
terraform apply
terraform output
```

### 2. Provision the Databricks workspace

```sh
cd ../databricks-sra
cp terraform.tfvars.example terraform.tfvars
# Fill in databricks_account_id, aws_account_id, admin_user, region,
# resource_prefix (match network/), and paste the custom_* values from
# `terraform output` in step 1.

export DATABRICKS_CLIENT_ID=...
export DATABRICKS_CLIENT_SECRET=...

terraform init
terraform plan
terraform apply
```

`terraform output workspace_host` gives you the URL to log into.

## Notes / things to check before applying

- This creates real, continuously-billed AWS resources (VPC, NAT gateway,
  PrivateLink interface endpoints, S3 buckets, KMS keys) regardless of the
  Databricks trial being free.
- `resource_prefix` must match between `network/` and `databricks-sra/` —
  they're separate Terraform states describing one deployment.
- `audit_log_delivery_exists` and `metastore_exists` in
  [databricks-sra/terraform.tfvars.example](databricks-sra/terraform.tfvars.example)
  are set to `false` for a first run in a fresh account/region. Audit log
  delivery can only be configured **twice** per Databricks account — flip
  `audit_log_delivery_exists` to `true` after your first successful apply.
- `databricks-sra/` is intentionally kept as an unmodified copy of upstream
  so it can be diffed/updated by re-running the sync — customize via
  `terraform.tfvars`, not by editing the `.tf` files directly.
- To tear down: `terraform destroy` in `databricks-sra/` first, then in
  `network/`.
