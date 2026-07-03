bucket                      = "tofu-state"
key                         = "great-falls-tool-bus-infra/edge-dns/terraform.tfstate"
region                      = "us-east-1"
endpoints = {
  s3 = "http://tofu-state-rustfs.nix-cache.svc:9000"
}
use_path_style              = true
skip_credentials_validation = true
skip_region_validation      = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
skip_s3_checksum            = true
