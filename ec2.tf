# =============================================================================
# ec2-grafana.tf
#
# 目的:
#   新規 EC2 を1台作成し、その EC2 自身に
#     - node_exporter (ホストのCPU/メモリ等を 9100 番で公開)
#     - Prometheus    (localhost の node_exporter を 9090 番でスクレイプ)
#   を同居させる。
#   その上で、既存の Grafana (main.tf で起動済み) に対して
#     - Prometheus データソース
#     - この EC2 のCPU/メモリ使用率ダッシュボード
#   を Grafana provider 経由で新規作成する。
#
#   => `terraform apply` 一発で「新規EC2作成」と「Grafana専用ダッシュボード作成」
#      が同時に実行される。
#
# 接続経路 (パターンA):
#   Grafana サーバー(EC2) --(VPC内, proxy)--> 新規EC2:9090 (Prometheus)
#   データソース URL には新規EC2のプライベートIPを使用。
#   9090 は外部公開せず、送信元を Grafana の SG に限定する。
#
# 前提:
#   - main.tf は変更しない。
#   - Grafana は既に起動済み。URL = http://<grafana_public_ip>:3000
#     認証情報 = admin / Handson0911!
# =============================================================================

# -----------------------------------------------------------------------------
# Provider について
#   grafana provider の required_providers と provider 設定 (接続先/認証) は
#   main.tf 側に定義している。
#   理由: このファイルを .tf 以外にリネームして無効化した際、provider 設定まで
#   消えると state に残る grafana リソースを削除できず
#   "the Grafana client is required for this resource" エラーになるため。
# -----------------------------------------------------------------------------
# 監視対象となる新規 EC2 用セキュリティグループ
#   - 9090 (Prometheus): 送信元を Grafana の SG に限定 (VPC内 proxy アクセス用)
#   - node_exporter(9100) は localhost スクレイプのため外部開放不要
#   - 22 (SSH): デバッグ用にログインできるよう許可する
# -----------------------------------------------------------------------------
# 名前は VPC 内で一意である必要があるため var.owner を付与する。
resource "aws_security_group" "monitored_target" {
  name        = "monitored-target-sg-${var.owner}"
  description = "Allow Prometheus scrape from Grafana server within VPC"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Prometheus HTTP from Grafana server"
    from_port       = 9090
    to_port         = 9090
    protocol        = "tcp"
    security_groups = [aws_security_group.grafana.id]
  }

  # デバッグ用の SSH。全世界に開いているため、ハンズオン以外では
  # cidr_blocks を自分のIP (x.x.x.x/32) に絞ることを推奨。
  ingress {
    description = "SSH for debugging"
    from_port   = 22
    to_port     = 22
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
    Name  = "monitored-target-sg-${var.owner}"
    Owner = var.owner
  }
}

# -----------------------------------------------------------------------------
# 監視対象の新規 EC2
#   node_exporter + Prometheus を user_data でインストール・起動する。
#   AMI は main.tf の data ソースを再利用する。
#   IAM インスタンスプロファイルと SSH キーペアは既定では付与しない
#   (ハンズオン環境に該当ロールが無い / キーペア名が環境依存のため)。
#   必要な場合は下のコメントを外して使う。
#   (data.aws_ami.amazon_linux は arm64 AL2023 なので arm64 バイナリを使う)
# -----------------------------------------------------------------------------
resource "aws_instance" "monitored_target" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t4g.small"
  vpc_security_group_ids      = [aws_security_group.monitored_target.id]
  associate_public_ip_address = true

  # SSM を使う場合はコメントを外す (main.tf の data ブロックも合わせて有効化する)
  # iam_instance_profile = data.aws_iam_instance_profile.ssm.name

  # SSH でログインする場合はコメントを外し、既存のキーペア名を指定する
  # key_name = "your-key-pair-name"

  # 注意1: <<-EOF はタブのみ除去。shebang前に空白が入らないよう左詰めで記述。
  # 注意2: user_data 内で bash のシェル変数を使う箇所は、Terraform の補間
  #        (${...}) と衝突するため $${...} とエスケープしている。Terraform は
  #        $${ をリテラルの ${ に変換して EC2 へ渡す。このスクリプト内に
  #        Terraform 側の値注入は無い。
  user_data = <<EOF
#!/bin/bash
set -euxo pipefail

# --- 共通: アーキテクチャ判定 (t4g = arm64) -----------------------------------
ARCH=arm64

# --- node_exporter インストール -----------------------------------------------
NODE_EXPORTER_VERSION=1.8.2
useradd --no-create-home --shell /sbin/nologin node_exporter || true
cd /tmp
curl -fsSL -o node_exporter.tar.gz \
  "https://github.com/prometheus/node_exporter/releases/download/v$${NODE_EXPORTER_VERSION}/node_exporter-$${NODE_EXPORTER_VERSION}.linux-$${ARCH}.tar.gz"
tar xzf node_exporter.tar.gz
cp "node_exporter-$${NODE_EXPORTER_VERSION}.linux-$${ARCH}/node_exporter" /usr/local/bin/node_exporter
chown node_exporter:node_exporter /usr/local/bin/node_exporter

tee /etc/systemd/system/node_exporter.service > /dev/null <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
# localhost のみで待受 (外部公開しない)
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100

[Install]
WantedBy=multi-user.target
UNIT

# --- Prometheus インストール --------------------------------------------------
PROMETHEUS_VERSION=2.53.1
useradd --no-create-home --shell /sbin/nologin prometheus || true
mkdir -p /etc/prometheus /var/lib/prometheus
cd /tmp
curl -fsSL -o prometheus.tar.gz \
  "https://github.com/prometheus/prometheus/releases/download/v$${PROMETHEUS_VERSION}/prometheus-$${PROMETHEUS_VERSION}.linux-$${ARCH}.tar.gz"
tar xzf prometheus.tar.gz
cd "prometheus-$${PROMETHEUS_VERSION}.linux-$${ARCH}"
cp prometheus promtool /usr/local/bin/
cp -r consoles console_libraries /etc/prometheus/
chown -R prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool /etc/prometheus /var/lib/prometheus

# Prometheus 設定: localhost の node_exporter をスクレイプ
tee /etc/prometheus/prometheus.yml > /dev/null <<'PROMYML'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['127.0.0.1:9100']
PROMYML
chown prometheus:prometheus /etc/prometheus/prometheus.yml

tee /etc/systemd/system/prometheus.service > /dev/null <<'UNIT'
[Unit]
Description=Prometheus
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
# Grafana サーバー(VPC内)からの proxy アクセスを受けるため 0.0.0.0 で待受
# 外部公開はセキュリティグループ側で 9090 を Grafana SG に限定して防ぐ
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090

[Install]
WantedBy=multi-user.target
UNIT

# --- 起動 ---------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now node_exporter
systemctl enable --now prometheus
EOF

  tags = {
    Name  = "monitored-target-instance-${var.owner}"
    Owner = var.owner
  }
}

# -----------------------------------------------------------------------------
# Grafana: Prometheus データソース
#   URL は新規EC2のプライベートIP:9090 (VPC内 proxy アクセス)
#   Grafana サーバーがこの URL に到達する。
# -----------------------------------------------------------------------------
resource "grafana_data_source" "prometheus" {
  type = "prometheus"
  name = "prometheus-monitored-target"
  url  = "http://${aws_instance.monitored_target.private_ip}:9090"

  # Grafana サーバー経由でアクセス (パターンA)
  access_mode = "proxy"
  is_default  = false

  json_data_encoded = jsonencode({
    httpMethod = "POST"
  })

  # 依存を明示 (インスタンス起動 → Prometheus 起動まで多少ラグがあるが、
  # データソース登録自体は接続テストをしないため作成順序のみ担保する)
  depends_on = [aws_instance.monitored_target]
}

# -----------------------------------------------------------------------------
# Grafana: 専用ダッシュボード (CPU / メモリ使用率)
#   node_exporter のメトリクスから使用率を算出:
#     - CPU使用率  : 100 - (idle CPU の割合)
#     - メモリ使用率: (1 - MemAvailable / MemTotal) * 100
# -----------------------------------------------------------------------------
resource "grafana_dashboard" "monitored_target" {
  config_json = jsonencode({
    uid           = "monitored-target-metrics"
    title         = "Monitored Target - CPU / Memory"
    schemaVersion = 39
    version       = 1
    refresh       = "10s"
    time = {
      from = "now-1h"
      to   = "now"
    }
    templating  = { list = [] }
    annotations = { list = [] }
    panels = [
      {
        id      = 1
        type    = "timeseries"
        title   = "CPU使用率 (%)"
        gridPos = { h = 9, w = 12, x = 0, y = 0 }
        datasource = {
          type = "prometheus"
          uid  = grafana_data_source.prometheus.uid
        }
        fieldConfig = {
          defaults = {
            unit = "percent"
            min  = 0
            max  = 100
          }
          overrides = []
        }
        targets = [
          {
            refId        = "A"
            expr         = "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)"
            legendFormat = "CPU使用率"
          }
        ]
      },
      {
        id      = 2
        type    = "timeseries"
        title   = "メモリ使用率 (%)"
        gridPos = { h = 9, w = 12, x = 12, y = 0 }
        datasource = {
          type = "prometheus"
          uid  = grafana_data_source.prometheus.uid
        }
        fieldConfig = {
          defaults = {
            unit = "percent"
            min  = 0
            max  = 100
          }
          overrides = []
        }
        targets = [
          {
            refId        = "A"
            expr         = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100"
            legendFormat = "メモリ使用率"
          }
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# 出力
# -----------------------------------------------------------------------------
output "monitored_target_private_ip" {
  description = "監視対象EC2のプライベートIP (Prometheus:9090)"
  value       = aws_instance.monitored_target.private_ip
}

output "grafana_dashboard_url" {
  description = "作成した専用ダッシュボードのURL"
  value       = "http://${aws_instance.grafana.public_ip}:3000/d/${grafana_dashboard.monitored_target.uid}"
}
