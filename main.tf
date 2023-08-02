terraform {
  required_version = ">=1.0.0"

  required_providers {
    aws = {
      version = ">=4.32.2"
      source  = "hashicorp/aws"
    }
  }
}
