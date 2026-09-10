terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# デフォルト VPC を利用（最小構成のため）
data "aws_vpc" "default" {
  default = true
}

# 最新の Amazon Linux 2023 AMI を取得
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  # 標準(フル)の AL2023 AMI に限定。"al2023-ami-2023*" は minimal を除外できる
  # t4g 系は ARM(Graviton) のため arm64 の AMI を使用する
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Grafana(3000番ポート)への外部アクセスを許可するセキュリティグループ
resource "aws_security_group" "grafana" {
  name        = "grafana-sg"
  description = "Allow Grafana web access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Grafana web UI"
    from_port   = 3000
    to_port     = 3000
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
    Name = "grafana-sg"
  }
}

# 既存の SSM 用インスタンスプロファイルを参照
data "aws_iam_instance_profile" "ssm" {
  name = "AmazonSSMManagedInstanceCore"
}

resource "aws_instance" "grafana" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t4g.small"
  vpc_security_group_ids      = [aws_security_group.grafana.id]
  associate_public_ip_address = true
  iam_instance_profile        = data.aws_iam_instance_profile.ssm.name

  # Grafana をインストールして起動
  # 注意: <<-EOF はタブのインデントのみ除去しスペースは残るため、
  # shebang(#!) の前に空白が入り "Exec format error" になる。
  # そのため通常の <<EOF を使い、行頭は左詰めで記述する。
  user_data = <<EOF
#!/bin/bash
set -euxo pipefail

# SSM Agent が未インストールなら導入し、起動・自動起動を有効化（冪等）
if ! systemctl list-unit-files | grep -q '^amazon-ssm-agent\.service'; then
  dnf install -y amazon-ssm-agent
fi
systemctl enable --now amazon-ssm-agent

tee /etc/yum.repos.d/grafana.repo > /dev/null <<'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO

dnf install -y grafana

# 初期 admin パスワードを設定（初回ログイン時のパスワード変更要求を回避）
# 注意: 平文で user_data / tfstate に残るため学習用途のみ。本番では利用しない。
tee -a /etc/sysconfig/grafana-server > /dev/null <<'ENVV'
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=Handson0911!
ENVV

systemctl enable --now grafana-server
EOF

  tags = {
    Name = "grafana-instance"
  }
}

output "grafana_url" {
  description = "Grafana にアクセスする URL"
  value       = "http://${aws_instance.grafana.public_ip}:3000"
}
