# Prerequisite AWS network infrastructure for ../databricks-sra with
# network_configuration = "custom". Unlike SRA's built-in "isolated" mode,
# this VPC keeps normal internet egress (via NAT) so clusters can reach
# pip/PyPI, external APIs, etc. Backend connectivity to the Databricks
# control plane still goes over PrivateLink, matching SRA's model.
#
# Apply this directory FIRST, then copy its outputs into
# ../databricks-sra/terraform.tfvars (custom_vpc_id, custom_private_subnet_ids,
# custom_sg_id, custom_general_access_vpce_id, custom_scc_relay_vpce_id).

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.resource_prefix}-vpc"
  }
}

# Classic compute plane subnets (where clusters launch)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.resource_prefix}-private-${count.index}"
  }
}

# PrivateLink interface endpoint subnets
resource "aws_subnet" "privatelink" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.resource_prefix}-privatelink-${count.index}"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 4)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.resource_prefix}-public"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.resource_prefix}-igw"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.this]

  tags = {
    Name = "${var.resource_prefix}-nat"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.resource_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Shared by private + privatelink subnets: internet egress via NAT, plus the
# S3 gateway endpoint route added below.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.resource_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "privatelink" {
  count          = length(aws_subnet.privatelink)
  subnet_id      = aws_subnet.privatelink[count.index].id
  route_table_id = aws_route_table.private.id
}

# Cluster / workspace security group. Mirrors SRA's internode rules and adds
# open internet egress (SRA's isolated mode intentionally omits this).
resource "aws_security_group" "workspace" {
  name   = "${var.resource_prefix}-workspace-sg"
  vpc_id = aws_vpc.this.id

  dynamic "ingress" {
    for_each = ["tcp", "udp"]
    content {
      description = "Internode communication"
      from_port   = 0
      to_port     = 65535
      protocol    = ingress.value
      self        = true
    }
  }

  dynamic "egress" {
    for_each = ["tcp", "udp"]
    content {
      description = "Internode communication"
      from_port   = 0
      to_port     = 65535
      protocol    = egress.value
      self        = true
    }
  }

  egress {
    description = "Internet egress (pip installs, external APIs, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.resource_prefix}-workspace-sg"
  }
}

# Security group for PrivateLink interface endpoints
resource "aws_security_group" "privatelink" {
  name   = "${var.resource_prefix}-privatelink-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    description     = "REST API"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.workspace.id]
  }

  ingress {
    description     = "Secure Cluster Connectivity"
    from_port       = 6666
    to_port         = 6666
    protocol        = "tcp"
    security_groups = [aws_security_group.workspace.id]
  }

  ingress {
    description     = "Secure Cluster Connectivity (compliance security profile)"
    from_port       = 2443
    to_port         = 2443
    protocol        = "tcp"
    security_groups = [aws_security_group.workspace.id]
  }

  ingress {
    description     = "Compute plane to control plane internal calls"
    from_port       = 8443
    to_port         = 8443
    protocol        = "tcp"
    security_groups = [aws_security_group.workspace.id]
  }

  ingress {
    description     = "Unity Catalog logging and lineage streaming"
    from_port       = 8444
    to_port         = 8444
    protocol        = "tcp"
    security_groups = [aws_security_group.workspace.id]
  }

  tags = {
    Name = "${var.resource_prefix}-privatelink-sg"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.resource_prefix}-s3-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.privatelink.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_prefix}-sts-vpc-endpoint"
  }
}

resource "aws_vpc_endpoint" "kinesis" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.kinesis-streams"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.privatelink.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_prefix}-kinesis-vpc-endpoint"
  }
}

# Backend PrivateLink to the Databricks control plane: General Access (REST API)
resource "aws_vpc_endpoint" "general_access" {
  vpc_id              = aws_vpc.this.id
  service_name        = var.general_access_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.privatelink.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_prefix}-databricks-general-access"
  }
}

# Backend PrivateLink to the Databricks control plane: SCC Relay
resource "aws_vpc_endpoint" "scc_relay" {
  vpc_id              = aws_vpc.this.id
  service_name        = var.scc_relay_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.privatelink[*].id
  security_group_ids  = [aws_security_group.privatelink.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.resource_prefix}-databricks-scc-relay"
  }
}
