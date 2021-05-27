provider "aws" {
  region = local.region
}

locals {
  region = "eu-west-2"
}

data "aws_route53_zone" "public" {
  name = "iacdemos.com."
}

data "http" "myip" {
  url = "http://ifconfig.co"
}

data "aws_ami" "ubuntu20-latest" {
  most_recent = true

  owners = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "ssh-pub" {
  key_name   = "nowills-popos"
  public_key = file("~/.ssh/id_rsa.pub")
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "ldms-demo"
  cidr = "192.168.120.0/22"

  azs              = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets  = ["192.168.120.0/27", "192.168.120.32/27", "192.168.120.64/27"]
  public_subnets   = ["192.168.121.0/27", "192.168.121.32/27", "192.168.121.64/27"]
  database_subnets = ["192.168.123.0/27", "192.168.123.32/27", "192.168.122.64/27"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = false
  single_nat_gateway   = true

  tags = {
    Owner       = "ColinW"
    Environment = "ldms-demo"
  }
}

module "sg-web" {
  source      = "terraform-aws-modules/security-group/aws"
  name        = "web-subnet-access"
  description = "Security group allowing access for SSH (my workstation IP) and HTTPS(open)"
  vpc_id      = module.vpc.vpc_id
  ingress_with_cidr_blocks = [
    {
      rule        = "https-443-tcp"
      cidr_blocks = "0.0.0.0/0"
    },
  ]
}

module "sg-bastion" {
  source      = "terraform-aws-modules/security-group/aws"
  name        = "private-subnet-access"
  description = "Security group allowing access for SSH to AWS jump server from workstation IP - replacing what would be a site to site VPN connection"
  vpc_id      = module.vpc.vpc_id
  ingress_with_cidr_blocks = [
    {
      rule        = "ssh-tcp"
      cidr_blocks = "${chomp(data.http.myip.body)}/32"
    },
  ]
}

module "sg-database" {
  source      = "terraform-aws-modules/security-group/aws"
  name        = "database-subnet-access"
  description = "Security group allowing access for mariadb from the pirvate subnet only"
  vpc_id      = module.vpc.vpc_id
  ingress_with_cidr_blocks = [
    {
      rule        = "mysql-tcp"
      cidr_blocks = join(",", module.vpc.private_subnets_cidr_blocks)
    },
  ]
}

module "ec2-web" {
  source         = "terraform-aws-modules/ec2-instance/aws"
  version        = "~> 2.0"
  name           = "web-servers"
  instance_count = 3

  ami                    = data.aws_ami.ubuntu20-latest.id
  instance_type          = "t2.micro"
  key_name               = "nowills-popos"
  monitoring             = true
  vpc_security_group_ids = [module.sg-web.security_group_id]
  subnet_ids             = module.vpc.public_subnets

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "ec2-bastion" {
  source         = "terraform-aws-modules/ec2-instance/aws"
  version        = "~> 2.0"
  name           = "bastion-server"
  instance_count = 1

  ami                    = data.aws_ami.ubuntu20-latest.id
  instance_type          = "t2.micro"
  key_name               = "nowills-popos"
  monitoring             = true
  vpc_security_group_ids = [module.sg-bastion.security_group_id]
  subnet_ids             = module.vpc.private_subnets

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 3.0"

  identifier = "ldms-demodb"

  engine            = "mariadb"
  engine_version    = "10.5.8"
  instance_class    = "db.t2.micro"
  allocated_storage = 5

  name     = "demo"
  username = "ldms"
  password = "Tes+0pts"
  port     = "3306"

  iam_database_authentication_enabled = false

  vpc_security_group_ids = [module.sg-database.security_group_id]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  monitoring_interval    = "30"
  monitoring_role_name   = "MyRDSMonitoringRole"
  family                 = "mariadb10.5"
  major_engine_version   = "10.5"
  create_monitoring_role = true

  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  subnet_ids          = module.vpc.database_subnets
  deletion_protection = false
}

module "elb" {
  source = "terraform-aws-modules/elb/aws"

  name = "elb-ldms-demo"

  subnets         = module.vpc.public_subnets
  security_groups = [module.sg-web.security_group_id]
  internal        = false

  listener = [
    {
      instance_port      = "8080"
      instance_protocol  = "https"
      lb_port            = "443"
      lb_protocol        = "https"
      ssl_certificate_id = module.acm.acm_certificate_arn
    },
    {
      instance_port     = "80"
      instance_protocol = "http"
      lb_port           = "80"
      lb_protocol       = "http"
    },
  ]

  health_check = {
    target              = "HTTP:8080/"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }

  #access_logs = {
  #  bucket = aws_s3_bucket.logs.id
  #}

  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  # ELB attachments
  #number_of_instances = var.number_of_instances
  instances = module.ec2-web.id
}

resource "aws_route53_record" "www-aws" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "aws.${data.aws_route53_zone.public.name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.elb.elb_dns_name]
}

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> v3.0"

  domain_name         = "iacdemos.com"
  zone_id             = data.aws_route53_zone.public.zone_id
  wait_for_validation = true
  subject_alternative_names = [
    "*.iacdemos.com",
  ]

  tags = {
    Name = "iacdemos.com"
  }
}

