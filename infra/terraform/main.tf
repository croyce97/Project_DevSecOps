provider "aws" {
  region = "ap-southeast-2"
}

resource "aws_vpc" "canhnq_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "canhnq-vpc"
  }
}

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

resource "aws_internet_gateway" "canhnq_igw" {
  vpc_id = aws_vpc.canhnq_vpc.id

  tags = {
    Name = "canhnq-igw"
  }
}

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

resource "aws_route_table_association" "a" {
  count          = 2
  subnet_id      = aws_subnet.canhnq_subnet[count.index].id
  route_table_id = aws_route_table.canhnq_route_table.id
}

resource "aws_security_group" "canhnq_cluster_sd" {
  vpc_id = aws_vpc.canhnq_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "canhnq-cluster-sd"
  }
}

resource "aws_security_group" "canhnq_node_sd" {
  vpc_id = aws_vpc.canhnq_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "canhnq-node-sd"
  }
}

resource "aws_eks_cluster" "canhnq" {
  name     = "canhnq-cluster"
  role_arn = aws_iam_role.canhnq_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.canhnq_subnet[*].id
    security_group_ids = [aws_security_group.canhnq_cluster_sd.id]
  }

  tags = {
    Name = "control-plane"
  }
}

resource "aws_eks_node_group" "canhnq" {
  cluster_name    = aws_eks_cluster.canhnq.name
  node_group_name = "canhnq-node-group"
  node_role_arn   = aws_iam_role.canhnq_node_group_role.arn
  subnet_ids      = aws_subnet.canhnq_subnet[*].id

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  instance_types = ["t2.medium"]

  tags = {
    Name = "slave"
  }
}

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

resource "aws_iam_role_policy_attachment" "canhnq_node_group_role_policy" {
  role       = aws_iam_role.canhnq_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "canhnq_node_group_cni_policy" {
  role       = aws_iam_role.canhnq_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "canhnq_node_group_registry_policy" {
  role       = aws_iam_role.canhnq_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "canhnq_node_group_ssm_policy" {
  role       = aws_iam_role.canhnq_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

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

resource "aws_security_group" "sonarqube_sd" {
  vpc_id = aws_vpc.canhnq_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sonarqube-sd"
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

resource "aws_security_group" "gitlab_runner_sd" {
  vpc_id = aws_vpc.canhnq_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "gitlab-runner-sd"
  }
}

resource "aws_instance" "gitlab_runner" {
  ami           = data.aws_ami.ubuntu_2204.id
  instance_type = "t2.medium"
  subnet_id     = aws_subnet.canhnq_subnet[0].id
  vpc_security_group_ids = [aws_security_group.gitlab_runner_sd.id]
  tags = {
    Name = "gitlab-runner"
  }
}
