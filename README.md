# OpenLiteSpeed WordPress Bootstrap

A production-grade bash script that provisions a complete OpenLiteSpeed web stack with security hardening on a fresh Debian 11/12 server in a single command.

## Stack

| Component | Version | Port |
|-----------|---------|------|
| OpenLiteSpeed | 1.9.x | 80 (public) |
| PHP LSAPI | 8.2.x | Direct (no proxy) |
| MariaDB | 10.11 LTS | 3306 (localhost) |
| Redis | 7.x | 6379 (localhost) |
| Shorewall | 5.2.x | Firewall |
| Fail2ban | 1.0.x | Intrusion prevention |

## Why OpenLiteSpeed + LSAPI

Unlike Nginx or Apache which delegate PHP execution to a separate PHP-FPM process pool over a socket, OpenLiteSpeed handles PHP natively via LSAPI (LiteSpeed Server Application Programming Interface). PHP workers run as direct extensions of the web server, communicating through shared memory rather than inter-process sockets. This eliminates the IPC overhead present in traditional Nginx + PHP-FPM setups and results in significantly faster PHP execution. Particularly under high concurrency WordPress and WooCommerce workloads.

## What the script does

- Creates application directory structure before any service starts
- Adds the official LiteSpeed repository and installs OpenLiteSpeed 1.9
- Installs PHP 8.2 via LSAPI using the lsphp82 package set from the LiteSpeed repo
- Configures OLS to serve on port 80 with PHP 8.2 as the script handler
- Adds the official MariaDB repository and installs MariaDB 10.11 LTS
- Secures MariaDB and creates an application database with a random password
- Installs Redis bound to localhost only
- Configures Shorewall zone-based firewall allowing only SSH, HTTP, and HTTPS
- Installs Fail2ban with four active jails covering SSH brute force, WordPress login attacks, XML-RPC abuse, and bad bot scanning
- Locks the OLS admin panel to localhost only (SSH tunnel required for access)
- Deploys a PHP test page confirming PHP LSAPI handler, MariaDB, and Redis

## Usage

    git clone https://github.com/hamzanaqvix-code/openlitespeed-wordpress-bootstrap.git
    cd openlitespeed-wordpress-bootstrap
    chmod +x ols-bootstrap.sh
    sudo bash ols-bootstrap.sh

To change the application name edit APP_NAME at the top of ols-bootstrap.sh before running.

## Requirements

- Debian 11 (Bullseye) or Debian 12 (Bookworm)
- Root access
- Fresh server with no existing web stack

## Verified on

- Debian 12.12 (Bookworm) on DigitalOcean Basic Droplet (1 vCPU, 1GB RAM)

## After installation

Visit http://YOUR_SERVER_IP/index.php to verify the stack.

Expected output:
- PHP Version: 8.2.x
- PHP Handler: litespeed (confirms LSAPI, not FPM)
- MariaDB: Connected successfully
- Redis: Connected and read/write verified
- Server Software: LiteSpeed
- OPcache: Enabled
- Imagick: Loaded

## PHP extensions included

lsphp82, lsphp82-common (includes gd, mbstring, xml, zip, bcmath, soap), lsphp82-mysql, lsphp82-redis, lsphp82-curl, lsphp82-intl, lsphp82-imap, lsphp82-imagick, lsphp82-opcache, lsphp82-memcached, lsphp82-igbinary

## Security configuration

Shorewall zones:
- net: public internet
- fw: the server itself
- Policy: DROP all inbound by default, ACCEPT outbound

Allowed inbound:
- SSH (rate limited via SSH/ACCEPT macro)
- HTTP port 80
- HTTPS port 443

Fail2ban jails:
- sshd: bans after 3 failed SSH logins, 24 hour ban
- wordpress-auth: bans after 5 failed wp-login.php attempts, 1 hour ban
- wordpress-xmlrpc: bans after 2 XML-RPC POST requests, 24 hour ban
- ols-badbots: bans known malicious user agents, 24 hour ban

OLS admin panel security:
- Port 7080 is not exposed in Shorewall rules
- Access requires an SSH tunnel: ssh -L 7080:127.0.0.1:7080 root@YOUR_SERVER_IP
- Then open http://127.0.0.1:7080 in your browser

## Related projects

- lemp-stack-bootstrap: https://github.com/hamzanaqvix-code/lemp-stack-bootstrap
- thunderstack-bootstrap: https://github.com/hamzanaqvix-code/thunderstack-bootstrap
