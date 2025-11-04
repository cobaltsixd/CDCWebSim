# MACCDC Target — Setup & Hardening Guide

This repo gets a target web service up and running for a MACCDC-style exercise. It installs **nginx + php-fpm + MariaDB**, seeds a tiny database with a few flags, and drops in a deliberately weak PHP app so you can poke around and then harden it.

Everything here is Bash-only and meant to run on a Kali VM where you can become root. Do a VM snapshot before you start so you can always roll back.

---

## Quick start — clone & run

Do this from an account that can become root:

```bash
sudo su -
cd ~

git clone http://www.github.com/cobaltsixd/CDCWebSim.git
cd CDCWebSim
chmod +x setup-target.sh

# default: vulnerable mode
./setup-target.sh --vuln

# or run a safer baseline
# ./setup-target.sh --harden
```

`setup-target.sh` installs the web stack, creates `/var/www/target/` with sample pages, seeds the `scoredb` database, and enables services.

---

## Verify the target (what to check right after install)

Run these commands to confirm the stack is live and the intentionally vulnerable pages are present:

```bash
# services
systemctl status nginx --no-pager -l
systemctl status php8.4-fpm --no-pager -l   # adjust PHP version if needed
systemctl status mariadb --no-pager -l

# nginx config test
nginx -t

# quick web checks
curl -I http://127.0.0.1/
curl -s http://127.0.0.1/ | sed -n '1,40p'

# sample pages (should return HTML)
curl -s http://127.0.0.1/app/login.php | sed -n '1,120p'
curl -s 'http://127.0.0.1/app/search.php?q=guest' | sed -n '1,120p'

# phpinfo (only present in vuln mode)
curl -s http://127.0.0.1/phpinfo.php | sed -n '1,20p' || echo "phpinfo not found"

# database flags
sudo mysql -D scoredb -e "SELECT id,name,value FROM flags\G"

# listening ports
ss -ltnp | grep -E ':(80|443|3306|9000)' || true
```

A simple vulnerability test (for verification only):

```bash
curl -s 'http://127.0.0.1/app/search.php?q=%27%20or%201=1%20--%20' | sed -n '1,200p'
```

If that reveals multiple users, the sample app is behaving as intentionally vulnerable.

---

## Manual hardening checklist (do these in order)

1. **Snapshot the VM** — make a snapshot before hardening or running any attack scripts.

2. **Remove phpinfo**

   ```bash
   rm -f /var/www/target/phpinfo.php
   systemctl reload nginx
   ```

3. **Bind MariaDB to localhost**

   ```bash
   sed -i.bak 's/^\s*bind-address.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf
   systemctl restart mariadb
   ```

4. **Rotate DB credentials**

   ```bash
   NEWPASS="$(openssl rand -base64 12)"
   mysql -u root <<SQL
   ALTER USER 'webapp'@'localhost' IDENTIFIED BY '${NEWPASS}';
   ALTER USER 'webapp'@'%' IDENTIFIED BY '${NEWPASS}';
   FLUSH PRIVILEGES;
   SQL
   sed -i "s/^DB_PASS=.*/DB_PASS=${NEWPASS}/" /var/www/target/.env.sample
   ```

   Save the new password somewhere secure.

5. **Fix SQL in the app**
   Replace string-concatenated queries in `app/login.php` and `app/search.php` with prepared statements (mysqli or PDO). This is the main coding exercise.

6. **Tighten file ownership & permissions**

   ```bash
   chown -R root:www-data /var/www/target
   find /var/www/target -type d -exec chmod 750 {} \;
   find /var/www/target -type f -exec chmod 640 {} \;
   ```

7. **Disable directory listings**
   Ensure `autoindex off;` is set in `/etc/nginx/sites-available/target`, then:

   ```bash
   nginx -t && systemctl reload nginx
   ```

8. **Add security headers** (in the nginx server block):

   ```
   add_header X-Frame-Options "DENY" always;
   add_header X-Content-Type-Options "nosniff" always;
   add_header Referrer-Policy "no-referrer" always;
   add_header Content-Security-Policy "default-src 'self';" always;
   add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
   ```

   (HSTS only applies if HTTPS is used.)

9. **Harden PHP** (`/etc/php/<version>/fpm/php.ini`):

   ```
   expose_php = Off
   display_errors = Off
   log_errors = On
   ```

   Then `systemctl restart php8.4-fpm` (or the applicable php-fpm service).

10. **Firewall: restrict MariaDB**
    Example iptables rules (adjust the admin network as needed):

    ```bash
    iptables-save > /root/iptables.pre_harden.save
    iptables -F
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp -s 10.0.2.0/24 --dport 3306 -j ACCEPT  # replace with your admin net
    iptables -A INPUT -p icmp -j ACCEPT
    ```

11. **Enable fail2ban**

    ```bash
    apt-get install -y fail2ban
    systemctl enable --now fail2ban
    ```

12. **SSH tweaks (careful not to lock yourself out)**
    Edit `/etc/ssh/sshd_config` to set:

    ```
    PermitRootLogin no
    PasswordAuthentication no   # only if key auth is in place
    ```

    Then `systemctl reload sshd`.

---

## Automated hardening script

There’s a `hardening-playbook.sh` script in the repo that automates the baseline hardening steps: backups, remove phpinfo, bind MariaDB to localhost, rotate the `webapp` DB password, tighten permissions, disable autoindex, add headers, tune PHP ini, apply basic iptables rules, enable fail2ban, and tweak SSH. It saves the rotated DB creds to `/root/backup_hardening/rotated_db_creds.txt` (chmod 600).

To run it:

```bash
chmod +x hardening-playbook.sh
sudo ./hardening-playbook.sh
```

After it runs, the rotated DB password is stored at `/root/backup_hardening/rotated_db_creds.txt`. Keep that file secure or delete it once the password is recorded where you want it.

---

## Post-hardening checks

Confirm the system is hardened:

```bash
systemctl status nginx php8.4-fpm mariadb fail2ban --no-pager -l
nginx -t
curl -I http://127.0.0.1/           # check for security headers
curl -s http://127.0.0.1/phpinfo.php | sed -n '1,20p' || echo "phpinfo removed"
ss -ltnp | grep mysqld || true
# use the rotated DB password saved earlier:
MYSQL_NEW_PASS="$(sed -n '1p' /root/backup_hardening/rotated_db_creds.txt | cut -d'=' -f2)"
mysql -u webapp -p"${MYSQL_NEW_PASS}" -D scoredb -e "SELECT id,name,value FROM flags\G"
```

Look for:

* `phpinfo.php` removed
* `autoindex off` and the security headers showing up
* MariaDB bound to `127.0.0.1`
* Firewall rules that restrict access to 3306
* fail2ban running

---

## Snapshot & attack runs

Take a snapshot before running any attack scripts. If an attack “tears up the server,” restore the snapshot to return to a clean baseline. Decide whether attacks run against the vulnerable baseline (so you can harden afterward) or against the hardened baseline (so you can practice live defense), and snapshot accordingly.

---

## Files in this repo

* `setup-target.sh` — installer for nginx + php-fpm + MariaDB. Supports `--vuln` and `--harden`.
* `hardening-playbook.sh` — automated baseline hardening script.
* `/var/www/target/` — webroot created by the installer. Contains `app/login.php` and `app/search.php` (intentionally vulnerable in `--vuln` mode).
* `README.md` — this file.

---

## Want an attacker or scoreboard script?

If you want an attacker script that runs recon and tests the vulnerable app, or a simple scoreboard that records captured flags, say which one and a few preferences (how noisy the attacker should be, scoreboard DB choice, etc.) and a ready-to-run Bash script will be added to the repo.
