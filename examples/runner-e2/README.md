# Terraform を使って Auto Scaling を利用した GitLab Runner リソースを作成する

GitLab Runner に必要な以下のリソースを Terraform で作成する。

- Auto Scaling Group（GitLab Runner の実行用）
- Launch Template（GitLab Runner の実行用．GitLab Runner のインストールスクリプトや設定ファイルが含まれる）
- S3 Bucket（ビルドキャッシュ用）
- CloudWatch Logs（EC2 インスタンスのログ）
- Lambda （EC2 インスタンスを終了させる）
- 上記で必要な VPC, Security Group や IAM Role, Policy など

## Terraform で作成した場合の不都合

`terraform apply` を実行後、以下の不都合があったため対応する必要があった。

1. GitLab に Runnner が登録できていない
2. 既存のEIPを設定できない（IP 制限かけてる環境にデプロイできない）
3. アウトバウンドルールが限定されている（22, 443, 80のみ）

以下で対応

1. `gitlab-runner register` を実行する
    1. Terraform で作成された config.toml の設定を、新たに作成された設定にマージする
2. 既存の EIP を使用する NatGateway を作成しルートに設定する
    1. Terraform で作成された NatGateway, EIP は費用がかかるので削除する
3. セキュリティグループのアウトバウンドルールに 6301, 5002 を追加する
    - 6301: E2 の SSH ポート
    - 5002: GitLab のレジストリにから Docker イメージをプルするためのポート

## 実行するための前提条件

- [aws cli](https://aws.amazon.com/jp/cli/) で`aws-org`アカウントから`e2_awsdevelop`アカウントにスイッチロールできること
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli?in=terraform/aws-get-started) がインストールされていること
- ~~[tfenv](https://github.com/tfutils/tfenv) がインストールされていること~~ 今回は不使用
  - ~~terraformの実行には、Terraform のバージョンを指定する必要があるため~~
- [jq](https://stedolan.github.io/jq/) がインストールされていること
  - `terraform destroy`実行時に必要
- [aws-vault](https://github.com/99designs/aws-vault) がインストールされていること
  - スイッチロールやMFAを設定しているアカウントで実行する場合は、aws-vault を使うと楽

### aws cli の設定

`aws-org`アカウントから`e2_awsdevelop`にスイッチロールできるよう設定する。

各アカウントを以下に読み替えて、各ファイルを設定。

- aws-org -> e2-org
- e2_awsdevelop -> e2-dev

~/.aws/credentials

```ini
[e2-org]
aws_access_key_id = アクセスキー
aws_secret_access_key = シークレットアクセスキー
```

~/.aws/config

```ini
[profile e2-org]
region = ap-northeast-1
output = json

[profile e2-dev]
region = ap-northeast-1
output = json
role_arn = arn:aws:iam::977310042706:role/OrganizationAccountAccessRole
source_profile = e2-org
```

スイッチロールの確認

```shell
aws --profile e2-dev sts get-caller-identity 
```

以下が表示されれれば OK。

```shell
{
    "UserId": "XXXXXXXXXXXXXXXXXXXXX:botocore-session-XXXXXXXXXX",
    "Account": "977310042706",
    "Arn": "arn:aws:sts::977310042706:assumed-role/OrganizationAccountAccessRole/botocore-session-XXXXXXXXXX"
}
```

### aws-vault の設定

e2-org の資格情報を登録する。

```shell
aws-vault add e2-org
```

以下参照

- [\[Terraform CLI\]MFA認証を使ったAssumeRole。AWSVaultで解決 | DevelopersIO](https://dev.classmethod.jp/articles/terraform-assumerole/)

## 構築手順

### 前提

- v9.2.3 の examples/runner-default をコピーして作成した。
- tfenvは使用せず、以下のバージョンのterraformを使用した。

```bash
% terraform --version 
Terraform v1.5.7
```

### 0. レジストレーション・トークンの設定

1. <https://gitlab.e-2.jp/admin/runners> でレジストレーション・トークン (registration token) を控えておく。
1. 控えておいたトークンを `/gitlab/runner/token` と言う名前で SSM パラメータストアの保存する。
    - 以下のコマンドを CloudShell 経由で実行する。

```shell
aws ssm put-parameter \
  --name "/gitlab/runner/token" \
  --type "SecureString" \
  --value "レジストレーション・トークン" \
  --description "GitLab Runner registration token"
```

### 1 .初期化

初めて実行する場合は、以下を実行する。

```shell
terraform init
```

### 2. plan して apply

plan

```shell
aws-vault exec e2-dev -- terraform plan
```

apply

```shell
aws-vault exec e2-dev -- terraform apply
```

### 3. GitLab Runner の登録

1. SSM で作成された EC2 インスタンスにログインして root になる。
2. 設定ファイルのバックアップをする。

```shell
cp -p /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.toml.org
```

3. GitLab Runner に登録する。

```shell
gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.e-2.jp/" \
  --registration-token "レジストレーション・トークン" \
  --executor "docker+machine" \
  --docker-image "alpine:latest" \
  --description "e2-docker-gitlab-runner" \
  --tag-list "aws,docker" \
  --run-untagged="true" \
  --locked="false"
```

4. 再度バックアップをする。

```shell
cp -p /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.toml.regist
```

5. Terraform で設定された部分を、GitLab Runner 登録時に作成された部分にマージする。

```shell
 vim /etc/gitlab-runner/config.toml
```

6. 無効な runner の設定を削除する。

```shell
gitlab-runner verify --delete
```

7. runner 再起動

```shell
gitlab-runner restart
```

<details>
<summary>最終的な config.toml</summary>

```toml
concurrent = 5
check_interval = 3
log_format = "json"
sentry_dsn = ""
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "e2-docker-gitlab-runner"
  url = "https://gitlab.e-2.jp/"
  id = 57
  token = "wbpAg-rVysQQxZ9ysi25"
  token_obtained_at = 2025-08-19T13:46:33Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = "docker+machine"
  [runners.cache]
    Type = "s3"
    MaxUploadedArchiveSize = 0
    [runners.cache.s3]
      ServerAddress = "s3.amazonaws.com"
      BucketName = "gitlab-runner-977310042706-gitlab-runner-cache"
      BucketLocation = "ap-northeast-1"
      AuthenticationType = "iam"
  [runners.docker]
    tls_verify = false
    image = "docker:18.03.1-ce"
    privileged = false
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/cache", "/certs/client"]
    pull_policy = ["always"]
    shm_size = 0
    [runners.docker.tmpfs]
      "/var/opt/cache" = "rw,noexec"
    [runners.docker.services_tmpfs]
      "/var/lib/mysql" = "rw,noexec"
  [runners.machine]
    IdleCount = 0
    IdleScaleFactor = 0.0
    IdleCountMin = 0
    IdleTime = 600
    MachineDriver = "amazonec2"
    MachineName = "gitlab-runner-%s"
    MachineOptions = [
      "amazonec2-instance-type=t3.medium", 
      "amazonec2-region=ap-northeast-1", 
      "amazonec2-zone=a", 
      "amazonec2-vpc-id=vpc-04f06e4c7bd29ee38", 
      "amazonec2-subnet-id=subnet-061b5b74b360835e4", 
      "amazonec2-private-address-only=true", 
      "amazonec2-use-private-address=false", 
      "amazonec2-request-spot-instance=true", 
      "amazonec2-security-group=gitlab-runner-docker-machine20250819131142905300000004", 
      "amazonec2-tags=Environment,gitlab-runner,tf-aws-gitlab-runner:example,runner-default,tf-aws-gitlab-runner:instancelifecycle,spot:yes,gitlab-runner-parent-id,i-0804bb93ea1f2bfff", 
      "amazonec2-use-ebs-optimized-instance=true", 
      "amazonec2-monitoring=false", 
      "amazonec2-iam-instance-profile=gitlab-runner-docker-machine", 
      "amazonec2-root-size=8", "amazonec2-volume-type=gp3", 
      "amazonec2-userdata=", 
      "amazonec2-ami=ami-02dc59944bc69e802", 
      "amazonec2-metadata-token=required", 
      "amazonec2-metadata-token-response-hop-limit=2"
      ]

    [[runners.machine.autoscaling]]
      Periods = ["* * 9-21 * * mon-fri *"]
      Timezone = "Asia/Tokyo"
      IdleCount = 2
      IdleScaleFactor = 0.0
      IdleCountMin = 1
      IdleTime = 600

    [[runners.machine.autoscaling]]
      Periods = ["* * 0-9,21-23 * * mon-fri *", "* * * * * sat,sun *"]
      Timezone = "Asia/Tokyo"
      IdleCount = 0
      IdleScaleFactor = 0.0
      IdleCountMin = 0
      IdleTime = 300
```

</details>

### 4. NatGateway の作成

1. 新たに NatGateway を作成し、元々使用していた EIP(gitlab-runner-nat-gateway-eip) を設定する。
    - 以下、CloudShell で実行する。

```shell
ALLOCATION_ID=NatGatewayに設定するEIPのID
SUBNET_ID=Terraform が作成したパブリックなサブネットのID

aws ec2 create-nat-gateway \
  --subnet-id "${SUBNET_ID}" \
  --allocation-id "${ALLOCATION_ID}" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=e2-gitlab-runner-nat-gateway}]'
```

1. Terraform で作成した NatGateway が使用していたサブネットのルートテーブルのルートの 0.0.0.0/0 の送信先を新たに作成した NatGateway に変更する。
1. Terraform で作成した NatGateway, EIP は費用がかかるので削除する。

### 4. セキュリティグループの設定

1. 以下のポートをセキュリティグループ gitlab-runner のアウトバウンドルールに IP4, IP6 それぞれ設定する。
    - 6301
    - 5002

## おまけ

ログの確認方法

```shell
journalctl -f /usr/bin/gitlab-runner
```

## 本家の追従

<https://github.com/npalm/terraform-aws-gitlab-runner> を`upstream`に設定する。

```shell
git remote add upstream git@github.com:npalm/terraform-aws-gitlab-runner.git
```

本家の変更を取り込む。

```shell
git fetch upstream
git checkout main
git merge upstream/main
```

# Example - Spot Runner - Default

In this scenario the runner agent is running on a single EC2 node and runners are created by [docker machine](https://docs.gitlab.com/runner/configuration/autoscale.html)
using spot instances. Runners will scale automatically based on configuration. The module creates by default a S3 cache
that is shared cross runners (spot instances).

This examples shows:

- Usages of public / private VPC
- You can log into the instance via SSM (Session Manager).
- Registration via GitLab token.
- Auto scaling using `docker+machine` executor.
- Additional security groups that are allowed access to the runner agent
- Use of `runners.docker.services` to configure docker registry mirror (commented out - uncomment to apply)

Multi region deployment is, of course, possible. Just instantiate the module multiple times with different AWS providers. In case
you use the cache, make sure to have one cache per region.

![runners-default](https://github.com/cattle-ops/terraform-aws-gitlab-runner/raw/main/assets/images/runner-default.png)

## Prerequisite

The Terraform version is managed using [tfenv](https://github.com/Zordrak/tfenv). If you are not using `tfenv` please
check `.terraform-version` for the tested version.

<!-- markdownlint-disable -->
<!-- cSpell:disable -->
<!-- markdown-link-check-disable -->

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.78.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | >= 2.5.2 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >= 3.2.3 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6.3 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | >= 4.0.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.78.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_runner"></a> [runner](#module\_runner) | ../../ | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | >= 5.16.0 |
| <a name="module_vpc_endpoints"></a> [vpc\_endpoints](#module\_vpc\_endpoints) | terraform-aws-modules/vpc/aws//modules/vpc-endpoints | >= 5.16.0 |

## Resources

| Name | Type |
|------|------|
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_security_group.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/security_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region. | `string` | `"eu-west-1"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | A name that identifies the environment, will used as prefix and for tagging. | `string` | `"runners-default"` | no |
| <a name="input_gitlab_url"></a> [gitlab\_url](#input\_gitlab\_url) | URL of the gitlab instance to connect to. | `string` | `"https://gitlab.com"` | no |
| <a name="input_preregistered_runner_token_ssm_parameter_name"></a> [preregistered\_runner\_token\_ssm\_parameter\_name](#input\_preregistered\_runner\_token\_ssm\_parameter\_name) | The name of the SSM parameter to read the preregistered GitLab Runner token from. | `string` | n/a | yes |
| <a name="input_runner_name"></a> [runner\_name](#input\_runner\_name) | Name of the runner, will be used in the runner config.toml | `string` | `"default-auto"` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | Name of the timezone that the runner will be used in. | `string` | `"Europe/Amsterdam"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
