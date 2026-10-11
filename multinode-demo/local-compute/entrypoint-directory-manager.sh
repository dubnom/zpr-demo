#!/bin/sh
set -eu

: "${ZPR_DIRECTORY_BASE_DN:?directory base DN required}"
test -r /directory-ca.crt
export LDAPTLS_CACERT=/directory-ca.crt LDAPTLS_REQCERT=demand
php <<'PHP' > /etc/phpldapadmin/config.php
<?php
$base = getenv('ZPR_DIRECTORY_BASE_DN');
echo "<?php\n";
echo '$config->custom->session[\'blowfish\'] = ' . var_export(bin2hex(random_bytes(24)), true) . ";\n";
echo '$servers = new Datastore();' . "\n";
echo '$servers->newServer(\'ldap_pla\');' . "\n";
echo '$servers->setValue(\'server\',\'name\',\'Organization directory\');' . "\n";
echo '$servers->setValue(\'server\',\'host\',\'ldaps://directory:1636\');' . "\n";
echo '$servers->setValue(\'server\',\'base\',array(' . var_export($base, true) . "));\n";
echo '$servers->setValue(\'server\',\'tls_cacert\',\'/directory-ca.crt\');' . "\n";
echo '$servers->setValue(\'login\',\'auth_type\',\'session\');' . "\n";
echo '$servers->setValue(\'login\',\'bind_id\',' . var_export('cn=admin,' . $base, true) . ");\n";
echo '$servers->setValue(\'login\',\'bind_pass\',\'\');' . "\n";
PHP
chmod 600 /etc/phpldapadmin/config.php
exec php -S 0.0.0.0:8080 -t /usr/share/phpldapadmin/htdocs
