output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "upload_service_name" {
  value = aws_ecs_service.upload.name
}

output "message_service_name" {
  value = aws_ecs_service.message.name
}

output "ecr_upload_repo" {
  value = aws_ecr_repository.upload.name
}

output "ecr_message_repo" {
  value = aws_ecr_repository.message.name
}

output "s3_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "sqs_queue_url" {
  value = aws_sqs_queue.messages.url
}
