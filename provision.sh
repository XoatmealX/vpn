#!/bin/bash
set -eu
source decrypted_credentials

set -eux

## create AWS resources

yes yes | terraform apply 
aws lightsail open-instance-public-ports --instance-name wireguard --port-info fromPort=27000,protocol=UDP,toPort=27000
aws lightsail attach-static-ip --static-ip-name wireguard-static-ip --instance-name wireguard || /bin/true

ip=$(aws lightsail get-instances | grep publicIpAddress |  cut -d'"' -f4)

# wait until instance is launched
until ssh -i wg_rsa ubuntu@$ip "/bin/true"; do echo "cannot ssh to $ip, waiting 30s"; sleep 30s; done

## setup config files

cat <<EOF > wg0.conf
[Interface]
PrivateKey = $server_private_key
Address = 10.99.0.1/24
ListenPort = 27000
DNS = 127.0.0.1
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE;

PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE;

[Peer]
# e.g. your phone
PublicKey = ...
AllowedIPs = 10.99.0.2/32

[Peer]
# e.g. your laptop (the AllowedIPs below needs to increase monotonically
PublicKey = ...
AllowedIPs = 10.99.0.3/32

[Peer]
# e.g. another phone or laptop
PublicKey = ...
AllowedIPs = 10.99.0.4/32

EOF
scp -i wg_rsa wg0.conf ubuntu@$ip:
rm wg0.conf

cat <<EOF > unbound.conf 
server:
    num-threads: 4
    # enable logs
    verbosity: 0
    # list of root DNS servers
    root-hints: "/var/lib/unbound/root.hints"
    # use the root server's key for DNSSEC
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    # respond to DNS requests on all interfaces
    interface: 0.0.0.0
    port: 53000
    max-udp-size: 3072
    # IPs authorised to access the DNS Server
    access-control: 0.0.0.0/0                 refuse
    access-control: 127.0.0.1                 allow
    access-control: 10.99.0.0/24              allow
    # not allowed to be returned for public Internet  names
    private-address: 10.99.0.0/24
    #hide DNS Server info
    hide-identity: yes
    hide-version: yes
    # limit DNS fraud and use DNSSEC
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    # add an unwanted reply threshold to clean the cache and avoid, when possible, DNS poisoning
    unwanted-reply-threshold: 10000000
    # have the validator print validation failures to the log
    val-log-level: 1
    # minimum lifetime of cache entries in seconds
    cache-min-ttl: 1800
    # maximum lifetime of cached entries in seconds
    cache-max-ttl: 14400
    prefetch: yes
    prefetch-key: yes
EOF
scp -i wg_rsa unbound.conf ubuntu@$ip:
rm unbound.conf


cat <<EOF > setupVars.conf
PIHOLE_INTERFACE=wg0
IPV4_ADDRESS=10.99.0.1/24
IPV6_ADDRESS=
QUERY_LOGGING=false
INSTALL_WEB_SERVER=false
INSTALL_WEB_INTERFACE=false
LIGHTTPD_ENABLED=false
WEBPASSWORD=e8d9e97b522f78808a10fadcac8b5abc939d012752e45195490e40c4c0c24ac2
BLOCKING_ENABLED=true
DNSMASQ_LISTENING=single
PIHOLE_DNS_1=127.0.0.1#53000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSSEC=true
CONDITIONAL_FORWARDING=false
EOF
scp -i wg_rsa setupVars.conf ubuntu@$ip:
rm setupVars.conf

## provision the remote machine

cat <<'EOF' > remote_provision.sh
set -eux
export DEBIAN_FRONTEND=noninteractive
# setup dumb ec2 default hostname
ip_addr=$(ip -br -4 addr show dev eth0 | awk '{split($3,a,"/"); print a[1]}')
ec2_addr="ip-$(echo $ip_addr | tr '.' '-')"
echo "127.0.0.1 $ec2_addr" | sudo tee -a /etc/hosts

# do this twice b/c apt sucks
sudo apt-get update -y || sudo apt-get update -y

# lightsail fucks with sshd_config in a stupid way so trim the lightsail specifics
tail -n 3 /etc/ssh/sshd_config > /tmp/lightsail_addons
head -n -3 /etc/ssh/sshd_config > /tmp/sshd_config
sudo cp /tmp/sshd_config /etc/ssh/sshd_config

sudo apt-get upgrade -y

sudo apt-get install -y software-properties-common nload
sudo apt-get update -y || sudo apt-get update -y
sudo apt-get install -y wireguard-dkms wireguard-tools resolvconf unbound unbound-host

## wireguard setup

# enable ipv4 port forwarding
sudo sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
sudo sysctl --system

sudo mv wg0.conf /etc/wireguard/
wg-quick up wg0
sudo systemctl enable wg-quick@wg0


## dns firewall setup
sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 27000 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A INPUT -s 10.99.0.0/24 -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A INPUT -s 10.99.0.0/24 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT


## unbound setup
echo nameserver 1.1.1.1 | sudo tee -a /etc/resolv.conf 

# download list of DNS root servers
sudo curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache

sudo chown -R unbound:unbound /var/lib/unbound
sudo mv unbound.conf /etc/unbound/unbound.conf

sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo systemctl enable unbound-resolvconf
sudo systemctl enable unbound

sudo systemctl --system


## pihole
sudo mkdir -p /etc/pihole/
sudo mv setupVars.conf /etc/pihole/
wget -O basic-install.sh https://install.pi-hole.net
sudo bash basic-install.sh --unattended --disable-install-webserver


## apply patches every day
echo "0 1 * * * sudo apt-get update -y && sudo apt-get upgrade -y && sudo shutdown -r now" | sudo tee /var/spool/cron/crontabs/root

## fin
rm remote_provision.sh
cat /tmp/lightsail_addons | sudo tee -a /etc/ssh/sshd_config
sudo shutdown -r now
EOF
scp -i wg_rsa remote_provision.sh ubuntu@$ip:
rm remote_provision.sh

# execute provision script
ssh  -i wg_rsa ubuntu@$ip "nohup bash remote_provision.sh" || /bin/true

echo "server public key: $server_public_key"
