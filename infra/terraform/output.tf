output "cluster_id" {
  value = aws_eks_cluster.canhnq.id
}

output "node_group_id" {
  value = aws_eks_node_group.canhnq.id
}

output "vpc_id" {
  value = aws_vpc.canhnq_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.canhnq_subnet[*].id
}