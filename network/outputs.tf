output "custom_vpc_id" {
  value = aws_vpc.this.id
}

output "custom_private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "custom_sg_id" {
  value = aws_security_group.workspace.id
}

output "custom_general_access_vpce_id" {
  value = aws_vpc_endpoint.general_access.id
}

output "custom_scc_relay_vpce_id" {
  value = aws_vpc_endpoint.scc_relay.id
}
