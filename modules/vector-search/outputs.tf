output "index_id" {
  description = "Vector Search index resource name"
  value       = google_vertex_ai_index.vector_index.id
}

output "index_endpoint_id" {
  description = "Vector Search endpoint resource name"
  value       = google_vertex_ai_index_endpoint.vector_endpoint.id
}

output "index_endpoint_private_ip" {
  description = "Private IP address of the Vector Search endpoint"
  value       = google_vertex_ai_index_endpoint.vector_endpoint.private_service_connect_config[0].network_attachment
  sensitive   = true
}

output "deployed_index_id" {
  description = "ID of the deployed index on the endpoint"
  value       = google_vertex_ai_index_endpoint_deployed_index.deployed.deployed_index_id
}
