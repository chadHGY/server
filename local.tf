terraform {
  required_version = "~> 0.12.25"
  backend "local" {}
}

provider "aws" {
  region = "us-west-2"
}

##########################################
# Variables
##########################################

variable "global_environment_name" {
  description = "A globally unique environment name for S3 buckets."
  type        = string
}

##########################################
# Data
##########################################

data "aws_region" "current" {
}

data "aws_availability_zones" "available" {
}

##########################################
# VPC resources
##########################################

resource "aws_vpc" "wandb" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    "Name" = "wandb"
    "kubernetes.io/cluster/wandb" = "shared"
  }
}

resource "aws_subnet" "wandb" {
  count = 2

  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = "10.10.${count.index}.0/24"
  vpc_id                  = aws_vpc.wandb.id
  map_public_ip_on_launch = true

  tags = {
    "Name" = "wandb-${count.index}"
    "kubernetes.io/cluster/wandb" = "shared"
  }
}

resource "aws_internet_gateway" "wandb" {
  vpc_id = aws_vpc.wandb.id

  tags = {
    Name = "wandb-gateway"
  }
}

resource "aws_route_table" "wandb" {
  vpc_id = aws_vpc.wandb.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.wandb.id
  }
}

resource "aws_route_table_association" "wandb_workers" {
  count = 2

  subnet_id      = aws_subnet.wandb[count.index].id
  route_table_id = aws_route_table.wandb.id
}

##########################################
# EKS resources
##########################################

resource "aws_security_group" "eks_master" {
  name        = "wandb-eks-master"
  description = "Cluster communication with worker nodes"
  vpc_id      = aws_vpc.wandb.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wandb-eks-master"
  }
}

resource "aws_eks_cluster" "wandb" {
  name     = "wandb"
  role_arn = aws_iam_role.wandb_cluster_role.arn
  version  = "1.15"

  vpc_config {
    security_group_ids = [aws_security_group.eks_master.id]
    subnet_ids         = aws_subnet.wandb.*.id
  }

  depends_on = [
    aws_iam_role_policy_attachment.wandb_eks_cluster_policy,
    aws_iam_role_policy_attachment.wandb_eks_service_policy,
  ]
}

resource "aws_security_group_rule" "eks_worker_ingress" {
  description              = "Allow comntainer NodePort service to receive load balancer traffic"
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.wandb.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.wandb_alb.id
  from_port                = 32543
  to_port                  = 32543
  type                     = "ingress"
}

resource "aws_iam_role" "wandb_cluster_role" {
  name = "wandb-cluster-role"

  assume_role_policy = <<POLICY
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
POLICY
}

resource "aws_iam_role_policy_attachment" "wandb_eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.wandb_cluster_role.name
}

resource "aws_iam_role_policy_attachment" "wandb_eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.wandb_cluster_role.name
}

data "aws_iam_policy_document" "wandb_node_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "wandb_node_role" {
  name               = "wandb-eks-node"
  assume_role_policy = data.aws_iam_policy_document.wandb_node_policy.json
}

resource "aws_iam_role_policy_attachment" "wandb_node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.wandb_node_role.name
}

resource "aws_iam_role_policy_attachment" "wandb_node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.wandb_node_role.name
}

resource "aws_iam_role_policy_attachment" "wandb_node_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.wandb_node_role.name
}

resource "aws_iam_role_policy_attachment" "wandb_node_s3_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.wandb_node_role.name
}

resource "aws_iam_role_policy_attachment" "wandb_node_sqs_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
  role       = aws_iam_role.wandb_node_role.name
}

resource "aws_eks_node_group" "eks_worker_node_group" {
  cluster_name    = aws_eks_cluster.wandb.name
  node_group_name = "wandb-node-group"
  node_role_arn   = aws_iam_role.wandb_node_role.arn
  subnet_ids      = aws_subnet.wandb[*].id

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  instance_types = ["m5.xlarge"]

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.wandb_node_worker_policy,
    aws_iam_role_policy_attachment.wandb_node_cni_policy,
    aws_iam_role_policy_attachment.wandb_node_registry_policy,
  ]
}

##########################################
# Load Balancing
##########################################

resource "aws_security_group" "wandb_alb" {
  name        = "wandb-alb-sg"
  description = "Allow http(s) traffic to wandb"
  vpc_id      = aws_vpc.wandb.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wandb-alb"
  }
}

resource "aws_lb" "wandb" {
  name               = "wandb-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.wandb_alb.id]
  subnets            = aws_subnet.wandb.*.id
}

output "lb_address" {
  value = "http://${aws_lb.wandb.dns_name}"
}

resource "aws_lb_target_group" "wandb_tg" {
  name     = "wandb-alb-tg"
  port     = 32543
  protocol = "HTTP"
  vpc_id   = aws_vpc.wandb.id

  health_check {
    protocol            = "HTTP"
    path                = "/healthz"
    port                = "traffic-port"
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "wandb_listener" {
  load_balancer_arn = aws_lb.wandb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wandb_tg.arn
  }
}

resource "aws_autoscaling_attachment" "wandb" {
  autoscaling_group_name = aws_eks_node_group.eks_worker_node_group.resources[0].autoscaling_groups[0].name
  alb_target_group_arn   = aws_lb_target_group.wandb_tg.arn
}

##########################################
# SQS/SNS
##########################################

resource "aws_sqs_queue" "file_metadata" {
  name = "wandb-file-metadata"

  # enable long-polling
  receive_wait_time_seconds = 10
}

resource "aws_sqs_queue_policy" "file_metadata_queue_policy" {
  queue_url = aws_sqs_queue.file_metadata.id

  policy = data.aws_iam_policy_document.file_metadata_queue_policy.json
}

data "aws_iam_policy_document" "file_metadata_queue_policy" {
  statement {
    actions   = ["SQS:SendMessage"]
    effect    = "Allow"
    resources = [aws_sqs_queue.file_metadata.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.file_metadata.arn]
    }
  }
}

resource "aws_sns_topic" "file_metadata" {
  name = "wandb-file-metadata-topic"
}

resource "aws_sns_topic_policy" "file_metadata_topic_policy" {
  arn = aws_sns_topic.file_metadata.arn

  policy = data.aws_iam_policy_document.file_metadata_topic_policy.json
}

data "aws_iam_policy_document" "file_metadata_topic_policy" {
  statement {
    sid       = "s3-can-publish"
    actions   = ["SNS:Publish"]
    effect    = "Allow"
    resources = [aws_sns_topic.file_metadata.arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.file_storage.arn]
    }
  }
}

resource "aws_sns_topic_subscription" "file_metadata" {
  topic_arn = aws_sns_topic.file_metadata.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.file_metadata.arn
}

##########################################
# S3
##########################################

resource "aws_s3_bucket" "file_storage" {
  bucket        = "${var.global_environment_name}-wandb-files"
  acl           = "private"
  force_destroy = true

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }

  server_side_encryption_configuration {
    rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "AES256"
        }
    }
  }
}

resource "aws_s3_bucket_notification" "file_metadata_sns" {
  bucket = aws_s3_bucket.file_storage.id

  topic {
    topic_arn = aws_sns_topic.file_metadata.arn
    events    = ["s3:ObjectCreated:*"]
  }
}

##########################################
# RDS
##########################################

resource "aws_db_subnet_group" "metadata_subnets" {
  name       = "wandb-db-subnets"
  subnet_ids = aws_subnet.wandb.*.id
}

resource "aws_rds_cluster" "metadata_cluster" {
  engine               = "aurora-mysql"
  db_subnet_group_name = aws_db_subnet_group.metadata_subnets.name

  skip_final_snapshot     = true
  backup_retention_period = 14

  enabled_cloudwatch_logs_exports = [
    "error",
  ]
  iam_database_authentication_enabled = true

  database_name   = "wandb_local"
  master_username = "wandb"
  master_password = "wandb_root_password"

  vpc_security_group_ids = [aws_security_group.metadata_store.id]

  storage_encrypted = true
}

resource "aws_rds_cluster_instance" "metadata_store" {
  identifier           = "wandb-metadata"
  engine               = "aurora-mysql"
  cluster_identifier   = aws_rds_cluster.metadata_cluster.id
  instance_class       = "db.r5.large"
  db_subnet_group_name = aws_db_subnet_group.metadata_subnets.name
}

resource "aws_security_group" "metadata_store" {
  name        = "wandb-metadata-store"
  description = "Allow inbound traffic from workers to metadata store"
  vpc_id      = aws_vpc.wandb.id

  tags = {
    Name = "wandb-metadata-store"
  }
}

resource "aws_security_group_rule" "metadata_ingress_eks_workers" {
  description              = "Allow inbound traffic from EKS workers to metadata store"
  from_port                = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.metadata_store.id
  source_security_group_id = aws_eks_cluster.wandb.vpc_config[0].cluster_security_group_id
  to_port                  = 3306
  type                     = "ingress"
}

##########################################
# Output files
##########################################

resource "local_file" "kubeconfig" {
  filename = "kubeconfig.yaml"
  content = <<KUBECONFIG
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: ${aws_eks_cluster.wandb.endpoint}
        certificate-authority-data: ${aws_eks_cluster.wandb.certificate_authority[0].data}
      name: kubernetes
    contexts:
    - context:
        cluster: kubernetes
        user: aws
      name: aws
    current-context: aws
    preferences: {}
    users:
    - name: aws
      user:
        exec:
          apiVersion: client.authentication.k8s.io/v1alpha1
          command: aws-iam-authenticator
          args:
            - "token"
            - "-i"
            - "wandb"
KUBECONFIG
}

resource "local_file" "wandb_kube" {
  filename = "wandb.yaml"
  content = <<KUBE
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wandb
  labels:
    app: wandb
spec:
  strategy:
    type: RollingUpdate
  replicas: 1
  selector:
    matchLabels:
      app: wandb
  template:
    metadata:
      labels:
        app: wandb
    spec:
      containers:
        - name: wandb
          env:
            - name: BUCKET
              value: s3:///${aws_s3_bucket.file_storage.bucket}
            - name: BUCKET_QUEUE
              value: sqs://${aws_sqs_queue.file_metadata.name}
            - name: AWS_REGION
              value: ${aws_s3_bucket.file_storage.region}
            - name: MYSQL
              value: mysql://wandb:wandb_root_password@${aws_rds_cluster_instance.metadata_store.endpoint}/wandb_local
          imagePullPolicy: Always
          image: wandb/local:latest
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
          readinessProbe:
            httpGet:
              path: /ready
              port: http
          resources:
            requests:
              cpu: "1500m"
              memory: 4G
            limits:
              cpu: "4000m"
              memory: 8G
---
apiVersion: v1
kind: Service
metadata:
  name: wandb-service
spec:
  type: NodePort
  selector:
    app: wandb
  ports:
    - port: 8080
      nodePort: 32543
KUBE
}
