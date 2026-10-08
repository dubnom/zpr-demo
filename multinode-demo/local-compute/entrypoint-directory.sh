#!/bin/sh
set -eu

runtime=/runtime
data_dir="$runtime/data"
accesslog_dir="$runtime/accesslog"
mkdir -p "$data_dir" "$accesslog_dir"
mkdir -p "$runtime/slapd.d"
chmod 700 "$runtime" "$data_dir" "$accesslog_dir"

bind_password=$(cat "$runtime/ldap-password")
admin_password=$(cat "$runtime/ldap-admin-password")
bind_hash=$(slappasswd -s "$bind_password")
admin_hash=$(slappasswd -s "$admin_password")
# Render on every start so configuration changes (such as the accesslog change feed)
# reach existing directories without reseeding their data.
sed "s|@@BIND_PASSWORD_HASH@@|$bind_hash|g; s|@@ADMIN_PASSWORD_HASH@@|$admin_hash|g" \
    "$runtime/slapd.conf.template" > "$runtime/slapd.conf"
chmod 600 "$runtime/slapd.conf"

if [ ! -s "$runtime/seed-complete" ]; then
    rm -f "$data_dir/data.mdb" "$data_dir/lock.mdb" "$accesslog_dir/data.mdb" "$accesslog_dir/lock.mdb"
    rm -rf "$runtime/slapd.d"
    mkdir -p "$runtime/slapd.d"
    sed "s|DEMO_BIND_PASSWORD_HASH|$bind_hash|g" "$runtime/seed.ldif" > "$runtime/company.ldif"
    service_accounts_dn="ou=Service Accounts,$ZPR_DIRECTORY_BASE_DN"
    reader_dn="cn=zpr-reader,$service_accounts_dn"
    if ! grep -Fqx "dn: $service_accounts_dn" "$runtime/company.ldif"; then
        printf '\ndn: %s\nobjectClass: top\nobjectClass: organizationalUnit\nou: Service Accounts\n' \
            "$service_accounts_dn" >>"$runtime/company.ldif"
    fi
    if ! grep -Fqx "dn: $reader_dn" "$runtime/company.ldif"; then
        printf '\ndn: %s\nobjectClass: top\nobjectClass: organizationalRole\nobjectClass: simpleSecurityObject\ncn: zpr-reader\nuserPassword: %s\n' \
            "$reader_dn" "$bind_hash" >>"$runtime/company.ldif"
    fi
    if grep -Eq '@@[A-Z0-9_]+@@|DEMO_BIND_PASSWORD_HASH' "$runtime/slapd.conf" "$runtime/company.ldif"; then
        echo 'Unresolved directory template token' >&2
        exit 1
    fi
    slaptest -f "$runtime/slapd.conf" -F "$runtime/slapd.d" -u
    slapadd -f "$runtime/slapd.conf" -b "$ZPR_DIRECTORY_BASE_DN" -l "$runtime/company.ldif"
    : > "$runtime/seed-complete"
    chmod 600 "$runtime/seed-complete"
else
    test -s "$data_dir/data.mdb"
    if grep -Eq '@@[A-Z0-9_]+@@' "$runtime/slapd.conf"; then
        echo 'Unresolved directory template token' >&2
        exit 1
    fi
    slaptest -f "$runtime/slapd.conf" -u
fi

slapd -f "$runtime/slapd.conf" -h 'ldaps://0.0.0.0:1636' -d 0 &
slapd_pid=$!
reader_dn="cn=zpr-reader,ou=Service Accounts,$ZPR_DIRECTORY_BASE_DN"
ready=no
for attempt in $(seq 1 30); do
    if env LDAPTLS_REQCERT=demand LDAPTLS_CACERT="$runtime/ca.crt" ldapsearch -LLL -x \
        -H ldaps://127.0.0.1:1636 -D "$reader_dn" -y "$runtime/ldap-password" \
        -b "$ZPR_DIRECTORY_BASE_DN" -s base '(objectClass=*)' dn >/dev/null 2>&1; then
        ready=yes
        break
    fi
    sleep 1
done
if [ "$ready" != yes ]; then
    kill "$slapd_pid" 2>/dev/null || true
    wait "$slapd_pid" 2>/dev/null || true
    echo 'Organization LDAPS directory did not become ready' >&2
    exit 1
fi

if [ "${ZPR_DIRECTORY_SMOKE_TEST:-0}" = 1 ]; then
    /app/bin/zpr-trusted-service \
        -listen 0.0.0.0:8443 \
        -cert "$runtime/provider.crt" -key "$runtime/provider.key" -client-ca "$runtime/ca.crt" \
        -ldap-uri ldaps://127.0.0.1:1636 -ldap-ca "$runtime/ca.crt" \
        -ldap-base "$ZPR_DIRECTORY_BASE_DN" -ldap-bind "$reader_dn" \
        -ldap-password-file "$runtime/ldap-password" \
        -ldap-identities "$ZPR_DIRECTORY_IDENTITY_MAPPINGS" \
        -ldap-attributes "$ZPR_DIRECTORY_ATTRIBUTES" \
        -ldap-groups-base "ou=Roles,$ZPR_DIRECTORY_BASE_DN" \
        -ldap-changes-base cn=accesslog -ldap-changes-retention 168h &
    provider_pid=$!
    cleanup() {
        kill "$provider_pid" "$slapd_pid" 2>/dev/null || true
        wait "$provider_pid" "$slapd_pid" 2>/dev/null || true
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    lookup() {
        curl -fsS --connect-timeout 1 --max-time 5 --resolve directory:8443:127.0.0.1 \
            --cacert "$runtime/ca.crt" --cert "$runtime/visa-client.crt" --key "$runtime/visa-client.key" \
            -H 'Content-Type: application/json' --data-binary "$1" \
            https://directory:8443/v1/attributes
    }
    changes_get() {
        curl -fsS --connect-timeout 1 --max-time 5 --resolve directory:8443:127.0.0.1 \
            --cacert "$runtime/ca.crt" --cert "$runtime/visa-client.crt" --key "$runtime/visa-client.key" \
            "https://directory:8443/v1/changes$1"
    }
    changes_feed_ready() {
        changes_cursor=$(changes_get '' | sed -n 's/.*"cursor":"\([^"]*\)".*/\1/p')
        [ -n "$changes_cursor" ] && changes_get "?cursor=$changes_cursor" >/dev/null
    }
    smoke_machine=${ZPR_DIRECTORY_SMOKE_MACHINE:?smoke machine is required}
    smoke_owner=${ZPR_DIRECTORY_SMOKE_OWNER:?smoke owner is required}
    smoke_user=${ZPR_DIRECTORY_SMOKE_USER:?smoke user is required}
    smoke_role=${ZPR_DIRECTORY_SMOKE_ROLE:?smoke role is required}
    device_attributes=
    user_attributes=
    for attempt in $(seq 1 30); do
        device_attributes=$(lookup "{\"identities\":[{\"key\":\"device.zpr.adapter.cn\",\"value\":\"$smoke_machine\"}]}" 2>/dev/null || true)
        user_attributes=$(lookup "{\"identities\":[{\"key\":\"user.sub\",\"value\":\"$smoke_user\"}]}" 2>/dev/null || true)
        if printf '%s' "$device_attributes" | grep -Fq "$smoke_owner" &&
           printf '%s' "$user_attributes" | grep -Fq "$smoke_role" &&
           changes_feed_ready 2>/dev/null; then
            echo 'Organization LDAP, trusted-service lookups, and change feed passed'
            exit 0
        fi
        sleep 1
    done
    echo 'Organization LDAP/trusted-service smoke lookups failed' >&2
    exit 1
fi

exec /app/bin/zpr-trusted-service \
    -listen 0.0.0.0:8443 \
    -cert "$runtime/provider.crt" -key "$runtime/provider.key" -client-ca "$runtime/ca.crt" \
    -ldap-uri ldaps://127.0.0.1:1636 -ldap-ca "$runtime/ca.crt" \
    -ldap-base "$ZPR_DIRECTORY_BASE_DN" -ldap-bind "$reader_dn" \
    -ldap-password-file "$runtime/ldap-password" \
    -ldap-identities "$ZPR_DIRECTORY_IDENTITY_MAPPINGS" \
    -ldap-attributes "$ZPR_DIRECTORY_ATTRIBUTES" \
    -ldap-groups-base "ou=Roles,$ZPR_DIRECTORY_BASE_DN" \
    -ldap-changes-base cn=accesslog -ldap-changes-retention 168h
