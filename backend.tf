terraform {
  backend "s3" {
    bucket       = "sctp-tfstate-ce13"
    key          = "terraform.tfstate" # change per project/environment, e.g. "my-project/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3 native locking, no DynamoDB table needed
  }
}
