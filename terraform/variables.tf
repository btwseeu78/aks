variable "region" {
  default = "us-east-1"
}
variable "cluster_name" {
  default = "eks-test"
}
variable "k8s_version" {
  default = "1.36"
}
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}
variable "pod_cidr" {
  default = "100.64.0.0/16"
}
variable "node_count" {
  default = 2
}
variable "admin_principle_arn" {
  default = null
}