#!/usr/bin/env python3
"""Exercise the public Haskell client against a bounded external HTTPS fixture.

This tests the client boundary, not manager workflow execution or TUI acceptance.
"""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import copy
import json
import re
import socket
import ssl
import subprocess
import sys
import threading

source, work, checker = map(Path, sys.argv[1:4])
native = sys.argv[4]
assert native in ("1", "8")
print(f"work={work}", flush=True)
base = json.loads((source / "test/fixtures/manager/v1/valid/capabilities.json").read_bytes())


def certificate(name, common_name="127.0.0.1", san="IP:127.0.0.1"):
    cert, key = work / (name + ".pem"), work / (name + ".key")
    with (work / (name + ".log")).open("wb") as log:
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                        "-days", "1", "-subj", "/CN=" + common_name, "-addext", "subjectAltName=" + san,
                        "-keyout", str(key), "-out", str(cert)], check=True, stdout=log, stderr=log, timeout=30)
    return cert, key


def openssl(*arguments):
    with (work / "constraints.log").open("ab") as log:
        subprocess.run(["openssl", *map(str, arguments)], check=True, stdout=log, stderr=log, timeout=30)


ca, ca_key = work / "ca.pem", work / "ca.key"
openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1",
        "-subj", "/CN=Fixture Root", "-addext", "basicConstraints=critical,CA:TRUE,pathlen:1",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", ca_key, "-out", ca)


def constrained_certificate(name, constraint):
    issuer, leaf = work / (name + "-issuer.pem"), work / (name + "-leaf.pem")
    issuer_key, leaf_key = work / (name + "-issuer.key"), work / (name + "-leaf.key")
    for cert_path, key_path, common_name, signer, signing_key, serial, extensions in [
        (issuer, issuer_key, name, ca, ca_key, "2",
         "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n"
         + "nameConstraints=critical," + constraint + "\n"),
        (leaf, leaf_key, "localhost", issuer, issuer_key, "3",
         "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
         "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n"),
    ]:
        csr, ext = cert_path.with_suffix(".csr"), cert_path.with_suffix(".ext")
        ext.write_text(extensions)
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-subj", "/CN=" + common_name, "-keyout", key_path, "-out", csr)
        openssl("x509", "-req", "-in", csr, "-CA", signer, "-CAkey", signing_key,
                "-set_serial", serial, "-days", "1", "-sha256", "-extfile", ext, "-out", cert_path)
    checked = subprocess.run(["openssl", "verify", "-purpose", "sslserver", "-verify_hostname", "localhost",
                              "-CAfile", str(ca), "-untrusted", str(issuer), str(leaf)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    assert checked.returncode == (0 if name == "name-permitted" else 2), checked.stderr
    if name != "name-permitted":
        assert b"subtree violation" in checked.stderr, checked.stderr
    chain = work / (name + "-chain.pem")
    chain.write_bytes(leaf.read_bytes() + issuer.read_bytes())
    return chain, leaf_key


constrained = {name: constrained_certificate(name, constraint) for name, constraint in [
    ("name-permitted", "permitted;DNS:localhost"),
    ("name-excluded", "excluded;DNS:localhost"),
    ("name-outside", "permitted;DNS:example.invalid"),
]}
cert, key = certificate("trusted")
untrusted, _ = certificate("other")
ip_san, ip_san_key = certificate("ip-san", "localhost")
san_certificates = {
    "ip-san": (ip_san, ip_san_key), "wrong-host": (ip_san, ip_san_key),
    "wrong-ip": certificate("wrong-ip", san="IP:127.0.0.2"),
    "dns-ip": certificate("dns-ip", san="DNS:127.0.0.1"),
}
for scenario, mode, expected in [
    ("name-permitted", "pages", None),
    ("name-excluded", "failure", "transport"), ("name-outside", "failure", "transport"),
    ("ip-san", "pages", None), ("pages", "pages", None), ("bad-pages", "bad-pages", None),
    ("nonce", "nonce", None), ("lost", "lost", None),
    ("changed", "changed", None), ("cancel", "cancel", None),
    ("wrong-ca", "failure", "transport"), ("wrong-host", "failure", "transport"),
    ("wrong-ip", "failure", "transport"), ("dns-ip", "failure", "transport"),
    ("bad-version", "failure", "version"), ("redirect", "failure", "redirect"),
    ("bad-profile", "failure", "profile"), ("writable-profile", "failure", "file"),
]:
    root = work / scenario
    root.mkdir(mode=0o700)
    credential = root / "credential"
    original = b"a" * 64
    credential.write_bytes(original)
    credential.chmod(0o600)
    requests, failures = [], []
    blocked, peer_closed = threading.Event(), threading.Event()
    expiry = (datetime.now(timezone.utc) + timedelta(seconds=60)).isoformat().replace("+00:00", "Z")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, status, value, extras=()):
            raw = json.dumps(value, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json" if status == 200 else "application/problem+json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(raw)))
            for name, value in extras:
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(raw)
            self.wfile.flush()

        def do_GET(self):
            requests.append(("GET", self.path))
            if self.path == "/v1/capabilities":
                if scenario == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "/v1/elsewhere")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                value = copy.deepcopy(base)
                if scenario == "nonce":
                    value["authorityEpoch"] = "e" * 105
                if scenario == "bad-version":
                    value["versions"]["runtimeProtocol"] = [99]
                self.reply(200, value)
            elif self.path.startswith("/v1/snapshot"):
                second = "pageToken=" in self.path
                value = {"version": 1, "page": {"setId": "set_other" if second and scenario == "bad-pages" else "set_fixture",
                    "revision": "revision_fixture", "expiresAt": expiry, "index": int(second), "totalItems": 2,
                    "next": None if second else "/v1/snapshot?pageToken=second"},
                    "items": ["second" if second else "first"]}
                self.reply(200, value)
            elif self.path == "/v1/requests/request_probe":
                self.reply(200, {"version": 1}, [("ETag", '"revision_probe"')])
            elif self.path == "/v1/profiles" and scenario == "changed":
                credential.write_bytes(b"b" * 64)
                self.reply(200, {"version": 1})
            elif self.path == "/v1/blocked":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", "100")
                self.end_headers()
                self.wfile.flush()
                blocked.set()
                self.connection.settimeout(5)
                try:
                    if self.connection.recv(1) == b"":
                        peer_closed.set()
                except ssl.SSLEOFError:
                    peer_closed.set()
                except Exception:
                    failures.append("blocked connection did not close")
            else:
                failures.append("unexpected GET")
                self.reply(404, {"status": 404, "code": "unavailable-resource"})

        def do_POST(self):
            count = int(self.headers["Content-Length"])
            body = self.rfile.read(count)
            requests.append(("POST", self.path))
            if scenario == "lost":
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            command_key = self.headers["Idempotency-Key"]
            if not (len(command_key) == 128 and command_key.startswith("e" * 105 + ".")
                    and re.fullmatch(r"[A-Za-z0-9_-]{22}", command_key[106:])
                    and self.headers["If-Match"] == '"revision_probe"'
                    and body == b'{"operation":"enqueue"}'):
                failures.append("pending command binding changed")
            self.reply(409, {"status": 409, "code": "state-conflict"})

    server = HTTPServer(("127.0.0.1", 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = tls.maximum_version = ssl.TLSVersion.TLSv1_3
    server_cert, server_key = constrained.get(scenario, san_certificates.get(scenario, (cert, key)))
    tls.load_cert_chain(server_cert, server_key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    host = "localhost" if scenario == "wrong-host" or scenario in constrained else "127.0.0.1"
    profile = root / "profile.json"
    trust = ca if scenario in constrained else untrusted if scenario == "wrong-ca" else server_cert
    settings = {"version": 1, "endpoint": f"https://{host}:{server.server_port}/v1",
                "credentialFile": str(credential), "caFile": str(trust)}
    if scenario == "bad-profile":
        settings["extra"] = True
    profile.write_text(json.dumps(settings))
    profile.chmod(0o666 if scenario == "writable-profile" else 0o600)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    command = [str(checker), mode, str(profile)] + ([expected] if expected else []) + ["+RTS", "-N" + native, "-RTS"]
    try:
        if scenario == "cancel":
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                assert blocked.wait(10), "original HTTP task never reached body barrier"
                output, errors = child.communicate(b"cancel\n", timeout=10)
                assert child.returncode == 0 and peer_closed.wait(5), "original request cancellation did not close its connection"
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.communicate(timeout=10)
        else:
            completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            output, errors = completed.stdout, completed.stderr
            (root / "stdout.log").write_bytes(output)
            (root / "stderr.log").write_bytes(errors)
            assert completed.returncode == 0, (scenario, completed.returncode, errors.decode())
        (root / "stdout.log").write_bytes(output)
        (root / "stderr.log").write_bytes(errors)
        assert not failures, (scenario, failures)
        assert original not in output + errors, "credential appeared in diagnostics"
        if scenario in ("lost", "nonce"):
            assert sum(method == "POST" for method, _ in requests) == 1, "implicit mutation retry"
        if scenario == "redirect":
            assert requests == [("GET", "/v1/capabilities")], "redirect was followed"
        if scenario in ("bad-profile", "writable-profile", "wrong-ca", "wrong-host",
                        "wrong-ip", "dns-ip", "name-excluded", "name-outside"):
            assert not requests, "invalid profile or TLS crossed request boundary"
        print("PASS public client", scenario, flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)
        assert not thread.is_alive(), "original HTTPS fixture thread not joined"
