#create vpc and subnets
resource "aws_vpc" "main" {
  cidr_block = "10.222.0.0/16"
}

resource "aws_subnet" "pub1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.222.0.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true

  tags = {
    Name                               = "prod1"
    "kubernetes.io/role/elb"           = 1
    "kubernetes.io/cluster/DevCluster" = "shared"
  }
}

resource "aws_subnet" "pub2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.222.1.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true
  tags = {
    Name                               = "prod2"
    "kubernetes.io/role/elb"           = 1
    "kubernetes.io/cluster/DevCluster" = "shared"
  }
}

resource "aws_subnet" "pub3" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.222.3.0/24"
  availability_zone       = "eu-west-1c"
  map_public_ip_on_launch = true
  tags = {
    Name                               = "prod3"
    "kubernetes.io/role/elb"           = 1
    "kubernetes.io/cluster/DevCluster" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "main"
  }
}

resource "aws_route_table_association" "pub1" {
  subnet_id      = aws_subnet.pub1.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "pub2" {
  subnet_id      = aws_subnet.pub2.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "pub3" {
  subnet_id      = aws_subnet.pub3.id
  route_table_id = aws_route_table.main.id
}

############################## cluster role #############################
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cluster_role" {
  name               = "eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "role_attachment_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster_role.name
}

resource "aws_iam_role_policy_attachment" "controller_attachment_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster_role.name
}

######################### cluster ############################
resource "aws_eks_cluster" "dev_cluster" {
  name     = "DevCluster"
  role_arn = aws_iam_role.cluster_role.arn

  vpc_config {
    subnet_ids = [aws_subnet.pub1.id, aws_subnet.pub2.id]
  }
  depends_on = [
    aws_iam_role_policy_attachment.role_attachment_policy,
    aws_iam_role_policy_attachment.controller_attachment_policy,
  ]
}

#################### Node group ######################
resource "aws_eks_node_group" "n_group" {
  cluster_name    = aws_eks_cluster.dev_cluster.name
  node_group_name = "devNodeGroup"
  node_role_arn   = aws_iam_role.node_group_role.arn
  subnet_ids      = [aws_subnet.pub1.id, aws_subnet.pub2.id, aws_subnet.pub3.id]
  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }
  tags = {
    Name = "devcluster"
  }
  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
  ]
}

resource "aws_iam_role" "node_group_role" {
  name = "eks-node-group"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group_role.name
}

##### ingress controller ########

data "http" "iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.7/docs/install/iam_policy.json"
}
##### oidc provideer
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.dev_cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "ingress" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates.0.sha1_fingerprint]
  url             = data.tls_certificate.cluster.url
  depends_on      = [aws_eks_cluster.dev_cluster]
}

data "aws_eks_cluster" "cluster" {
  name = aws_eks_cluster.dev_cluster.id
}

data "aws_iam_openid_connect_provider" "dev_cluster" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  depends_on = [
    aws_eks_cluster.dev_cluster,
    aws_iam_openid_connect_provider.ingress
  ]
}

data "aws_eks_cluster_auth" "cluster" {
  name = aws_eks_cluster.dev_cluster.id
}

data "aws_iam_policy_document" "alb_ingress_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["${data.aws_iam_openid_connect_provider.dev_cluster.arn}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.dev_cluster.identity[0].oidc[0].issuer, "https://", "")}:sub"

      values = [
        "system:serviceaccount:kube-system:${var.k8s_service_account_name}",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.dev_cluster.identity[0].oidc[0].issuer, "https://", "")}:aud"

      values = [
        "sts.amazonaws.com",
      ]
    }

    effect = "Allow"
  }
}

resource "aws_iam_policy" "alb_ingress" {
  name        = "${var.cluster_name}-alb-ingress"
  path        = "/"
  description = "Policy for alb-ingress service"

  policy = data.http.iam_policy.response_body
}

resource "aws_iam_role" "alb_ingress" {
  assume_role_policy = data.aws_iam_policy_document.alb_ingress_assume.json
  name               = "eks_oidc_role"
}

resource "aws_iam_role_policy_attachment" "alb_ingress" {
  role       = aws_iam_role.alb_ingress.name
  policy_arn = aws_iam_policy.alb_ingress.arn
}

resource "helm_release" "ingress" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.dev_cluster.name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = var.k8s_service_account_name
  }
}

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = var.k8s_service_account_name
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/name"      = var.k8s_service_account_name
    }

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_ingress.arn
    }
  }
}

data "aws_region" "current_region" {}

## add kube config file
resource "null_resource" "configure_kubeconfig" {
  depends_on = [aws_eks_cluster.dev_cluster]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${aws_eks_cluster.dev_cluster.name} --region ${data.aws_region.current_region.name}"
  }
}
