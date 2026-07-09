output "bucket_names" {
  description = "Map of zone to data lake bucket name"
  value = {
    for zone, config in var.bucket_configs :
    zone => "${config.name_prefix}-${var.environment}"
  }
}

output "bucket_urls" {
  description = "Map of zone to bucket gs:// URL"
  value = {
    for zone, config in var.bucket_configs :
    zone => "gs://${config.name_prefix}-${var.environment}"
  }
}

output "kms_key_ids" {
  description = "Map of zone to CMEK key ID"
  value = var.kms_key_name != "" ? {} : {
    for zone, config in var.bucket_configs :
    zone => google_kms_crypto_key.datalake_key[zone].id
  }
}
