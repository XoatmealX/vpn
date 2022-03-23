set -eux

sudo rm /usr/local/bin/terraform | /bin/true
rm -r /tmp/vpn | /bin/true
mkdir /tmp/vpn
pushd /tmp/vpn

wget -c https://releases.hashicorp.com/terraform/0.12.24/terraform_0.12.24_linux_amd64.zip -O terraform.zip

unzip terraform.zip
sudo install terraform /usr/local/bin


curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip"
unzip awscli-bundle.zip
sudo ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws
