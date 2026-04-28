output "s3_bucket_name" {
  description = "S3 bucket where hotel documents are uploaded"
  value       = aws_s3_bucket.hotel_docs.bucket
}

output "ecr_repository_url" {
  description = "ECR URL for pushing Docker images"
  value       = aws_ecr_repository.hotel_rag_api.repository_url
}

output "opensearch_endpoint" {
  description = "OpenSearch Serverless endpoint for vector search"
  value       = aws_opensearchserverless_collection.vectors.collection_endpoint
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint for evaluation logs"
  value       = aws_db_instance.eval_db.endpoint
  sensitive   = true
}

output "lambda_function_name" {
  description = "Lambda function name for manual invocation"
  value       = aws_lambda_function.ingest.function_name
}