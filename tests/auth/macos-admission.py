#!/usr/bin/env python3
"""Loopback macOS admission qualification. Synthetic credentials only.

The probe reads an admission plist only from its temporary certificate
directory. This does not start a Broker, reboot a host, or write
require_admission into an installed Host configuration.
"""
import argparse
import base64
import http.client
import io
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


def uniqueid_matches(expected, actual):
    """Same UUID predicate as the Host's plank_admission_uniqueid_matches()."""
    if not isinstance(expected, str) or not isinstance(actual, str):
        return False
    left = expected.encode("utf-8")
    right = actual.encode("utf-8")
    hyphens = (8, 13, 18, 23)

    def at(buf, index):
        if index < len(buf):
            return buf[index]
        if index == len(buf):
            return 0
        return None

    for index in range(36):
        a = at(left, index)
        b = at(right, index)
        if a is None or b is None:
            return False
        if index in hyphens:
            if a != ord("-") or b != ord("-"):
                return False
            continue
        if ord("A") <= a <= ord("F"):
            a = a - ord("A") + ord("a")
        if ord("A") <= b <= ord("F"):
            b = b - ord("A") + ord("a")
        hex_a = (ord("0") <= a <= ord("9")) or (ord("a") <= a <= ord("f"))
        hex_b = (ord("0") <= b <= ord("9")) or (ord("a") <= b <= ord("f"))
        if not hex_a or not hex_b or a != b:
            return False
    return at(left, 36) == 0 and at(right, 36) == 0


def self_test():
    same = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    assert uniqueid_matches(same, same)
    assert uniqueid_matches(same.upper(), same)
    assert uniqueid_matches(same, same.upper())
    assert not uniqueid_matches(same, other)
    assert not uniqueid_matches("not-a-uuid", "not-a-uuid")
    assert not uniqueid_matches(same + "a", same)
    assert not uniqueid_matches(same[:-1], same)
    assert not uniqueid_matches("", "")
    print("macos_admission_gate=pass")


class ResponseBytes:
    def __init__(self, value):
        self.value = value

    def makefile(self, *args):
        return io.BytesIO(self.value)


def tls_command(certificate, port):
    return ["openssl", "s_client", "-connect", f"127.0.0.1:{port}", "-servername", "localhost",
            "-CAfile", str(certificate), "-verify_return_error", "-verify", "1", "-tls1_3",
            "-alpn", "http/1.1", "-quiet"]


def request(certificate, port, body=None, path="/plank/auth/start", raw=None, xml=False):
    encoded = b"" if body is None else json.dumps(body).encode()
    message = raw if raw is not None else (
        f"POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
        f"Content-Length: {len(encoded)}\r\n\r\n".encode() + encoded
    )
    result = subprocess.run(tls_command(certificate, port), input=message, capture_output=True, timeout=7)
    if result.returncode:
        raise AssertionError("TLS request failed")
    reply = http.client.HTTPResponse(ResponseBytes(result.stdout))
    reply.begin()
    content = reply.read()
    if xml:
        return reply.status, content
    return reply.status, json.loads(content)


def serverinfo_uniqueid(certificate, port):
    raw = b"GET /serverinfo HTTP/1.1\r\nHost: localhost\r\n\r\n"
    status, content = request(certificate, port, raw=raw, xml=True)
    if status != 200:
        raise AssertionError("serverinfo failed")
    marker = b"<uniqueid>"
    start = content.find(marker)
    end = content.find(b"</uniqueid>", start)
    if start < 0 or end < 0:
        raise AssertionError("serverinfo has no workstation id")
    return content[start + len(marker):end].decode("ascii")


def create_identity(temporary, config):
    os.chmod(temporary, 0o700)
    cert, key = Path(temporary) / "cert.pem", Path(temporary) / "key.pem"
    subprocess.run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
                    "-nodes", "-days", "1", "-config", str(config), "-keyout", str(key),
                    "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
    subprocess.run(["openssl", "x509", "-in", str(cert), "-outform", "DER", "-out", str(Path(temporary) / "cert.der")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    help_result = subprocess.run(["openssl", "rsa", "-help"], capture_output=True)
    traditional = ["-traditional"] if b"-traditional" in help_result.stdout + help_result.stderr else []
    subprocess.run(["openssl", "rsa", *traditional, "-in", str(key), "-outform", "DER",
                    "-out", str(Path(temporary) / "key.der")],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(Path(temporary) / "key.der", 0o600)
    return cert


def start_server(executable, directory):
    process = subprocess.Popen([str(executable), directory], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    if not select.select([process.stdout], [], [], 10)[0]:
        process.kill()
        raise AssertionError("HTTPS listener readiness timed out")
    line = process.stdout.readline()
    prefix = "macos_https_auth_ready port="
    if not line.startswith(prefix) or "desktop_active=1" not in line:
        process.kill()
        raise AssertionError("HTTPS listener did not report ready")
    port = int(line[len(prefix):].split()[0])
    return process, port


def stop_server(process):
    process.terminate()
    try:
        process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=3)


def consume_count(directory):
    consumed = Path(directory) / "consumed"
    if not consumed.exists():
        return 0
    return sum(1 for entry in consumed.iterdir() if entry.is_file())


def payload_is_lowercase(bundle):
    payload = bundle["admission"]["payload"]
    if any(char in payload for char in "+/="):
        return False
    padded = payload + "=" * ((4 - len(payload) % 4) % 4)
    raw = base64.urlsafe_b64decode(padded)
    workstation = bundle["workstation_uniqueid"].lower().encode("ascii")
    uppercase = bundle["workstation_uniqueid"].upper().encode("ascii")
    if uppercase != workstation and uppercase in raw:
        return False
    return raw.startswith(b"PLAD") and raw[4:5] == b"\x01" and workstation in raw


def load_bundle(path):
    bundle = json.loads(Path(path).read_text())
    if not payload_is_lowercase(bundle):
        raise AssertionError("signed workstation id was not lowercase")
    mode = Path(path).stat().st_mode & 0o777
    if mode != 0o600:
        raise AssertionError("bundle mode is not private")
    return bundle


def mint(mint_bin, directory):
    result = subprocess.run([str(mint_bin), directory], capture_output=True, text=True, timeout=10)
    if result.returncode or result.stdout != "mint_admission=pass\n":
        raise AssertionError("mint failed")
    plist = Path(directory) / "admission.plist"
    if (plist.stat().st_mode & 0o777) != 0o600 or b"RequireAdmission" not in plist.read_bytes():
        raise AssertionError("admission plist was not written")
    return (load_bundle(Path(directory) / "bundle.json"),
            load_bundle(Path(directory) / "bundle-case.json"),
            load_bundle(Path(directory) / "bundle-other.json"))


def post_start(certificate, port, admission=None):
    body = {"username": "synthetic", "start_desktop": True}
    if admission is not None:
        body["admission"] = admission
    return request(certificate, port, body)


def qualify(executable, mint_bin, config):
    self_test()
    with tempfile.TemporaryDirectory(prefix="plank-macos-admission-") as temporary:
        certificate = create_identity(temporary, config)
        process, port = start_server(executable, temporary)
        try:
            if consume_count(temporary) != 0:
                raise AssertionError("unmanaged probe created a consume record")
            status, result = post_start(certificate, port)
            if status != 200 or result.get("state") != "challenge":
                raise AssertionError("unmanaged login changed")
        finally:
            stop_server(process)

        match, case, other = mint(mint_bin, temporary)
        process, port = start_server(executable, temporary)
        try:
            presented = serverinfo_uniqueid(certificate, port)
            if not uniqueid_matches(match["workstation_uniqueid"], presented):
                raise AssertionError("server workstation id does not match the bundle")
            if not uniqueid_matches(case["workstation_uniqueid"], presented):
                raise AssertionError("letter case did not match")
            if uniqueid_matches(other["workstation_uniqueid"], presented):
                raise AssertionError("different workstation id matched")
            status, result = post_start(certificate, port)
            if status != 401 or result.get("state") != "admission_rejected" or consume_count(temporary) != 0:
                raise AssertionError("managed login without a ticket reached authentication")
            # A different UUID stops before POST. The following request is the
            # Host's own wrong-workstation check, not the Client gate.
            stopped_before_post = not uniqueid_matches(other["workstation_uniqueid"], presented)
            if not stopped_before_post:
                raise AssertionError("different workstation id was sent")
            status, result = post_start(certificate, port, other["admission"])
            if status != 401 or result.get("state") != "admission_rejected" or consume_count(temporary) != 0:
                raise AssertionError("wrong workstation id was consumed")
            status, result = post_start(certificate, port, case["admission"])
            if status != 200 or result.get("state") != "challenge" or consume_count(temporary) != 1:
                raise AssertionError("case-only workstation id was rejected")
            status, denied = request(certificate, port, {
                "conversation_id": result["conversation_id"],
                "responses": ["wrong-synthetic-secret"],
                "start_desktop": True,
            }, "/plank/auth/respond")
            if status != 200 or denied.get("state") != "denied" or consume_count(temporary) != 1:
                raise AssertionError("authentication failure removed the consume record")
            status, result = post_start(certificate, port, case["admission"])
            if status != 401 or result.get("state") != "admission_rejected" or consume_count(temporary) != 1:
                raise AssertionError("same ticket was accepted after authentication failure")
            status, result = post_start(certificate, port, match["admission"])
            if status != 200 or result.get("state") != "challenge" or consume_count(temporary) != 2:
                raise AssertionError("valid ticket did not reach authentication")
        finally:
            stop_server(process)

        process, port = start_server(executable, temporary)
        try:
            status, result = post_start(certificate, port, match["admission"])
            if status != 401 or result.get("state") != "admission_rejected" or consume_count(temporary) != 2:
                raise AssertionError("worker restart accepted a consumed ticket")
        finally:
            stop_server(process)
    print("macos_admission=pass unmanaged=1 managed_rejected=1 case_match=1 "
          "wrong_host_not_consumed=1 stopped_before_post=1 auth_failure_consumed=1 "
          "worker_restart_replay=1")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--server", type=Path)
    parser.add_argument("--mint", type=Path)
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.server or not args.mint or not args.config:
        parser.error("qualification requires --server, --mint, and --config")
    qualify(args.server, args.mint, args.config)


if __name__ == "__main__":
    main()
