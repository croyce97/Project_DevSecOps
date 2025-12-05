# Hạ tầng AWS với Terraform: EKS & các EC2 dịch vụ

Dự án này triển khai hạ tầng AWS bằng Terraform, bao gồm một cụm EKS (Elastic Kubernetes Service) được quản lý và ba máy chủ EC2 bổ sung cho các dịch vụ CI/CD, monitoring. Tất cả tài nguyên được tạo ở khu vực `ap-southeast-2` (Sydney).

## Tổng quan kiến trúc

### Mạng

- **VPC**: VPC tuỳ chỉnh với CIDR `10.0.0.0/16`
- **Public Subnet**: 2 subnet công khai ở `ap-southeast-2a` và `ap-southeast-2b`
- **Internet Gateway**: Kết nối internet cho VPC
- **Route Table**: Tuyến mặc định (`0.0.0.0/0`) ra Internet Gateway

### Security Group

- **EKS Cluster Security Group (`canhnq_cluster_sd`)**: Cho phép toàn bộ egress từ control plane của EKS
- **EKS Node Security Group (`canhnq_node_sd`)**: Cho phép toàn bộ ingress/egress cho các worker node
- **Security Group dịch vụ**: Mỗi EC2 dịch vụ (SonarQube, GitLab Runner) có security group riêng (`*_sd`) cho phép toàn bộ ingress/egress (chỉ nên dùng cho demo, cần siết lại cho production)

### Hạ tầng Kubernetes

- **EKS Cluster**: Control plane Kubernetes được quản lý (`canhnq-cluster`)
- **EKS NodeGroup**: 2 EC2 `t2.medium` (EKS-Optimized AMI, do AWS quản lý)

### Các EC2 dịch vụ bổ sung (Ubuntu 22.04 LTS)

Dùng cho các công cụ DevOps phổ biến:

- **SonarQube**: 1 EC2 `t2.medium`, Ubuntu 22.04 LTS
- **GitLab Runner**: 1 EC2 `t2.medium`, Ubuntu 22.04 LTS (cài 2 runner: shell executor và kubernetes executor)

> **Lưu ý:** Chỉ 3 EC2 dịch vụ này dùng Ubuntu 22.04 LTS. NodeGroup của EKS dùng AMI tối ưu EKS mặc định.

### GitLab Runner

Máy chủ GitLab Runner cài đặt 2 runner:

- **Shell Executor**: Dùng cho các job build Docker, scan SonarQube, Maven, Trivy
- **Kubernetes Executor**: Dùng cho các job deploy ứng dụng lên EKS cluster

### IAM

- **Cluster Role**: `canhnq-cluster-role` với `AmazonEKSClusterPolicy`
- **NodeGroup Role**: `canhnq-node-group-role` với:
  - `AmazonEKSWorkerNodePolicy`
  - `AmazonEKS_CNI_Policy`
  - `AmazonEC2ContainerRegistryReadOnly`
  - `AmazonSSMManagedInstanceCore`

## Cấu trúc dự án

```
terraform/
├── main.tf      # Hạ tầng chính: VPC, subnet, EKS, security group, IAM, EC2 dịch vụ
└── output.tf    # Output (ID cluster, VPC, subnet, ...)
```

## Tài nguyên chính trong Terraform

### 1. Khu vực (main.tf)

```terraform
provider "aws" {
  region = "ap-southeast-2"
}
```

Cấu hình AWS Provider để sử dụng khu vực Sydney (ap-southeast-2). Tất cả các tài nguyên sẽ được tạo trong khu vực này.

### 2. VPC (Virtual Private Cloud)

```terraform
resource "aws_vpc" "canhnq_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "canhnq-vpc"
  }
}
```

Tạo một VPC tùy chỉnh với khối địa chỉ IP `10.0.0.0/16`, cung cấp 65,536 địa chỉ IP có sẵn. Tag `Name` giúp dễ dàng xác định tài nguyên trong bảng điều khiển AWS.

### 3. Public Subnets

```terraform
resource "aws_subnet" "canhnq_subnet" {
  count = 2
  vpc_id                  = aws_vpc.canhnq_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.canhnq_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["ap-southeast-2a", "ap-southeast-2b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "canhnq-subnet-${count.index}"
  }
}
```

- **count = 2**: Tạo 2 mạng con (một trong mỗi vùng sẵn dùng)
- **cidrsubnet()**: Chia khối CIDR VPC thành 2 mạng con (/24 mỗi cái)
  - Subnet 0: `10.0.0.0/24`
  - Subnet 1: `10.0.1.0/24`
- **availability_zone**: Phân phối các mạng con trên 2 vùng sẵn dùng khác nhau để tăng tính sẵn dùng
- **map_public_ip_on_launch = true**: Tự động gán địa chỉ IP công khai cho các phiên bản trong mạng con này

### 4. Internet Gateway

```terraform
resource "aws_internet_gateway" "canhnq_igw" {
  vpc_id = aws_vpc.canhnq_vpc.id
  tags = {
    Name = "canhnq-igw"
  }
}
```

Tạo và gắn Internet Gateway vào VPC. Điều này cho phép các tài nguyên trong VPC giao tiếp với internet.

### 5. Route Table

```terraform
resource "aws_route_table" "canhnq_route_table" {
  vpc_id = aws_vpc.canhnq_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.canhnq_igw.id
  }

  tags = {
    Name = "canhnq-route-table"
  }
}
```

Định nghĩa bảng định tuyến với quy tắc: tất cả lưu lượng đi (0.0.0.0/0) được chuyển hướng đến Internet Gateway, cho phép các máy chủ trong mạng con truy cập internet.

### 6. Route Table Association

```terraform
resource "aws_route_table_association" "a" {
  count          = 2
  subnet_id      = aws_subnet.canhnq_subnet[count.index].id
  route_table_id = aws_route_table.canhnq_route_table.id
}
```

Liên kết bảng định tuyến với cả hai mạng con, áp dụng quy tắc định tuyến cho lưu lượng từ các mạng con.

### Security Group

- `canhnq_cluster_sd`: EKS control plane egress
- `canhnq_node_sd`: EKS worker node ingress/egress
- `sonarqube_sd`, `gitlab_runner_sd`: EC2 dịch vụ (toàn bộ ingress/egress)

> Khi triển khai production, cần siết lại rule cho phù hợp.

### Ví dụ: EC2 Ubuntu 22.04 LTS (SonarQube)

```hcl
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "sonarqube" {
  ami           = data.aws_ami.ubuntu_2204.id
  instance_type = "t2.medium"
  subnet_id     = aws_subnet.canhnq_subnet[0].id
  vpc_security_group_ids = [aws_security_group.sonarqube_sd.id]
  tags = {
    Name = "sonarqube"
  }
}
```

> NodeGroup của EKS dùng AMI tối ưu EKS mặc định, do AWS quản lý.

### EKS Cluster

```terraform
resource "aws_eks_cluster" "canhnq" {
  name     = "canhnq-cluster"
  role_arn = aws_iam_role.canhnq_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.canhnq_subnet[*].id
    security_group_ids = [aws_security_group.canhnq_cluster_sg.id]
  }
}
```

- Tạo mặt phẳng điều khiển EKS (Kubernetes API server, etcd, v.v.)
- **role_arn**: Tham chiếu đến IAM role cho phép dịch vụ EKS
- **subnet_ids = aws_subnet.canhnq_subnet[*].id**: Triển khai mặt phẳng điều khiển trên cả hai mạng con (splat syntax `[*]`)
- **security_group_ids**: Gắn nhóm bảo mật cụm

### EKS NodeGroup

```terraform
resource "aws_eks_node_group" "canhnq" {
  cluster_name    = aws_eks_cluster.canhnq.name
  node_group_name = "canhnq-node-group"
  node_role_arn   = aws_iam_role.canhnq_node_group_role.arn
  subnet_ids      = aws_subnet.canhnq_subnet[*].id

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  instance_types = ["t2.medium"]
}
```

- **node_group_name**: Tên nhóm nút
- **scaling_config**: 2 nút cố định (desired = max = min = 2)
- **instance_types = ["t2.medium"]**: Sử dụng phiên bản t2.medium (2 vCPU, 4GB RAM)
- **Không có remote_access block**: Sử dụng AWS Systems Manager Session Manager thay vì SSH

### IAM Role

**Cluster Role:**

```terraform
resource "aws_iam_role" "canhnq_cluster_role" {
  name = "canhnq-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "canhnq_cluster_role_policy" {
  role       = aws_iam_role.canhnq_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
```

- **assume_role_policy**: Cho phép dịch vụ EKS (eks.amazonaws.com) giả định vai trò này
- **AmazonEKSClusterPolicy**: Chính sách quản lý được cung cấp bởi AWS cho phép EKS quản lý tài nguyên

**Node Group Role:**

```terraform
resource "aws_iam_role" "canhnq_node_group_role" {
  name = "canhnq-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}
```

Cho phép dịch vụ EC2 (các phiên bản) giả định vai trò này.

**Gắn kèm các chính sách:**

- **AmazonEKSWorkerNodePolicy**: Quyền cơ bản để nút Kubernetes hoạt động
- **AmazonEKS_CNI_Policy**: Cho phép giao diện mạng container (CNI) quản lý địa chỉ IP pod
- **AmazonEC2ContainerRegistryReadOnly**: Cho phép nút kéo các hình ảnh từ Amazon ECR
- **AmazonSSMManagedInstanceCore**: Cho phép AWS Systems Manager Session Manager truy cập nút

### Output

```terraform
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
```

Xuất các định danh tài nguyên quan trọng sau khi triển khai hoàn tất. Sử dụng `terraform output` để xem các giá trị này.

## Bắt đầu

### Yêu cầu

- Tài khoản AWS có quyền EC2, VPC, EKS, IAM
- Terraform >= 1.0
- AWS CLI đã cấu hình credentials
- Quyền IAM cho AWS Systems Manager Session Manager
- `kubectl` để thao tác với Kubernetes

### Các bước triển khai

1. Di chuyển vào thư mục `terraform/`:

```bash
cd terraform/
```

2. Khởi tạo Terraform:

```bash
terraform init
```

3. Kiểm tra cấu hình:

```bash
terraform validate
```

4. Xem trước thay đổi:

```bash
terraform plan
```

5. Áp dụng thay đổi:

```bash
terraform apply
```

Xác nhận `yes` khi được hỏi.

### Sau khi triển khai

- Xem output:

```bash
  terraform output
```

- Cập nhật kubeconfig cho EKS:

```bash
  aws eks update-kubeconfig --name canhnq-cluster --region ap-southeast-2
  kubectl get nodes
```
