resource "aws_lightsail_instance" "wg" {
  name              = "wireguard"
  availability_zone = "<TODO FIXME>"
  blueprint_id      = "ubuntu_20_04"
  bundle_id         = "nano_2_0"
  key_pair_name     = "wireguard-ssh-key"
}
