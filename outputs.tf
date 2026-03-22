output "ec2_public_ip" {
  description = "Public IP of the EC2 instance — access the app at http://<this IP>"
  value       = aws_instance.app.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.app.public_dns
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = "${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}"
}

output "rds_secret_arn" {
  description = "ARN of the Secrets Manager secret holding RDS credentials"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app.id
}

output "app_url" {
  description = "URL to reach the Flask application"
  value       = "http://${aws_instance.app.public_ip}"
}
