# Build Plan

Reflects the state of this repo as of the last configuration pass: AWS
account `549394392070` (region `us-east-1`), `network/terraform.tfvars`
fully populated and plan-validated against live credentials, and
`databricks-sra/terraform.tfvars` populated except for the Databricks
account ID and the network IDs that only exist after step 2 runs.

## Current state

- AWS account `549394392070`, region `us-east-1` — reachable, root
  credentials, only the default VPC exists (no CIDR conflicts with the new
  `10.10.0.0/16` VPC).
- `network/terraform.tfvars` — fully populated, `terraform plan` already
  validated clean (23 resources to add) against live AWS credentials.
- `databricks-sra/terraform.tfvars` — populated except `databricks_account_id`
  (blank) and the five `custom_*` network IDs (blank, since they don't exist
  until step 2 runs).
- No Databricks trial/account yet — this is the actual blocker.
  [Databricks Free Edition will not work for this plan](https://docs.databricks.com/aws/en/getting-started/free-edition-limitations) —
  it has no account console or account-level API access, which every
  resource in `databricks-sra/` depends on.

## Build sequence

### 1. Get Databricks account-level access (blocking, not yet done)

Sign up for the Databricks free trial (not Free Edition) at databricks.com,
linking AWS account `549394392070`. From the Account Console:

- Copy the Account ID → `databricks-sra/terraform.tfvars` →
  `databricks_account_id`
- Create a service principal with account-admin rights → export as env vars:

  ```sh
  export DATABRICKS_CLIENT_ID=...
  export DATABRICKS_CLIENT_SECRET=...
  ```

### 2. Apply the network prerequisites

```sh
cd network
terraform init
terraform apply
```

Creates: VPC (`10.10.0.0/16`), 2 private + 2 PrivateLink subnets, public
subnet, IGW, NAT gateway, 2 security groups, S3 gateway endpoint, STS +
Kinesis + general-access + SCC-relay interface endpoints. Real, billed,
continuous cost (~$0.15–0.20/hr).

### 3. Wire network outputs into the workspace config

```sh
terraform output
```

Copy `custom_vpc_id`, `custom_private_subnet_ids`, `custom_sg_id`,
`custom_general_access_vpce_id`, `custom_scc_relay_vpce_id` into
`databricks-sra/terraform.tfvars` (currently blank placeholders there).

### 4. Apply the Databricks workspace

```sh
cd ../databricks-sra
terraform init
terraform plan   # sanity-check before apply
terraform apply
```

Creates: cross-account IAM role, 2 KMS CMKs, root S3 bucket,
`databricks_mws_workspaces` + credentials/storage/network registration,
Unity Catalog metastore + catalog, network policy, network connectivity
config, an example cluster (since `compute_mode = HYBRID`).

### 5. Verify

```sh
terraform output workspace_host
```

Log into that URL, confirm the workspace loads, the example cluster
starts, and the catalog is visible under Unity Catalog.

### 6. Post-first-apply cleanup of tfvars

- Flip `audit_log_delivery_exists = true` (Databricks only allows
  configuring this twice per account — don't rerun apply with it `false`
  again after success).
- If you want a persistent metastore across future destroys, note it now —
  `metastore_exists = false` on this run means SRA creates it, and a
  `terraform destroy` will remove it too.

## Teardown order (if needed)

`terraform destroy` in `databricks-sra/` first, then in `network/` —
reverse of the build order, since the workspace depends on the network
resources.

## Blocker

Step 1 is the only thing blocking progress right now — once you have the
Databricks account ID and service principal, everything else is ready to
run in order.
