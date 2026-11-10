# EKS on Terraform: VPC Design, Secondary Pod CIDR, IAM, and Testing

A sequential build guide. Every step has **What**, **Why**, the code, and a **Check**.
Everything in AWS is Terraform. Everything inside the cluster is `kubectl` (no Terraform kubernetes/helm provider).

---

## What "prefix" means here (two things, both covered)

1. **CIDR prefix math**: splitting `10.0.0.0/16` into smaller prefixes (/20, /24) using `cidrsubnet()`.
2. **VPC CNI prefix delegation**: pods get IPs in blocks of /28 (16 IPs) per ENI slot instead of one IP per slot. This raises pod density and needs contiguous free space in the subnet.

## Final architecture

```
VPC
├─ 10.0.0.0/16  (primary)     nodes, NAT, load balancers
│    private /20 x3  ──► node primary ENI, route 0.0.0.0/0 -> NAT
│    public  /24 x3  ──► ALB/NLB + NAT gateway, route 0.0.0.0/0 -> IGW
│    free    10.0.64.0 onward (reserved for future tiers)
│
└─ 100.64.0.0/16 (secondary)  pods only
     pod /18 x3      ──► pod ENIs (about 16k IPs per AZ)
                         upper half of each /18 reserved for /28 prefixes
```

**Goal:** many pods without consuming the primary range. Nodes stay in `10.0.x.x`, pods live in `100.64.x.x`.

**Answer to "can the secondary also be /16?"** Yes. AWS allows every IPv4 block on a VPC, primary or additional, to be between /16 and /28. The rules: no overlap with existing blocks, a block can't be resized after association, a per-VPC quota on block count applies, and certain ranges are restricted depending on your primary. 100.64.0.0/10 blocks between /16 and /28 are listed as permitted. Check for conflicts if you use Tailscale or another overlay that also uses 100.64.0.0/10.

---

## Step 0: Prerequisites

- Terraform >= 1.6, AWS CLI v2, kubectl.
- AWS credentials for an account/region where you can create VPCs, EKS, and IAM roles. Verify with `aws sts get-caller-identity`.
- Costs while it runs: EKS control plane (hourly), NAT gateway (hourly + data), EC2 nodes. **Destroy when done (Step 17).**
- The region needs at least 3 AZs (the code takes the first three).

For a scoped Terraform role, in addition to normal VPC/EKS/IAM permissions you need:
`ec2:AssociateVpcCidrBlock`, `ec2:DisassociateVpcCidrBlock`, `ec2:CreateSubnetCidrReservation`, `ec2:DeleteSubnetCidrReservation`, `iam:PassRole` on the roles created below. If `apply` fails with `UnauthorizedOperation`, the error names the missing action.

Project layout:

```
eks-lab/
├── versions.tf
├── variables.tf
├── locals.tf
├── vpc.tf          # VPC, secondary CIDR, subnets, routing, prefix reservations
├── iam.tf
├── eks.tf          # cluster, launch template, node group
├── addons.tf
└── outputs.tf
```

---

## Step 1: Design the address plan

**What:** decide which prefix sizes each tier gets before writing any code.

**Why:** subnets cannot be resized, and with the VPC CNI every pod consumes a real VPC IP, so pod capacity is a subnet-sizing decision. Get this right first.

| Tier | Block | Prefix | Subnets | Purpose |
|---|---|---|---|---|
| Private | 10.0.0.0/16 | /20 | 10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20 | Node primary ENIs, route to NAT |
| Public | 10.0.0.0/16 | /24 | 10.0.48.0/24, 10.0.49.0/24, 10.0.50.0/24 | Load balancers, NAT, route to IGW |
| Pod | 100.64.0.0/16 | /18 | 100.64.0.0/18, 100.64.64.0/18, 100.64.128.0/18 | Pod ENIs only |

Sizes for reference (AWS reserves 5 IPs per subnet): /18 = 16,379 usable, /20 = 4,091, /24 = 251, /28 = 16 IPs (prefix delegation unit).

Rules that produce these numbers:

- A prefix must start on a multiple of its own size, otherwise it overlaps its neighbour. `10.0.32.0/20` ends at `10.0.47.255`, so the public /24s start at `10.0.48.0`.
- Public vs private is only a routing difference. Public has `0.0.0.0/0 -> Internet Gateway`, private has `0.0.0.0/0 -> NAT Gateway`.
- A subnet lives inside exactly one VPC CIDR block. Node subnets come from the primary, pod subnets from the secondary.

**`cidrsubnet(prefix, newbits, netnum)`** adds `newbits` to the prefix length and picks block number `netnum`:

- `cidrsubnet("10.0.0.0/16", 4, 1)` -> `10.0.16.0/20`
- `cidrsubnet("10.0.0.0/16", 8, 48)` -> `10.0.48.0/24`
- `cidrsubnet("100.64.0.0/16", 2, 1)` -> `100.64.64.0/18`

**Check:** test the math before building anything.

```bash
terraform console
> cidrsubnet("10.0.0.0/16", 4, 2)
"10.0.32.0/20"
> cidrsubnet("100.64.0.0/16", 2, 2)
"100.64.128.0/18"
```

---

## Step 2: Providers and variables

**What:** pin versions and define inputs.

**Why:** pinned providers mean an upgrade never silently changes your plan. Inputs keep CIDRs, names, and node count in one place. `node_count` defaults to 0 because the build is phased (Steps 12-14).

`versions.tf`

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.60" }
  }
}

provider "aws" {
  region = var.region
}
```

`variables.tf`

```hcl
variable "region"       { default = "ap-south-1" }
variable "cluster_name" { default = "eks-test" }
variable "k8s_version"  { default = "1.33" }          # check currently supported EKS versions
variable "vpc_cidr"     { default = "10.0.0.0/16" }
variable "pod_cidr"     { default = "100.64.0.0/16" }
variable "node_count"   { default = 0 }               # phase 1 = 0, phase 3 = 2
variable "admin_principal_arn" { default = null }     # optional extra kubectl admin (IAM role/user ARN)
```

**Check:** `terraform init && terraform validate`

---

## Step 3: Compute subnets once (locals)

**What:** derive every subnet CIDR from the VPC CIDRs.

**Why:** one source of truth. Changing `vpc_cidr` or `pod_cidr` re-derives every subnet consistently. Maps keyed by AZ let `for_each` keep stable addresses, whereas `count` would shift indexes and recreate the wrong subnets if an AZ were removed.

`locals.tf`

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # /20 private: 10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20
  private_subnets = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 4, i) }

  # /24 public: 10.0.48.0/24, 10.0.49.0/24, 10.0.50.0/24
  public_subnets = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, 48 + i) }

  # /18 pods from the secondary CIDR: 100.64.0.0/18, 100.64.64.0/18, 100.64.128.0/18
  pod_subnets = { for i, az in local.azs : az => cidrsubnet(var.pod_cidr, 2, i) }
}
```

**Check:** after Step 4, `terraform plan` should show exactly these CIDRs.

---

## Step 4: VPC, secondary CIDR, and subnets

**What:** create the VPC, attach the second CIDR, create three tiers of subnets.

**Why:**

- `enable_dns_support` and `enable_dns_hostnames` are required by EKS. Nodes and the API endpoint resolve through VPC DNS.
- The secondary CIDR gives pods their own address space.
- Subnet tags drive discovery: `kubernetes.io/role/elb` marks where internet-facing load balancers go, `kubernetes.io/role/internal-elb` marks internal ones. **Pod subnets get neither tag on purpose**, otherwise a load balancer controller could place LBs there.
- Pod subnets take `vpc_id` from the CIDR association resource so Terraform creates the association first. Otherwise subnet creation fails.

`vpc.tf` (part 1)

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = var.cluster_name }
}

resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  vpc_id     = aws_vpc.this.id
  cidr_block = var.pod_cidr
}

resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "${var.cluster_name}-public-${each.key}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  for_each          = local.private_subnets
  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value
  tags = {
    Name                                        = "${var.cluster_name}-private-${each.key}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "pod" {
  for_each          = local.pod_subnets
  vpc_id            = aws_vpc_ipv4_cidr_block_association.pods.vpc_id   # orders after the association
  availability_zone = each.key
  cidr_block        = each.value
  tags = { Name = "${var.cluster_name}-pod-${each.key}" }
}
```

**Check:** later, `aws ec2 describe-vpcs --vpc-ids <id> --query 'Vpcs[].CidrBlockAssociationSet[].CidrBlock'` lists both CIDRs. If the association is rejected, the range overlaps or is restricted for your primary; pick another secondary range.

---

## Step 5: Internet access and routing

**What:** Internet Gateway, one NAT gateway, two route tables, associations.

**Why:**

- Public subnets need an IGW for inbound/outbound internet (load balancers, NAT).
- Nodes and pods sit in private subnets with no public IPs, but need outbound access (image pulls, AWS APIs). They reach out via NAT, which lives in a **public** subnet.
- AWS automatically adds a `local` route for each VPC CIDR, so `10.0.x` and `100.64.x` can talk to each other with no extra routes.
- One NAT keeps a test cluster cheap. For production, use one per AZ so an AZ failure doesn't take out egress.
- Pod subnets share the private route table. With custom networking, off-VPC pod traffic is source-NATed to the node's primary IP, but associating the table keeps routing behaviour explicit and consistent.

`vpc.tf` (part 2)

```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id   # NAT must be in a PUBLIC subnet
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "pod" {
  for_each       = aws_subnet.pod
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
```

**Check:** `terraform plan` shows a NAT gateway, one EIP, and 9 route table associations.

---

## Step 6: Reserve prefix space in the pod subnets

**What:** dedicate the upper half of each pod subnet to /28 prefix allocations only.

**Why:** with prefix delegation each ENI slot needs a **contiguous** /28. If single IPs (e.g. ENI primary IPs) get scattered through the subnet, a free /28 may not exist and pods fail with `InsufficientCidrBlocks` even though IPs are free. A `prefix` reservation makes that half usable only for prefixes, so ENI primary IPs come from the lower half and the reserved half stays contiguous.

Create this before nodes exist. If nodes already hold IPs in the range, the reservation fails.

`vpc.tf` (part 3)

```hcl
resource "aws_ec2_subnet_cidr_reservation" "pod_prefixes" {
  for_each         = aws_subnet.pod
  subnet_id        = each.value.id
  cidr_block       = cidrsubnet(each.value.cidr_block, 1, 1)   # upper /19 of each /18
  reservation_type = "prefix"
}
```

Example: for `100.64.0.0/18` the reserved block is `100.64.32.0/19`.

---

## Step 7: IAM roles

There are up to five identities. This step creates the two that are required; Step 16 adds a dedicated CNI role as hardening.

| # | Identity | Trusted by | Why it exists |
|---|---|---|---|
| 1 | Cluster role | `eks.amazonaws.com` | Lets the EKS control plane create ENIs and manage networking in your account |
| 2 | Node role | `ec2.amazonaws.com` | Lets nodes register, pull images, and lets the CNI manage ENIs/IPs |
| 3 | CNI role (Step 16) | `pods.eks.amazonaws.com` | Gives only the `aws-node` pods the CNI permissions instead of every pod on the node |
| 4 | Access entries | IAM principal | Maps an IAM user/role to Kubernetes cluster-admin |
| 5 | Terraform runner | your CI/user | Needs EC2 permissions listed in Step 0 |

**Node role policies, one by one:**

- `AmazonEKSWorkerNodePolicy`: kubelet can describe the cluster and register the node.
- `AmazonEC2ContainerRegistryReadOnly`: nodes can pull from ECR. Without it, ECR images end in `ImagePullBackOff`.
- `AmazonEKS_CNI_Policy`: the VPC CNI creates/attaches/deletes ENIs, assigns IPs and prefixes, and tags them. This is what makes custom networking and prefix delegation work. Nothing extra is needed for the secondary CIDR.

`iam.tf`

```hcl
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonEKS_CNI_Policy",          # removed in Step 16 after the dedicated CNI role works
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
}

# Optional: extra kubectl admin (a teammate or CI role).
# The identity running terraform is already admin via bootstrap_cluster_creator_admin_permissions.
resource "aws_eks_access_entry" "admin" {
  count         = var.admin_principal_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_principal_arn
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.admin_principal_arn == null ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
```

**Why access entries:** IAM authenticates you to AWS, but Kubernetes needs to know what you may do. Access entries map an IAM principal to Kubernetes permissions and replace the old `aws-auth` ConfigMap, so access stays under Terraform.

---

## Step 8: The EKS cluster

**What:** the control plane, attached to your subnets.

**Why:**

- The control plane creates ENIs in the subnets you list so it can reach nodes. **Pod subnets are not listed here.** Only the ENIConfig references them.
- `endpoint_private_access = true` lets nodes reach the API inside the VPC. `endpoint_public_access = true` lets you run kubectl from your laptop. Restrict it with `public_access_cidrs` (your IP/32) or turn it off and use a VPN/bastion.
- `authentication_mode = "API"` uses access entries. `bootstrap_cluster_creator_admin_permissions = true` makes the identity running `terraform apply` cluster-admin. This can't be changed after creation.

`eks.tf` (part 1)

```hcl
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.k8s_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat([for s in aws_subnet.private : s.id], [for s in aws_subnet.public : s.id])
    endpoint_private_access = true
    endpoint_public_access  = true
    # public_access_cidrs   = ["<your-ip>/32"]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}
```

---

## Step 9: Managed node group with a launch template

**What:** worker nodes in the private subnets, with `maxPods` raised.

**Why:**

- Nodes go only in private subnets (no public IPs, outbound via NAT).
- **Custom networking** moves pod IPs off the primary ENI, and **prefix delegation** hands out /28 blocks. Kubelet doesn't know that and keeps a small default (about 17 pods on a t3.medium), so you would never reach "many pods". The launch template sets `maxPods: 110` (AWS's recommended cap for small instances) through the AL2023 `NodeConfig`.
- Capacity check for t3.medium (3 ENIs, 6 slots each) with custom networking: `(3-1) x (6-1) x 16 = 160` pod IPs, more than the 110 cap.
- Prefix delegation requires Nitro instances (t3 is Nitro).
- `desired_size` comes from `var.node_count` (0 in phase 1). The node group waits for the CNI add-on so its config is in place before any node joins.

`eks.tf` (part 2)

```hcl
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"
  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: 110
    --BOUNDARY--
  EOT
  )
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [for s in aws_subnet.private : s.id]
  instance_types  = ["t3.medium"]
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = var.node_count
    min_size     = 0
    max_size     = 3
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
  ]
}
```

---

## Step 10: Add-ons (CNI, kube-proxy, CoreDNS)

**What:** configure the VPC CNI for custom networking + prefix delegation, and manage the other core add-ons.

**Why each env var:**

| Setting | Effect |
|---|---|
| `AWS_VPC_K8S_CNI_CUSTOM_CNI=true` | Pod ENIs are created in the subnet named by the node's ENIConfig, not the node's subnet |
| `ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone` | The CNI picks the ENIConfig whose name equals the node's AZ |
| `ENABLE_PREFIX_DELEGATION=true` | Each ENI slot holds a /28 instead of one IP; gives back the capacity lost by not using the primary ENI for pods |
| `WARM_PREFIX_TARGET=1` | Keep one spare /28 ready so new pods start fast |

**CoreDNS is gated on node count.** With zero nodes its pods can't schedule and the add-on would hang in DEGRADED, failing the phase-1 apply. `kube-proxy` and `vpc-cni` are DaemonSets, so zero nodes is fine for them.

`addons.tf`

```hcl
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      AWS_VPC_K8S_CNI_CUSTOM_CNI = "true"
      ENI_CONFIG_LABEL_DEF       = "topology.kubernetes.io/zone"
      ENABLE_PREFIX_DELEGATION   = "true"
      WARM_PREFIX_TARGET         = "1"
    }
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  count                       = var.node_count > 0 ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}
```

---

## Step 11: Outputs, including the ENIConfig YAML

**What:** emit the Kubernetes `ENIConfig` objects as YAML from Terraform.

**Why:** subnet IDs exist only after Terraform creates them. Rendering the YAML from Terraform avoids copy-paste mistakes and keeps Terraform as the single source of truth, while the objects themselves are applied with `kubectl`, not the Terraform provider.

- The ENIConfig **name must equal the AZ name**, matching `ENI_CONFIG_LABEL_DEF`.
- `securityGroups` uses the cluster security group. Nodes and the control plane already share it, so pods on the secondary ENIs can reach both.

`outputs.tf`

```hcl
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
```

---

## Step 12: Apply, phase 1 (network + control plane, zero nodes)

**Why phased:** custom networking only affects **new** ENIs. If nodes join before the ENIConfigs exist, `aws-node` can't assign pod IPs and nodes sit NotReady. Building the control plane and CNI config first, then the ENIConfigs, then nodes avoids that.

```bash
terraform init
terraform fmt && terraform validate
terraform plan -out tfplan      # read it: check subnet CIDRs, expect ~50 resources
terraform apply tfplan          # ~12-15 min, the control plane is the slow part
```

Planning to a file means what you reviewed is exactly what gets applied.

**Check:**

```bash
aws eks update-kubeconfig --name eks-test --region ap-south-1
kubectl get ns                  # works: you are cluster-admin
kubectl get nodes               # empty, expected
```

---

## Step 13: Phase 2, create the ENIConfigs with kubectl

```bash
terraform output -raw eniconfig_yaml | kubectl apply -f -
kubectl get eniconfig           # three entries, named after the AZs
```

**Check:** `kubectl get eniconfig -o yaml` shows subnet IDs from `100.64.x` subnets and the cluster security group.

---

## Step 14: Phase 3, bring up nodes

```bash
terraform apply -var node_count=2
```

This creates the nodes and the CoreDNS add-on. Nodes take a few minutes to become Ready.

To keep it, put `node_count = 2` in `terraform.tfvars`.

---

## Step 15: Verify everything with kubectl

```bash
# 1. Nodes are in the primary range (10.0.x.x)
kubectl get nodes -o wide

# 2. Which ENIConfig each node used
kubectl get nodes -o custom-columns='NAME:.metadata.name,ENICONFIG:.metadata.annotations.vpc\.amazonaws\.com/eniConfig'

# 3. Max pods actually applied (expect 110 per node)
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.pods}{"\n"}'

# 4. CNI settings took effect
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -E 'CUSTOM_CNI|PREFIX|ENI_CONFIG'

# 5. Scale test: pods land in the secondary range
kubectl create deployment pause --image=registry.k8s.io/pause:3.9 --replicas=150
kubectl rollout status deployment/pause
kubectl get pods -l app=pause -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' \
  | cut -d. -f1-2 | sort | uniq -c            # expect 100.64 only

# 6. Primary range was not consumed
aws ec2 describe-subnets --filters "Name=tag:Name,Values=eks-test-private-*" \
  --query 'Subnets[].[CidrBlock,AvailableIpAddressCount]' --output table

# 7. Egress through NAT
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -- curl -sI https://aws.amazon.com

# 8. Load balancer lands in public subnets (tags work)
kubectl create deployment web --image=nginx
kubectl expose deployment web --port=80 --type=LoadBalancer
kubectl get svc web -w                          # wait for EXTERNAL-IP, then curl it
```

Expected results:

- Nodes `10.0.x.x`, pods `100.64.x.x`.
- Private subnets show almost their full `/20` still free (only node IPs used).
- 150 pods running across 2 nodes.

Clean up test workloads: `kubectl delete deployment pause web && kubectl delete svc web`

---

## Step 16: Hardening, give the CNI its own IAM role (Pod Identity)

**What:** move the CNI permissions from the node role to a role only the `aws-node` service account can use.

**Why:** with `AmazonEKS_CNI_Policy` on the node role, **every pod on the node** can call the EC2 ENI APIs through the instance metadata. Pod Identity limits those permissions to the CNI.

Do this only after Step 15 passes, so you know the base build works.

Add to `iam.tf`:

```hcl
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]   # TagSession is required by Pod Identity
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.cluster_name}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
```

Add to `addons.tf`:

```hcl
# The agent that hands credentials to pods (a DaemonSet, so gate on nodes like coredns)
resource "aws_eks_addon" "pod_identity_agent" {
  count                       = var.node_count > 0 ? 1 : 0
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}
```

Add this block **inside** the existing `aws_eks_addon.vpc_cni` resource:

```hcl
  pod_identity_association {
    role_arn        = aws_iam_role.vpc_cni.arn
    service_account = "aws-node"
  }
```

Migration order (there is a startup race between the agent and `aws-node` on a fresh node, so the fallback stays until proven):

1. `terraform apply`. The node role still has `AmazonEKS_CNI_Policy`, which acts as the fallback.
2. Confirm: `kubectl -n kube-system get ds eks-pod-identity-agent` is fully ready, `aws eks list-pod-identity-associations --cluster-name eks-test` lists `aws-node`, and pods still get IPs.
3. Remove `"AmazonEKS_CNI_Policy"` from the node role list in `iam.tf`, apply, then recycle the nodes.

---

## Step 17: Destroy safely

```bash
kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer   # or delete each LB service by name
terraform destroy
```

**Why the LB deletion first:** AWS load balancers created by Kubernetes are not in Terraform state. They hold ENIs in your subnets, and if they still exist the subnet and VPC deletion hangs.

If `destroy` stalls on a subnet, look for leftover ENIs in that subnet (`aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=<id>`) and delete the orphaned `available` ones.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Phase 1 apply hangs on CoreDNS add-on | CoreDNS created with zero nodes | Keep the `count = var.node_count > 0 ? 1 : 0` gate (Step 10) |
| Nodes NotReady after phase 3 | ENIConfig missing, or its name doesn't equal the AZ name | `kubectl get eniconfig`; recreate from `terraform output -raw eniconfig_yaml`; check `aws-node` logs |
| Pods stuck `ContainerCreating`, "failed to assign an IP" | Prefix space exhausted or fragmented, or CNI IAM missing | Check the reservation (Step 6), the node/CNI role (Step 7/16), and `kubectl -n kube-system logs ds/aws-node` |
| `InsufficientCidrBlocks` | No contiguous /28 in the pod subnet | Confirm the prefix reservation exists; enlarge pod subnets |
| Max pods still about 17 | Launch template not applied, or nodes not recycled | Check `allocatable.pods`; replace nodes after fixing the template |
| Pods on `10.0.x` instead of `100.64.x` | Nodes joined before custom networking was configured | Cordon/drain and replace nodes (custom networking only affects new ENIs) |
| Secondary CIDR association fails | Overlap or restricted range for your primary | Choose a different non-overlapping range |
| LB in wrong subnets / not created | Missing role tags, or role tags on pod subnets | Verify the tags in Step 4 |
| `UnauthorizedOperation` | Terraform runner lacks an EC2/IAM action | Add the action named in the error (Step 0 list) |
| `kubectl` says Unauthorized | Different AWS identity than the one that ran `apply` | Use the same profile, or add an access entry (Step 7) |

---

## Behaviour changes to know about

- **Pods aren't routable outside the VPC.** Off-VPC traffic is source-NATed to the node IP, so `100.64.x` means nothing to on-prem or peered networks. Fine for egress and for ALB/NLB with `target-type: ip` (same VPC, local route). It breaks designs needing direct pod IP reachability across peering or Transit Gateway.
- **`hostNetwork` pods** use the node IP and ignore all of this.
- **Private subnets are oversized now.** They hold only node primary IPs, so /22 would do. Subnets can't be resized, so decide before creating them.
- **Enabling custom networking on a running cluster** requires draining and replacing every node.
- **Karpenter** works with the same ENIConfig approach (it sets the AZ label). Set max pods in its `EC2NodeClass`, not a launch template.
- **Alternative to all this:** an IPv6 cluster removes IP exhaustion, at the cost of IPv6 support across everything that talks to the cluster.

## Production checklist

- One NAT gateway per AZ.
- Restrict `public_access_cidrs`, or make the endpoint private and use a VPN/bastion.
- VPC endpoints for S3 (gateway), ECR, and STS to cut NAT cost and keep traffic private.
- Replace broad Terraform-runner permissions with the scoped set in Step 0.
- Remote state (S3 + locking) instead of local state.
- Install the AWS Load Balancer Controller for proper ALB/NLB management with IP targets.
