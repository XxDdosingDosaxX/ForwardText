#!/usr/bin/env python3
"""Re-issue the Apple Distribution certificate and App Store provisioning
profiles for ForwardText via the App Store Connect API.

Runs in CI so it can use the APP_STORE_CONNECT_* secrets. Writes the new
signing assets to ./out as base64 blobs, which are uploaded as an artifact
and then installed as GitHub secrets.
"""
import base64
import datetime as dt
import json
import os
import sys
import time
import urllib.request

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12, PrivateFormat
from cryptography.x509.oid import NameOID, ExtensionOID

API = "https://api.appstoreconnect.apple.com/v1"

KEY_ID = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
ISSUER_ID = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
P8 = base64.b64decode(os.environ["APP_STORE_CONNECT_API_KEY_BASE64"]).decode()
P12_PASSWORD = os.environ["P12_PASSWORD"]

# bundle id -> profile name (must match the PROVISIONING_PROFILE_* secrets)
PROFILES = {
    "com.kothari.ForwardText": "ForwardText App Store",
    "com.kothari.ForwardTextSheetal": "ForwardText Sheetal App Store",
}


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        P8,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def call(method, path, body=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        print(f"!! {method} {url} -> HTTP {e.code}\n{detail}", file=sys.stderr)
        raise


def main():
    os.makedirs("out", exist_ok=True)

    # --- 1. Inspect existing distribution certificates -------------------
    certs = call("GET", "/certificates?filter[certificateType]=DISTRIBUTION&limit=200")["data"]
    print(f"Existing DISTRIBUTION certificates: {len(certs)}")
    for c in certs:
        a = c["attributes"]
        print(f"  - {a.get('name')} | serial {a.get('serialNumber')} | expires {a.get('expirationDate')} | id {c['id']}")

    # Apple caps distribution certs (3). Free slots by deleting any that are
    # already past expiry, so certificate creation can't fail on the limit.
    for c in certs:
        exp = c["attributes"].get("expirationDate")
        if exp and dt.datetime.fromisoformat(exp.replace("Z", "+00:00")) < dt.datetime.now(dt.timezone.utc):
            print(f"Deleting expired certificate {c['id']}")
            call("DELETE", f"/certificates/{c['id']}")

    # --- 2. New private key + CSR ----------------------------------------
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(
            x509.Name(
                [
                    x509.NameAttribute(NameOID.COMMON_NAME, "Aashay Kothari"),
                    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
                ]
            )
        )
        .sign(key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

    # --- 3. Ask Apple to issue the certificate ---------------------------
    resp = call(
        "POST",
        "/certificates",
        {
            "data": {
                "type": "certificates",
                "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr_pem},
            }
        },
    )
    cert_id = resp["data"]["id"]
    cert_der = base64.b64decode(resp["data"]["attributes"]["certificateContent"])
    cert = x509.load_der_x509_certificate(cert_der)
    print(f"\nIssued certificate {cert_id}")
    print(f"  subject : {cert.subject.rfc4514_string()}")
    print(f"  serial  : {format(cert.serial_number, 'X')}")
    print(f"  valid   : {cert.not_valid_before_utc} -> {cert.not_valid_after_utc}")

    # --- 4. Fetch the issuing intermediate so the .p12 carries the chain --
    chain = []
    try:
        aia = cert.extensions.get_extension_for_oid(ExtensionOID.AUTHORITY_INFORMATION_ACCESS).value
        for desc in aia:
            if desc.access_method.dotted_string == "1.3.6.1.5.5.7.48.2":
                url = desc.access_location.value
                print(f"  chain   : {url}")
                with urllib.request.urlopen(url) as r:
                    chain.append(x509.load_der_x509_certificate(r.read()))
    except Exception as e:  # non-fatal, runners already trust WWDR
        print(f"  chain   : skipped ({e})")

    # --- 5. Package as .p12 using macOS-importable encryption ------------
    enc = (
        PrivateFormat.PKCS12.encryption_builder()
        .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
        .hmac_hash(hashes.SHA1())
        .build(P12_PASSWORD.encode())
    )
    p12 = pkcs12.serialize_key_and_certificates(
        b"ForwardText Distribution", key, cert, chain or None, enc
    )
    with open("out/distribution.p12.b64", "w") as f:
        f.write(base64.b64encode(p12).decode())
    with open("out/distribution.cer", "wb") as f:
        f.write(cert_der)

    # --- 6. Recreate the provisioning profiles against the new cert ------
    existing = call("GET", "/profiles?limit=200")["data"]
    by_name = {p["attributes"]["name"]: p["id"] for p in existing}

    summary = {}
    for bundle_identifier, profile_name in PROFILES.items():
        found = call("GET", f"/bundleIds?filter[identifier]={bundle_identifier}&limit=10")["data"]
        if not found:
            print(f"\n!! bundle id {bundle_identifier} not registered - skipping")
            continue
        bundle_id = found[0]["id"]

        if profile_name in by_name:
            print(f"\nDeleting stale profile '{profile_name}' ({by_name[profile_name]})")
            call("DELETE", f"/profiles/{by_name[profile_name]}")

        created = call(
            "POST",
            "/profiles",
            {
                "data": {
                    "type": "profiles",
                    "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                        "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                    },
                }
            },
        )
        attrs = created["data"]["attributes"]
        slug = bundle_identifier.rsplit(".", 1)[-1]
        with open(f"out/{slug}.mobileprovision.b64", "w") as f:
            f.write(attrs["profileContent"])
        print(f"Created profile '{profile_name}' for {bundle_identifier}, expires {attrs['expirationDate']}")
        summary[bundle_identifier] = profile_name

    with open("out/summary.json", "w") as f:
        json.dump({"certificateId": cert_id, "serial": format(cert.serial_number, "X"), "profiles": summary}, f, indent=2)
    print("\nDone.")


if __name__ == "__main__":
    main()
