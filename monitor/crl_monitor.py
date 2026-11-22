"""crl-monitor: one run checks every CRL in the list on every publish endpoint, then reports to Splunk.

For each CRL and endpoint: HTTP 200, a real CRL, signed by the CA named in the list, not expired, not close
to expiry, ThisUpdate not in the future, CRL number never lower than before, not served from a stale cache.
Across endpoints: the same CRL number. Runs as an OpenShift CronJob in the cluster of the other site.

    python crl_monitor.py --config /etc/crl-monitor/config.yaml

Exit codes: 0 run completed (findings are in the events), 1 configuration error, 3 Splunk delivery failed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import socket
import sys
import tempfile
import time
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests
import yaml
from cryptography import x509
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

__version__ = "1.1.0"

# Alert on the first occurrence (signs of tampering or a broken setup); other errors only after N runs in a row.
IMMEDIATE = {"signature_invalid", "crl_number_decreased", "list_invalid", "ca_certs_invalid"}
# Notifications that are not part of a failure streak.
ONE_SHOT = {"list_entry_added", "list_entry_removed", "state_corrupt"}

DEFAULTS: dict[str, Any] = {
    "environment": "unknown",
    "site": "unknown",
    "expiryWarning": {"defaultHours": 17, "rules": []},
    "http": {"timeoutSeconds": 10, "retries": 3},
    "alerting": {"consecutiveFailures": 2, "divergenceMinutes": 30, "clockSkewMinutes": 5},
    "splunk": None,
}


# ----------------------------------------------------------------------------------- inputs

def build_config(raw: Any) -> dict[str, Any]:
    """Apply defaults and check the required keys. Raises ValueError."""
    if not isinstance(raw, dict):
        raise ValueError("configuration must be a mapping")
    missing = [k for k in ("targets", "listFile", "caDir", "stateFile") if not raw.get(k)]
    if missing:
        raise ValueError(f"configuration is missing: {', '.join(missing)}")
    cfg = {**DEFAULTS, **raw}
    for section in ("expiryWarning", "http", "alerting"):
        cfg[section] = {**DEFAULTS[section], **(raw.get(section) or {})}
    for t in cfg["targets"]:
        t["baseUrl"] = str(t["baseUrl"]).rstrip("/")
    return cfg


def load_config(path: str) -> dict[str, Any]:
    return build_config(yaml.safe_load(Path(path).read_text(encoding="utf-8")))


def warning_hours(cfg: dict[str, Any], path: str) -> float:
    """Hours before NextUpdate at which a CRL starts warning. First matching rule wins (e.g. 'root' -> 168)."""
    for rule in cfg["expiryWarning"]["rules"]:
        if str(rule["match"]).lower() in path.lower():
            return float(rule["hours"])
    return float(cfg["expiryWarning"]["defaultHours"])


def load_ca_certs(ca_dir: str) -> dict[str, list[x509.Certificate]]:
    """One PEM file per CA name (all key generations of that CA in the same file). Never from the publish."""
    certs = {}
    for f in sorted(Path(ca_dir).glob("*.pem")):
        if not f.name.startswith("."):   # ConfigMap mounts contain ..data entries
            certs[f.stem] = x509.load_pem_x509_certificates(f.read_bytes())
    if not certs:
        raise ValueError(f"no CA certificates (*.pem) in {ca_dir}")
    return certs


def parse_list(text: str, known_cas: set[str]) -> list[tuple[str, str]]:
    """'<full URL path> <CA name>' per line, '#' starts a comment. An empty list is an error."""
    entries, problems = [], []
    for n, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2 or not parts[0].startswith("/"):
            problems.append(f"line {n}: expected '/path/file.crl ca-name', got '{line}'")
        elif parts[1] not in known_cas:
            problems.append(f"line {n}: unknown CA '{parts[1]}'")
        else:
            entries.append((parts[0], parts[1]))
    if problems:
        raise ValueError("invalid CRL list: " + "; ".join(problems))
    if not entries:
        raise ValueError("the CRL list is empty")
    return entries


# ----------------------------------------------------------------------------------- one CRL

def make_fetcher(cfg: dict[str, Any]) -> Any:
    """GET as a client would, with timeout and retries on connection errors and 5xx."""
    retries = int(cfg["http"]["retries"])
    retry = Retry(total=retries, backoff_factor=0.5, status_forcelist=(500, 502, 503, 504),
                  allowed_methods=frozenset({"GET"}), raise_on_status=False)
    session = requests.Session()
    session.mount("http://", HTTPAdapter(max_retries=retry))
    session.mount("https://", HTTPAdapter(max_retries=retry))
    session.headers["Cache-Control"] = "no-cache"

    def fetch(url: str) -> tuple[int | None, bytes, dict[str, str], str | None]:
        try:
            r = session.get(url, timeout=float(cfg["http"]["timeoutSeconds"]), allow_redirects=False)
            return r.status_code, r.content, {k.lower(): v for k, v in r.headers.items()}, None
        except requests.RequestException as exc:
            return None, b"", {}, f"{type(exc).__name__}: {exc}"

    return fetch


def parse_crl(data: bytes) -> x509.CertificateRevocationList:
    if not data:
        raise ValueError("empty")
    if data.lstrip().startswith(b"-----BEGIN X509 CRL-----"):
        return x509.load_pem_x509_crl(data)
    return x509.load_der_x509_crl(data)


def crl_number(crl: x509.CertificateRevocationList) -> int | None:
    try:
        return int(crl.extensions.get_extension_for_class(x509.CRLNumber).value.crl_number)
    except x509.ExtensionNotFound:
        return None


def is_signed_by(crl: x509.CertificateRevocationList, certs: list[x509.Certificate]) -> bool:
    """True when one of the CA's certificates has the CRL's issuer as subject and its key verifies the CRL."""
    for cert in certs:
        try:
            if cert.subject == crl.issuer and crl.is_signature_valid(cert.public_key()):  # type: ignore[arg-type]
                return True
        except (TypeError, ValueError):
            continue
    return False


def check_crl(cfg: dict[str, Any], target: str, path: str, ca: str, response: tuple[Any, ...],
              certs: list[x509.Certificate], now: datetime, high_water: int | None) -> tuple[list[dict], int | None]:
    """All checks for one CRL on one endpoint. Returns the findings and the CRL number if the signature verified."""
    status, body, headers, error = response
    findings: list[dict[str, Any]] = []
    info: dict[str, Any] = {"target": target, "path": path, "ca": ca, "httpStatus": status}
    uploader = {k[len("x-amz-meta-"):]: v for k, v in headers.items() if k.startswith("x-amz-meta-")}
    if uploader:
        info["uploader"] = uploader   # which uploader run and host wrote this object

    def fail(check: str, severity: str, message: str, **extra: Any) -> None:
        findings.append({"check": check, "severity": severity, "message": message, **info, **extra})

    if status != 200:
        fail("http_unavailable", "error", f"CRL not available: {error or f'HTTP {status}'}")
        return findings, None
    if headers.get("x-cache-status", "").upper() == "STALE":
        fail("stale_cache", "error", "served from a stale cache: the serving layer cannot read its S3")
    try:
        crl = parse_crl(body)
    except ValueError as exc:
        fail("not_a_crl", "error", f"response is not a CRL ({len(body)} bytes): {exc}")
        return findings, None

    number = crl_number(crl)
    info.update({"crlNumber": number, "sha256": hashlib.sha256(body).hexdigest()})
    verified = is_signed_by(crl, certs)
    if not verified:
        fail("signature_invalid", "error", f"not signed by CA '{ca}' (issuer in CRL: {crl.issuer.rfc4514_string()})")
    if crl.last_update_utc > now + timedelta(minutes=float(cfg["alerting"]["clockSkewMinutes"])):
        fail("not_yet_valid", "error", f"ThisUpdate {crl.last_update_utc.isoformat()} is in the future")
    next_update = crl.next_update_utc
    if next_update is None or next_update <= now:
        fail("expired", "error", f"CRL expired at {next_update.isoformat() if next_update else '(no NextUpdate)'}")
    else:
        hours = (next_update - now).total_seconds() / 3600
        limit = warning_hours(cfg, path)
        if hours < limit:
            fail("expires_soon", "warning", f"CRL expires in {hours:.1f} h (threshold {limit:g} h)",
                 hoursRemaining=round(hours, 2))
    if verified and number is not None and high_water is not None and number < high_water:
        fail("crl_number_decreased", "error",
             f"CRL number {number} is lower than {high_water} seen before (old CRL served)")
    return findings, (number if verified else None)


# ----------------------------------------------------------------------------------- state

def empty_state() -> dict[str, Any]:
    return {"highWater": {}, "listEntries": None, "failures": {}, "divergenceSince": {}}


def load_state(path: str) -> dict[str, Any]:
    """Missing -> empty. Unreadable -> ValueError (the caller warns and starts fresh)."""
    empty = empty_state()
    p = Path(path)
    if not p.exists():
        return empty
    try:
        state = json.loads(p.read_text(encoding="utf-8"))
        return {**empty, **{k: state[k] for k in empty if k in state}}
    except (OSError, ValueError, TypeError) as exc:
        raise ValueError(f"cannot read state {path}: {exc}") from exc


def save_state(path: str, state: dict[str, Any]) -> None:
    """Atomic: temp file in the same directory, then rename."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=p.parent)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=1, sort_keys=True)
    os.replace(tmp, p)


# ----------------------------------------------------------------------------------- Splunk

class SplunkError(Exception):
    pass


def send_events(splunk: dict[str, Any], events: list[dict[str, Any]], attempts: int = 3) -> None:
    """All events in one HEC request, with retries. The token comes from the mounted Secret file."""
    token = os.environ.get("SPLUNK_HEC_TOKEN") or Path(splunk["tokenFile"]).read_text(encoding="utf-8")
    token = token.strip().removeprefix("Splunk ").strip()
    host = socket.gethostname()
    body = "\n".join(json.dumps({"time": e["epoch"], "host": host, "event": e,
                                 "source": splunk.get("source", "crl-monitor"),
                                 "sourcetype": splunk.get("sourcetype", "crl:monitor"),
                                 **({"index": splunk["index"]} if splunk.get("index") else {})}, default=str)
                     for e in events)
    last = ""
    for attempt in range(1, attempts + 1):
        try:
            r = requests.post(splunk["url"], data=body.encode(), timeout=float(splunk.get("timeoutSeconds", 10)),
                              headers={"Authorization": f"Splunk {token}"}, verify=splunk.get("verifyTls", True))
            if r.status_code == 200:
                return
            last = f"HTTP {r.status_code}: {r.text[:200]}"
        except requests.RequestException as exc:
            last = str(exc)
        if attempt < attempts:
            time.sleep(0.5 * attempt + random.random() * 0.4)  # noqa: S311 - jitter, not crypto
    raise SplunkError(f"HEC delivery failed after {attempts} attempts: {last}")


# ----------------------------------------------------------------------------------- run

def run(cfg: dict[str, Any], now: datetime | None = None, fetch: Any = None, send: Any = None,
        out: Any = sys.stdout) -> int:
    started = time.monotonic()
    now = now or datetime.now(UTC)
    fetch = fetch or make_fetcher(cfg)
    findings: list[dict[str, Any]] = []

    try:
        state = load_state(cfg["stateFile"])
    except ValueError as exc:
        findings.append({"check": "state_corrupt", "severity": "warning", "message": f"{exc}; starting fresh"})
        state = empty_state()

    entries: list[tuple[str, str]] = []
    certs: dict[str, list[x509.Certificate]] = {}
    try:
        certs = load_ca_certs(cfg["caDir"])
        try:
            entries = parse_list(Path(cfg["listFile"]).read_text(encoding="utf-8"), set(certs))
        except (OSError, ValueError) as exc:
            findings.append({"check": "list_invalid", "severity": "error", "message": str(exc)})
    except (OSError, ValueError) as exc:
        findings.append({"check": "ca_certs_invalid", "severity": "error", "message": str(exc)})

    # Changes to the list since the last run (removing a line is the easiest way to hide a broken CRL).
    if entries:
        current = sorted(f"{p} {c}" for p, c in entries)
        previous = state["listEntries"]
        state["listEntries"] = current
        if previous is not None:
            findings += [{"check": "list_entry_added", "severity": "info", "message": f"added: {e}"}
                         for e in sorted(set(current) - set(previous))]
            findings += [{"check": "list_entry_removed", "severity": "warning", "message": f"removed: {e}"}
                         for e in sorted(set(previous) - set(current))]

    checked = clean = 0
    for path, ca in entries:
        numbers: dict[str, int] = {}
        for target in cfg["targets"]:
            # Keep '+' literal: AD CS delta CRL names contain it and clients request it unencoded.
            url = target["baseUrl"] + quote(path, safe="/+")
            hw_key = f"{target['name']}|{path}"   # per endpoint: a lagging site is divergence, not a replay
            found, number = check_crl(cfg, target["name"], path, ca, fetch(url), certs[ca], now,
                                      state["highWater"].get(hw_key))
            findings += found
            checked += 1
            clean += not any(f["severity"] in ("error", "warning") for f in found)
            if number is not None:   # only signature-verified CRLs may raise the high-water mark
                numbers[target["name"]] = number
                state["highWater"][hw_key] = max(number, state["highWater"].get(hw_key, 0))
        # Endpoints serving different numbers for too long: one site did not receive the latest CRL.
        if len(numbers) >= 2 and len(set(numbers.values())) > 1:
            since = state["divergenceSince"].setdefault(path, now.timestamp())
            minutes = (now.timestamp() - since) / 60
            if minutes >= float(cfg["alerting"]["divergenceMinutes"]):
                findings.append({"check": "sites_diverged", "severity": "warning", "path": path, "numbers": numbers,
                                 "message": f"endpoints serve different CRL numbers for {minutes:.0f} min"})
        elif len(numbers) >= 2:
            state["divergenceSince"].pop(path, None)

    # A non-urgent error becomes an error only after N runs in a row; until then it is a pending warning.
    streaks = {}
    for f in findings:
        if f["check"] in ONE_SHOT or f["severity"] == "info":
            continue
        key = f"{f.get('target', '*')}|{f.get('path', '*')}|{f['check']}"
        streaks[key] = state["failures"].get(key, 0) + 1
        f["consecutive"] = streaks[key]
        if f["severity"] == "error" and f["check"] not in IMMEDIATE \
                and streaks[key] < int(cfg["alerting"]["consecutiveFailures"]):
            f.update(severity="warning", pending=True)
    state["failures"] = streaks

    events = [{"event": "crl_monitor_finding", **f} for f in findings]
    try:
        save_state(cfg["stateFile"], state)
    except OSError as exc:
        events.append({"event": "crl_monitor_finding", "check": "state_save_failed", "severity": "error",
                       "message": str(exc)})
    severities = [e["severity"] for e in events]
    events.append({"event": "crl_monitor_run_completed",
                   "status": "error" if "error" in severities else "warning" if "warning" in severities else "ok",
                   "crlChecks": checked, "ok": clean, "errors": severities.count("error"),
                   "warnings": severities.count("warning"), "durationMs": int((time.monotonic() - started) * 1000)})
    run_id = uuid.uuid4().hex[:12]
    for e in events:
        e.update(runId=run_id, site=cfg["site"], environment=cfg["environment"], version=__version__,
                 epoch=round(time.time(), 3))
        out.write(json.dumps(e, default=str) + "\n")
    out.flush()

    if send is None and cfg["splunk"]:
        def send(batch: list[dict[str, Any]]) -> None:
            send_events(cfg["splunk"], batch)
    if send is not None:
        try:
            send(events)
        except (SplunkError, OSError) as exc:
            print(f"splunk delivery failed: {exc}", file=sys.stderr)
            return 3
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="CRL monitor (one run)")
    parser.add_argument("--config", default="/etc/crl-monitor/config.yaml")
    args = parser.parse_args(argv)
    try:
        cfg = load_config(args.config)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 1
    return run(cfg)


if __name__ == "__main__":
    raise SystemExit(main())
