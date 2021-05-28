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
  owners      = ["099720109477"]
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
  key_name   = "workstation-key"
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
      rule        = "http-80-tcp"
      cidr_blocks = join(",", module.vpc.public_subnets_cidr_blocks)
    },
    {
      rule        = "http-80-tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      rule        = "https-443-tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      rule        = "ssh-tcp"
      cidr_blocks = "${chomp(data.http.myip.body)}/32"
    },
  ]
  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    },
  ]
}

module "sg-private" {
  source      = "terraform-aws-modules/security-group/aws"
  name        = "private-subnet-access"
  description = "Security group allowing access for SSH adn Mysql from web subnet"
  vpc_id      = module.vpc.vpc_id
  ingress_with_cidr_blocks = [
    {
      rule        = "ssh-tcp"
      cidr_blocks = join(",", module.vpc.public_subnets_cidr_blocks)
    },
    {
      rule        = "mysql-tcp"
      cidr_blocks = join(",", module.vpc.private_subnets_cidr_blocks)
    },
    {
      rule        = "mysql-tcp"
      cidr_blocks = join(",", module.vpc.public_subnets_cidr_blocks)
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
    {
      rule        = "mysql-tcp"
      cidr_blocks = join(",", module.vpc.public_subnets_cidr_blocks)
    },
  ]
}

module "ec2-web" {
  source         = "terraform-aws-modules/ec2-instance/aws"
  version        = "~> 2.0"
  name           = "web-servers"
  instance_count = var.no_of_webinstance

  ami                    = data.aws_ami.ubuntu20-latest.id
  instance_type          = "t2.small"
  key_name               = "workstation-key"
  monitoring             = true
  vpc_security_group_ids = [module.sg-web.security_group_id]
  subnet_ids             = module.vpc.public_subnets

  tags = {
    Terraform   = "true"
    Environment = "web"
  }
}

module "ec2-private" {
  source         = "terraform-aws-modules/ec2-instance/aws"
  version        = "~> 2.0"
  name           = "secret-servers"
  instance_count = 3

  ami                    = data.aws_ami.ubuntu20-latest.id
  instance_type          = "t2.micro"
  key_name               = "workstation-key"
  monitoring             = true
  vpc_security_group_ids = [module.sg-private.security_group_id]
  subnet_ids             = module.vpc.private_subnets

  tags = {
    Terraform   = "true"
    Environment = "private"
  }
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 3.0"

  identifier = "ldms-demodb"

  engine            = "mysql"
  engine_version    = "8.0.20"
  instance_class    = "db.t2.small"
  allocated_storage = 5

  publicly_accessible                 = false
  name                                = "cpx000db"
  username                            = "rack"
  password                            = var.db-password
  port                                = "3306"
  multi_az                            = true
  storage_encrypted                   = true
  iam_database_authentication_enabled = false

  vpc_security_group_ids = [module.sg-database.security_group_id]

  maintenance_window      = "Mon:00:00-Mon:03:00"
  backup_window           = "03:00-06:00"
  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  monitoring_interval    = "30"
  monitoring_role_name   = "MyRDSMonitoringRole"
  family                 = "mysql8.0"
  major_engine_version   = "8.0"
  create_monitoring_role = true

  tags = {
    Owner       = "user"
    Environment = "dev"
  }

  subnet_ids = module.vpc.database_subnets
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "my-alb"

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [module.sg-web.security_group_id]

  #  access_logs = {
  #    bucket = "my-alb-logs"
  #  }

  target_groups = [
    {
      name_prefix      = "pref-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      targets = [
        {
          target_id = module.ec2-web.id[0]
          port      = 80
        },
        {
          target_id = module.ec2-web.id[1]
          port      = 80
        },
        {
          target_id = module.ec2-web.id[2]
          port      = 80
        },
      ]
      stickiness = {
        enabled = true
        type    = "lb_cookie"
      }
    }
  ]
  https_listeners = [
    {
      port               = 443
      protocol           = "HTTPS"
      certificate_arn    = module.acm.acm_certificate_arn
      target_group_index = 0
    }
  ]

  http_tcp_listeners = [
    {
      port        = 80
      protocol    = "HTTP"
      action_type = "redirect"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  ]

  tags = {
    Environment = "Test"
  }
}

resource "aws_route53_record" "www-aws" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "aws.${data.aws_route53_zone.public.name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.alb.lb_dns_name]
}

resource "aws_route53_record" "rds-aws" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "rds.${data.aws_route53_zone.public.name}"
  type    = "CNAME"
  ttl     = 300
  records = [module.db.db_instance_address]
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


output "web-app-dns" {
  value = aws_route53_record.www-aws.fqdn
}
output "rds-db-dns" {
  value = aws_route53_record.rds-aws.fqdn
}
output "rds-db-name" {
  value = module.db.db_instance_address
}
