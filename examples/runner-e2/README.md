# Terraform を使って Auto Scaling を利用した GitLab Runner リソース作成

https://github.com/npalm/terraform-aws-gitlab-runner を利用して、GitLab Runner に必要な以下のリソースを設定する。

- Auto Scaling Group（GitLab Runner の実行用）
- Launch Template（GitLab Runner の実行用．GitLab Runner のインストールスクリプトや設定ファイルが含まれる）
- S3 Bucket（ビルドキャッシュ用）
- CloudWatch Logs（EC2 インスタンスのログ）
- Lambda （EC2 インスタンスを終了させる）
- 上記で必要な VPC, Security Group や IAM Role, Policy など

## 実行するための前提条件

- [aws cli](https://aws.amazon.com/jp/cli/) で`aws-org`アカウントから`e2_awsdevelop`アカウントにスイッチロールできること
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli?in=terraform/aws-get-started) がインストールされていること
- [tfenv](https://github.com/tfutils/tfenv) がインストールされていること
    - `terraform-aws-gitlab-runner`の実行には、Terraform のバージョンを指定する必要があるため
- [jq](https://stedolan.github.io/jq/) がインストールされていること
    - `terraform destroy`実行時に必要
- [aws-vault](https://github.com/99designs/aws-vault) がインストールされていること
    - スイッチロールやMFAを設定しているアカウントで実行する場合は、aws-vault を使って実行する必要があります。

### aws cli の設定

`aws-org`アカウントから`e2_awsdevelop`にスイッチロールする。

各アカウントを以下に読み替えて、各ファイルを設定。
- aws-org -> e2-org
- e2_awsdevelop -> e2-dev

~/.aws/credentials 
```
[e2-org]
aws_access_key_id = アクセスキー
aws_secret_access_key = シークレットアクセスキー
```

~/.aws/config

```
[profile e2-org]
region = ap-northeast-1
output = json

[profile e2-dev]
region = ap-northeast-1
output = json
role_arn = arn:aws:iam::977310042706:role/OrganizationAccountAccessRole
source_profile = e2-org
```

スイッチロール確認
```
$  aws --profile e2-dev sts get-caller-identity 
```

以下が表示されれれば OK。
```
{
    "UserId": "XXXXXXXXXXXXXXXXXXXXX:botocore-session-XXXXXXXXXX",
    "Account": "977310042706",
    "Arn": "arn:aws:sts::977310042706:assumed-role/OrganizationAccountAccessRole/botocore-session-XXXXXXXXXX"
}
```

実行時に使用する AWS のプロファイルは、`variables.tf` で設定。

上書きする場合は、`terraform.tfvars` とういうファイルを作成し、以下を設定する。

```
aws_profile = "プロファイル名"
```

### tfenv の設定

tfenv インストール後、.terraform-version に書かれたバージョンをインストールする。

```
$ tfenv install 1.3.0
```

このディレクトリ内で以下のコマンドを実行し、上記でインストールしたバージョンが表示されれば OK。

```
$ terraform version
```

### aws-vault の設定

e2-org の資格情報を登録する。
```
$ aws-vault add e2-org
```

以下参照
- [\[Terraform CLI\]MFA認証を使ったAssumeRole。AWSVaultで解決 | DevelopersIO](https://dev.classmethod.jp/articles/terraform-assumerole/)

## 設定を反映する

あらかじめ https://gitlab.e-2.jp/admin/runners ページでレジストレーション・トークン (registration token) を確認しておく。

基本は、 init -> plan -> apply


### 0 .初期化、プラグインの設定

初めて実行する場合は、以下を実行する。
```
$ terraform init
```

### 1. 設定、変更内容の確認

```
$ aws-vault exec e2-dev -- terraform plan
var.registration_token
  Enter a value: 
レジストレーション・トークンを入力
``````

### 2. 設定、変更の実行

```
$ aws-vault exec e2-dev -- terraform apply
var.registration_token
  Enter a value: 
レジストレーション・トークンを入力

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: 
yes と入力
``````

### 3. NatGateway の作成

以下、NatGateway を新たに作成する。  
[Runner について](https://redmine.e-2.jp/projects/e2lan/wiki/Gitlab_CICD_%E3%81%A7%E3%83%87%E3%83%97%E3%83%AD%E3%82%A4#Runner-%E3%81%AB%E3%81%A4%E3%81%84%E3%81%A6) を参照。

* 名前： gitlab-runner-nat-gateway
* サブネット：Terraform で作成された NatGateway と同じサブネットを指定
* 接続タイプ：パブリック
* Elastib IP 割り当て ID：gitlab-runner-nat-gateway-eip

作成できたら、費用がかかるので Terraform で作成された NatGateway と EIP は削除しておく。

## 確認と破棄

### 現在の状態の確認

```
$ aws-vault exec e2-dev -- terraform show
``````

### 設定の破棄の確認

```
$ aws-vault exec e2-dev -- terraform plan -destroy
var.registration_token
  Enter a value: 
レジストレーション・トークンを入力
``````

### 設定の破棄

破棄の前に、作成した NatGateway は削除しておく。
（EIP は次回設定時に使用すうるので削除しない）

```
$ aws-vault exec e2-dev -- terraform destroy
var.registration_token
  Enter a value: 
レジストレーション・トークンを入力

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: 
yes と入力
``````


## 本家の追従

https://github.com/npalm/terraform-aws-gitlab-runner を`upstream`に設定する。

```
$ git remote add upstream git@github.com:npalm/terraform-aws-gitlab-runner.git
```

本家の変更を取り込む。

```
$ git fetch upstream
$ git checkout develop
$ git merge upstream/develop
```

## 参考

- [Configuring GitLab Runner | GitLab](https://docs.gitlab.com/runner/configuration/)
- [Runners autoscale configuration | GitLab](https://docs.gitlab.com/runner/configuration/autoscale.html)
- [npalm/terraform-aws-gitlab-runner: Terraform module for AWS GitLab runners on ec2 (spot) instances](https://github.com/npalm/terraform-aws-gitlab-runner)
- [npalm/gitlab-runner/aws | Terraform Registry](https://registry.terraform.io/modules/npalm/gitlab-runner/aws/latest)
- [Terraform Moduleを用いたAWSにおけるGitLab Runnerの運用 - GeekFactory](https://int128.hatenablog.com/entry/2019/06/20/185319)


---


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
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | 5.44.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | 2.5.1 |
| <a name="requirement_null"></a> [null](#requirement\_null) | 3.2.2 |
| <a name="requirement_random"></a> [random](#requirement\_random) | 3.6.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | 4.0.5 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.44.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_runner"></a> [runner](#module\_runner) | ../../ | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | 5.7.1 |
| <a name="module_vpc_endpoints"></a> [vpc\_endpoints](#module\_vpc\_endpoints) | terraform-aws-modules/vpc/aws//modules/vpc-endpoints | 5.7.1 |

## Resources

| Name | Type |
|------|------|
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/5.44.0/docs/data-sources/availability_zones) | data source |
| [aws_security_group.default](https://registry.terraform.io/providers/hashicorp/aws/5.44.0/docs/data-sources/security_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region. | `string` | `"eu-west-1"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | A name that identifies the environment, will used as prefix and for tagging. | `string` | `"runners-default"` | no |
| <a name="input_gitlab_url"></a> [gitlab\_url](#input\_gitlab\_url) | URL of the gitlab instance to connect to. | `string` | `"https://gitlab.com"` | no |
| <a name="input_registration_token"></a> [registration\_token](#input\_registration\_token) | Registration token for the runner. | `string` | n/a | yes |
| <a name="input_runner_name"></a> [runner\_name](#input\_runner\_name) | Name of the runner, will be used in the runner config.toml | `string` | `"default-auto"` | no |
| <a name="input_timezone"></a> [timezone](#input\_timezone) | Name of the timezone that the runner will be used in. | `string` | `"Europe/Amsterdam"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->


##  実行

スイッチロールやMFAを設定しているアカウントで実行する場合は、aws-vault を使って実行することをお勧めします。

```
% aws-vault exec e2-dev -- terraform plan -out=plan
```
