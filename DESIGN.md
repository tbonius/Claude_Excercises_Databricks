# Architecture Design: Databricks on AWS (Terraform)

## Overview

This project deploys a Databricks E2 workspace into AWS account `549394392070`
(region `us-east-1`, resource prefix `dbx-trial`) using Terraform. It is split
into two independent Terraform roots that describe one deployment:

- [network/](network/) (hand-written): the AWS VPC and PrivateLink prerequisites.
- [databricks-sra/](databricks-sra/) (vendored, unmodified): Databricks'
  Security Reference Architecture (SRA) module, which builds the workspace,
  storage, IAM, and Unity Catalog resources.

Key choices: `compute_mode = HYBRID` (classic VPC compute, serverless available
alongside); `network_configuration = "custom"` (SRA consumes the VPC from
`network/` instead of building one); clusters keep internet egress via NAT,
unlike SRA's default "isolated" mode.

## Architecture Diagram

```
 AWS account 549394392070, us-east-1
 +----------------------------------------------------------------------------+
 | VPC 10.10.0.0/16  (network/)                                               |
 |                                                                            |
 |  public 10.10.4.0/24 ------- NAT gateway -------- IGW ----> internet       |
 |                                  ^                         (egress only)   |
 |  private 10.10.0.0/24, 10.10.1.0/24 (x2 AZ)  -- 0.0.0.0/0 via NAT          |
 |    classic compute (clusters)  [workspace-sg]                              |
 |         |                                                                  |
 |         | 443, 6666, 2443, 8443, 8444 (from workspace-sg)                  |
 |         v                                                                  |
 |  privatelink 10.10.2.0/24, 10.10.3.0/24 (x2 AZ) [privatelink-sg]           |
 |    - VPCE general-access (REST) --------------------+                      |
 |    - VPCE SCC relay ----------------------+         |                      |
 |    - VPCE STS, VPCE Kinesis (interface)   |         |                      |
 |  S3 gateway endpoint (on private route table)      |                      |
 +-------------------------------------------+---------+----------------------+
                                             |         |  AWS PrivateLink
                                             v         v
                        Databricks control plane (account + workspace)
                                             ^
                                             | IAM assume-role (cross-account)
 +-------------------------------------------+--------------------------------+
 | databricks-sra/ (AWS side)                                                 |
 |   cross-account IAM role + policy                                          |
 |   KMS CMK: workspace storage, KMS CMK: managed services                    |
 |   root S3 bucket (public access blocked, restrictive Databricks policy)    |
 +----------------------------------------------------------------------------+
 | databricks-sra/ (Databricks side)                                          |
 |   MWS workspace + credentials / storage / network config registration      |
 |   Unity Catalog metastore + catalog, metastore assignment                  |
 |   network policy, network connectivity configuration                       |
 |   example cluster (HYBRID mode)                                            |
 +----------------------------------------------------------------------------+
```


## AWS Network Layer (`network/`)

Creates the prerequisite network, applied first. Outputs feed
`databricks-sra/terraform.tfvars`.

| Component | Detail |
|---|---|
| VPC | `10.10.0.0/16`, DNS support and hostnames enabled |
| Private subnets | 2 (`10.10.0.0/24`, `10.10.1.0/24`), classic compute, one per AZ |
| PrivateLink subnets | 2 (`10.10.2.0/24`, `10.10.3.0/24`), interface endpoints |
| Public subnet | 1 (`10.10.4.0/24`), hosts the NAT gateway |
| Internet gateway + NAT | IGW on the public route table; NAT on an EIP, used as the default route for private and PrivateLink subnets |
| Security groups | `workspace-sg`: self-referencing TCP/UDP internode rules plus open egress. `privatelink-sg`: ingress 443, 6666, 2443, 8443, 8444 from `workspace-sg` only |
| S3 gateway endpoint | Attached to the private route table |
| Interface endpoints | STS and Kinesis (AWS services); general-access (REST) and SCC relay (Databricks backend) |

Backend connectivity to the Databricks control plane uses PrivateLink, so
cluster-to-control-plane traffic stays off the public internet. The NAT route
is added only for general egress (package installs, external APIs).

Service names for the two Databricks endpoints are region-specific and are set
in `network/terraform.tfvars` (currently the `us-east-1` values from
`general_access_config` and `scc_relay_config` in `databricks-sra/variables.tf`).

## Databricks Workspace Layer (`databricks-sra/`)

Vendored unmodified from the upstream SRA module. Customize through
`terraform.tfvars`, not by editing `.tf` files, so the copy can be re-synced.

When `network_configuration = "custom"`, SRA skips its own VPC, subnets,
workspace security group, privatelink security group, and the general-access
and SCC endpoints. It uses the `custom_*` IDs supplied from `network/`
instead. The following resources are still created:

- **AWS IAM**: cross-account role and inline policy that Databricks assumes.
- **AWS KMS**: two customer-managed keys, one for workspace storage and one for
  managed services, each with an alias.
- **AWS S3**: the workspace root bucket, with versioning, SSE, public access
  block, and a Databricks-generated bucket policy.
- **Databricks account**: MWS workspace, with credentials, storage
  configuration, and network registration. Audit log delivery is gated by
  `audit_log_delivery_exists`.
- **Unity Catalog**: metastore (gated by `metastore_exists`), metastore
  assignment, and a catalog.
- **Network**: network policy and network connectivity configuration.
- **Workspace**: legacy-feature disabling, user assignment, and an example
  cluster (created because `compute_mode = HYBRID`).

Optional modules are off by default: the compliance security profile
(`enable_compliance_security_profile = false`) and the Security Analysis Tool
(`enable_security_analysis_tool`, default `false`).

Outputs: `workspace_host` (login URL) and `catalog_name`.

## Security Considerations

- **No public backend path for compute.** Control-plane traffic uses
  PrivateLink. Only the general-egress path leaves through NAT, which is a
  deliberate trade-off against SRA's isolated mode.
- **Endpoint policies differ from SRA.** SRA's own restrictive policies for the
  S3 gateway, STS, and Kinesis endpoints live in a module gated to non-custom
  mode, so they are not applied here. The `network/` endpoints have no `policy`
  argument and get AWS's default full-access policy. This is a known gap versus
  the SRA baseline.
- **Restrictive root bucket is still applied.** The `restrictive_root_bucket`
  module runs regardless of network mode.
- **Encryption.** The root bucket uses SSE-KMS with the workspace-storage CMK.
  The managed-services CMK is a separate key.
- **Cross-account trust.** The IAM role's trust policy uses the Databricks
  account ID as its external ID.
- **Credentials.** The service principal secret comes from environment
  variables, not files. `terraform.tfvars` and state files are gitignored.
- **State is local.** Neither root declares a remote backend. `terraform.tfstate`
  holds sensitive values and should be protected or moved to a remote backend.

## Known Constraints and Blockers

- **Blocker: Databricks account access.** Requires a Databricks free trial (E2)
  account linked to AWS account `549394392070`, plus a service principal with
  account-admin rights. Databricks Free Edition does not work because it has no
  account console or account-level API access, which every resource in
  `databricks-sra/` depends on. `databricks_account_id` is still blank.
- **Network IDs are blank until step 2.** The five `custom_*` values in
  `databricks-sra/terraform.tfvars` are filled only after `network/` is applied.
- **Metastore lifecycle.** With `metastore_exists = false`, SRA creates the
  metastore, and `terraform destroy` removes it.
- **Cost.** Resources bill continuously (about $0.15 to $0.20/hr for `network/`,
  per `BUILD_PLAN.md`) even on the free trial.
- **Teardown order.** `databricks-sra/` first, then `network/`.
- **Upstream constraint.** Unity Catalog securables are isolated per workspace;
  sharing needs `databricks_workspace_binding`.

## References

- [README.md](README.md): overall approach, two-directory structure, usage.
- [BUILD_PLAN.md](BUILD_PLAN.md): current deployment state and build sequence.
- [network/](network/): VPC and PrivateLink prerequisites.
- [databricks-sra/](databricks-sra/): vendored SRA module, with
  [UPSTREAM_README.md](databricks-sra/UPSTREAM_README.md).
- Upstream: https://github.com/databricks/terraform-databricks-sra
