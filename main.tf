terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}

# -----------------------------------------------------------------------------
# 変数
#   ハンズオンを同一 AWS アカウント / 同一デフォルトVPC で複数人が同時に実施する
#   ことを想定した識別子。
#   HCP Terraform を使う場合 state はワークスペースごとに分離されるが、AWS 側の
#   実体は共有されるため、名前が衝突するリソースには識別子を付けて分ける必要が
#   ある。特にセキュリティグループ名は VPC 内で一意でなければならず、未対応だと
#   2人目の apply が InvalidGroup.Duplicate で失敗する。
# -----------------------------------------------------------------------------
variable "owner" {
  description = <<-EOT
    リソース名・タグに付与する作業者識別子。
    同一アカウント/VPC で複数人が実施する際の名前衝突と、
    コンソール上での所有者判別のために使用する。
    HCP Terraform ではワークスペース変数として各自設定する。
    例: "tomochika"
  EOT
  type        = string

  # SG 名やタグに埋め込むため、AWS の命名で安全に使える文字種に限定する。
  # デフォルト値は意図的に設けない (全員が同じ値で走って衝突するのを防ぐため)。
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,29}$", var.owner))
    error_message = "owner は英小文字・数字・ハイフンのみ、1〜30文字、先頭は英数字にしてください。"
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
# 名前は VPC 内で一意である必要があるため var.owner を付与する。
resource "aws_security_group" "grafana" {
  name        = "grafana-sg-${var.owner}"
  description = "Allow Grafana web access"
  vpc_id      = data.aws_vpc.default.id

  # 3000 番は 0.0.0.0/0 で開ける必要がある。
  # 理由: HCP Terraform でリモート実行する場合、grafana provider の API 接続は
  # 手元のPCではなく HCP のランナーから発生するため、送信元IPを自分に絞ると
  # apply が到達不能で失敗する。
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
    Name  = "grafana-sg-${var.owner}"
    Owner = var.owner
  }
}

# 既存の SSM 用インスタンスプロファイルを参照。
# ハンズオン環境に AmazonSSMManagedInstanceCore が存在しない場合は解決に失敗するため
# 既定ではコメントアウトしている。存在する環境では以下と、各 aws_instance の
# iam_instance_profile 行のコメントを外すと SSM セッションマネージャが利用できる。
# data "aws_iam_instance_profile" "ssm" {
#   name = "AmazonSSMManagedInstanceCore"
# }

resource "aws_instance" "grafana" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t4g.small"
  vpc_security_group_ids      = [aws_security_group.grafana.id]
  associate_public_ip_address = true

  # SSM を使う場合はコメントを外す (上記 data ブロックも合わせて有効化する)
  # iam_instance_profile = data.aws_iam_instance_profile.ssm.name

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
    Name  = "grafana-instance-${var.owner}"
    Owner = var.owner
  }
}

# Grafana provider の接続設定。
# ec2-grafana.tf ではなく main.tf に置いている理由:
#   ec2-grafana.tf を .tf 以外にリネームして無効化したときに provider 設定まで
#   消えてしまうと、state に残った grafana リソース (データソース/ダッシュボード)
#   を削除できず "the Grafana client is required for this resource" となるため。
#   provider 設定を常に有効にしておくことで、リネームによる削除が正しく動く。
provider "grafana" {
  # 上で作成した Grafana インスタンスのパブリックIP:3000 を参照
  url = "http://${aws_instance.grafana.public_ip}:3000"
  # basic auth 形式 "username:password"
  auth = "admin:Handson0911!"

  # Grafana 起動直後は API 応答が不安定なことがあるためリトライを緩める
  retries    = 10
  retry_wait = 15
}

output "grafana_url" {
  description = "Grafana にアクセスする URL"
  value       = "http://${aws_instance.grafana.public_ip}:3000"
}
