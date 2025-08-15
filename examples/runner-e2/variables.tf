variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "A name that identifies the environment, will used as prefix and for tagging."
  type        = string
  default     = "gitlab-runner"
}

variable "runner_name" {
  description = "Name of the runner, will be used in the runner config.toml"
  type        = string
  default     = "gitlab-runner-docker"
}

variable "gitlab_url" {
  description = "URL of the gitlab instance to connect to."
  type        = string
  default     = "https://gitlab.e-2.jp"
}

variable "preregistered_runner_token_ssm_parameter_name" {
  description = "The name of the SSM parameter to read the preregistered GitLab Runner token from."
  type        = string
  default     = "/gitlab/runner/token"
}

variable "timezone" {
  description = "Name of the timezone that the runner will be used in."
  type        = string
  default     = "Asia/Tokyo"
}
