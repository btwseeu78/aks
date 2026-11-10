output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "private_subnets" {
  value = { for k, s in aws_subnet.private : k => s.cidr_block }
}

output "public_subnets" {
  value = { for k, s in aws_subnet.public : k => s.cidr_block }
}

output "pod_subnets" {
  value = { for k, s in aws_subnet.pod : k => s.cidr_block }
}

output "eniconfig_yaml" {
  value = join("---\n", [for az, s in aws_subnet.pod : yamlencode({
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata   = { name = az }
    spec = {
      subnet         = s.id
      securityGroups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
    }
  })])
}
