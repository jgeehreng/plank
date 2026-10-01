#!/usr/bin/env python3
"""Loopback Phase 0 admission gate. Synthetic account only. No passwords are printed."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import select
import subprocess
import sys
import tempfile


HOST = "f92140f5-8740-4b3b-82f7-74db5353de27"
OTHER = "22222222-2222-4222-8222-222222222222"


def load_https(source_root):
    path = source_root / "tests/auth/macos-https-auth.py"
    spec = importlib.util.spec_from_file_location("macos_https_auth", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mint(minter, *uniqueids):
    result = subprocess.run([str(minter), *uniqueids], check=True, capture_output=True, text=True)
    bundle = json.loads(result.stdout)
    tickets = []
    for ticket in bundle["tickets"]:
        ticket["key_id"] = bundle["key_id"]
        ticket["issuer"] = bundle["issuer"]
        ticket["public_key"] = bundle["public_key"]
        tickets.append(ticket)
    return tickets


def write_policy(directory, ticket, consume_dir):
    policy = {
        "RequireAdmission": True,
        "MaxTTL": 900,
        "ClockSkew": 60,
        "ConsumeDirectory": str(consume_dir),
        "Trust": [{
            "KeyID": ticket["key_id"],
            "Issuer": ticket["issuer"],
            "PublicKey": ticket["public_key"],
        }],
    }
    path = Path(directory) / "admission.plist"
    with path.open("wb") as stream:
        plistlib.dump(policy, stream)
    os.chmod(path, 0o600)


def start(executable, directory):
    process = subprocess.Popen([str(executable), directory], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    if not select.select([process.stdout], [], [], 10)[0]:
        process.kill()
        raise AssertionError("listener readiness timed out")
    line = process.stdout.readline()
    match = re.fullmatch(r"macos_https_auth_ready port=(\d+) desktop_active=1\n", line)
    if not match:
        process.kill()
        raise AssertionError("listener did not report ready: " + line.strip())
    return process, int(match[1])


def stop(process):
    process.terminate()
    try:
        process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=3)


def start_body(ticket=None):
    body = {"username": "synthetic", "start_desktop": True}
    if ticket is not None:
        body["admission"] = {"v": ticket["v"], "payload": ticket["payload"], "sig": ticket["sig"]}
    return body


def expect_rejected(https, tls, port, ticket=None):
    status, result = https.request(tls, port, start_body(ticket))
    assert status == 401 and result == {"state": "admission_rejected"}, (status, sorted(result))


def expect_challenge(https, tls, port, ticket=None):
    status, result = https.request(tls, port, start_body(ticket))
    assert status == 200 and result["state"] == "challenge", (status, result.get("state"))
    return result


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: macos-admission.py <source-root> <https-auth-synthetic> <mint-admission>")
    source_root = Path(sys.argv[1])
    executable = Path(sys.argv[2])
    minter = Path(sys.argv[3])
    https = load_https(source_root)
    config = source_root / "probes/macos/https-cert.cnf"

    with tempfile.TemporaryDirectory(prefix="plank-admission-unmanaged-") as temporary:
        presented = mint(minter, HOST)[0]
        cert = https.create_identity(temporary, config)
        process, port = start(executable, temporary)
        try:
            expect_challenge(https, https.context(cert), port, presented)
        finally:
            stop(process)
    print("unmanaged_presented_admission=ignored")

    host_ticket, wrong_ticket, refund_ticket = mint(minter, HOST, OTHER, HOST)
    with tempfile.TemporaryDirectory(prefix="plank-admission-managed-") as temporary, \
            tempfile.TemporaryDirectory(prefix="plank-admission-consume-") as consume:
        os.chmod(consume, 0o700)
        cert = https.create_identity(temporary, config)
        write_policy(temporary, host_ticket, consume)
        process, port = start(executable, temporary)
        try:
            tls = https.context(cert)
            expect_rejected(https, tls, port)
            print("managed_missing_admission=rejected")
            expect_rejected(https, tls, port, wrong_ticket)
            assert not (Path(consume) / wrong_ticket["admission_id"]).exists()
            print("wrong_workstation=rejected_not_consumed")
            expect_challenge(https, tls, port, host_ticket)
            assert (Path(consume) / host_ticket["admission_id"]).is_file()
            print("valid_admission=consumed_then_challenge")
            expect_rejected(https, tls, port, host_ticket)
            print("replay=rejected")
            challenge = expect_challenge(https, tls, port, refund_ticket)
            status, denied = https.request(tls, port, {
                "conversation_id": challenge["conversation_id"],
                "responses": ["wrong-synthetic-secret"],
            }, "/plank/auth/respond")
            assert status == 200 and denied["state"] == "denied"
            expect_rejected(https, tls, port, refund_ticket)
            print("os_login_failure=not_refunded")
        finally:
            stop(process)

        process, port = start(executable, temporary)
        try:
            expect_rejected(https, https.context(cert), port, host_ticket)
            print("worker_restart=replay")
        finally:
            stop(process)

    print("macos_admission=pass unmanaged=1 managed_missing=1 wrong_uniqueid=1 consumed=1 replay=1 restart=1 os_failure=1")


if __name__ == "__main__":
    main()
