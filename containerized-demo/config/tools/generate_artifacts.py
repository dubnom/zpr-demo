import os
import sys
import subprocess
import argparse
from pathlib import Path




AUTHDIRNAME="authority"
KEYDIRNAME="keys"

NODES = [("node", "node.zpr.org")]

# Adapters that need a noise key and cert.
ADAPTERS = [("vs", "vs.zpr")]


BOOTSTRAPS = [("vs", "vs.zpr"),
              ("node", "node.zpr.org"),
              ("bas", "bas.zpr.org")]

def run(command, shell=True):
    print(f"> {command}")
    result = subprocess.run(command, shell=shell)
    if result.returncode != 0:
        raise RuntimeError(f"Command failed: {command}")

def write_file(path, content):
    with open(path, "w") as f:
        f.write(content)

def makedirs(builddir):
    Path(builddir).mkdir(parents=True, exist_ok=True)
    (Path(builddir) / AUTHDIRNAME).mkdir(parents=True, exist_ok=True)
    (Path(builddir) / KEYDIRNAME).mkdir(parents=True, exist_ok=True)

def generate_authority(builddir):
    print("\n\n\ngenerating ZPR RSA Certificate Authority\n\n\n")
    authority_dir = Path(builddir) / AUTHDIRNAME
    run(f"openssl genrsa -out {authority_dir}/auth-ca.key 4096")
    run(f"openssl req -x509 -new -key {authority_dir}/auth-ca.key -sha256 -days 1826 -out {authority_dir}/auth-ca.crt"
        f" -subj '/CN=auth.zpr'")

def generate_zpr_rsa(builddir):
    print("\n\n\ngenerating ZPR RSA key and cert\n\n\n")
    authority_dir = Path(builddir) / AUTHDIRNAME
    key_dir = Path(builddir) / KEYDIRNAME
    run(f"openssl genrsa -out {key_dir}/zpr-rsa-key.pem 2048")
    run(f"openssl req -new -key {key_dir}/zpr-rsa-key.pem -out {key_dir}/zpr.csr -subj '/CN=root.zpr'")

    sign_ext = """
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = DNS:*.zpr.org
"""
    write_file(f"{key_dir}/sign.ext", sign_ext)

    run(f"openssl x509 -req -in {key_dir}/zpr.csr -CA {authority_dir}/auth-ca.crt -CAkey {authority_dir}/auth-ca.key "
        f"-CAcreateserial -out {key_dir}/zpr-rsa.crt -days 1825 -sha256 -extfile {key_dir}/sign.ext")

    os.remove(f"{key_dir}/sign.ext")
    os.remove(f"{key_dir}/zpr.csr")

def generate_noise_keys_and_certs(builddir, zprbuilddir, fname, cn):
    print(f"\n\n\ngenerating noise keys and cert for {fname} ({cn})\n\n\n")
    priv_key = f"{fname}-noise.key"
    pub_key = f"{fname}-noise-pub.pem"
    cert = f"{fname}-noise.crt"
    cn = f"/CN={cn}"

    key_dir = Path(builddir) / KEYDIRNAME
    authority_dir = Path(builddir) / AUTHDIRNAME

    run(f"{zprbuilddir}/zpr-core/tools/zpr-pki genkey > {key_dir}/{priv_key}")
    run(f"{zprbuilddir}/zpr-core/tools/zpr-pki pubkey < {key_dir}/{priv_key} > {key_dir}/{pub_key}")
    run(f"{zprbuilddir}/zpr-core/tools/zpr-pki gensignedcert {authority_dir}/auth-ca.crt {authority_dir}/auth-ca.key "
        f"{cn} 365 < {key_dir}/{pub_key} > {key_dir}/{cert}")

def generate_bootstrap_keys(builddir, fname, cn):
    print(f"\n\n\ngenerating bootstrap keys for {fname} ({cn})\n\n\n")
    key_dir = Path(builddir) / KEYDIRNAME
    priv_key = f"{fname}-bs-rsa-key.pem"
    pub_key = f"{fname}-bs-rsa-pubkey.pem"
    run(f"openssl genrsa -out {key_dir}/{priv_key} 2048")
    run(f"openssl rsa -pubout -in {key_dir}/{priv_key} -out {key_dir}/{pub_key}")

def generate_rsa_tls_key_and_cert(builddir, fname, cn):
    print(f"\n\n\ngenerating TLS RSA key and cert for {fname}\n\n")
    key_dir = Path(builddir) / KEYDIRNAME
    priv_key = f"{fname}-tls.key"
    cert_name = f"{fname}-tls.crt"
    run(f"openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -out {key_dir}/{cert_name} -keyout {key_dir}/{priv_key}"
        f" -subj '/CN={cn}' -addext 'subjectAltName=DNS:{cn}'")


def main():
    parser = argparse.ArgumentParser(description="Generate cryptographic artifacts for ZPR demo")

    parser.add_argument("--builddir", type=str, default="build", help="Path to the build directory")
    parser.add_argument("--zprbuilddir", type=str, required=True, help="Path to the zpr source build directory")
    parser.add_argument("--noisekeypair", type=str, help="Generate noise keypair for the given CN")
    parser.add_argument("--force", action="store_true", help="Allow writing to an existing build directory")
    args = parser.parse_args()

    if args.noisekeypair:
        # Just generate a noise keypair for the given CN
        makedirs(args.builddir)
        generate_noise_keys_and_certs(args.builddir, args.zprbuilddir, f"adapter-{args.noisekeypair}", args.noisekeypair)
        print(f"generated noise keypair and cert for {args.noisekeypair} in {Path(args.builddir) / KEYDIRNAME}")
        sys.exit(0)

    if not args.force and Path(args.builddir).is_dir():
        print(f"Error: build directory {args.builddir} already exists.")
        print("To continue anyway pass the --force flag")
        sys.exit(1)

    makedirs(args.builddir)
    generate_authority(args.builddir)
    generate_zpr_rsa(args.builddir)

    generate_rsa_tls_key_and_cert(args.builddir, "bas", "bas.zpr.org")
    generate_rsa_tls_key_and_cert(args.builddir, "vs", "vs.zpr")

    for aname, cn in ADAPTERS:
        generate_noise_keys_and_certs(args.builddir, args.zprbuilddir, f"adapter-{aname}", cn)

    for aname, cn in BOOTSTRAPS:
        generate_bootstrap_keys(args.builddir, aname, cn)

    for aname, cn in NODES:
        generate_noise_keys_and_certs(args.builddir, args.zprbuilddir, aname, cn)

if __name__ == "__main__":
    main()
