#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


ENDPOINT = "https://alidns.aliyuncs.com/"
API_VERSION = "2015-01-09"


def percent_encode(value: object) -> str:
    return urllib.parse.quote(str(value), safe="~")


def call_api(action: str, **action_parameters: object) -> dict[str, object]:
    parameters: dict[str, object] = {
        "AccessKeyId": os.environ["ALIBABA_CLOUD_ACCESS_KEY_ID"],
        "Action": action,
        "Format": "JSON",
        "SignatureMethod": "HMAC-SHA1",
        "SignatureNonce": str(uuid.uuid4()),
        "SignatureVersion": "1.0",
        "Timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "Version": API_VERSION,
        **action_parameters,
    }
    canonical_query = "&".join(
        f"{percent_encode(key)}={percent_encode(parameters[key])}" for key in sorted(parameters)
    )
    string_to_sign = f"GET&%2F&{percent_encode(canonical_query)}"
    signing_key = (os.environ["ALIBABA_CLOUD_ACCESS_KEY_SECRET"] + "&").encode()
    signature = base64.b64encode(
        hmac.new(signing_key, string_to_sign.encode(), hashlib.sha1).digest()
    ).decode()
    request_url = ENDPOINT + "?" + canonical_query + "&Signature=" + percent_encode(signature)

    try:
        with urllib.request.urlopen(request_url, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            error_payload = json.loads(exc.read().decode("utf-8", errors="replace"))
            error_code = error_payload.get("Code", "HTTPError")
            error_message = error_payload.get("Message", str(exc))
        except Exception:
            error_code = "HTTPError"
            error_message = str(exc)
        print(f"dns_error_code={error_code}", file=sys.stderr)
        print(f"dns_error_message={error_message}", file=sys.stderr)
        raise SystemExit(1) from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    parser.add_argument("--rr", required=True)
    parser.add_argument("--type", default="A")
    parser.add_argument("--value", required=True)
    args = parser.parse_args()

    for variable_name in (
        "ALIBABA_CLOUD_ACCESS_KEY_ID",
        "ALIBABA_CLOUD_ACCESS_KEY_SECRET",
    ):
        if not os.environ.get(variable_name):
            raise SystemExit(f"Missing required environment variable: {variable_name}")

    response = call_api(
        "DescribeDomainRecords",
        DomainName=args.domain,
        RRKeyWord=args.rr,
        TypeKeyWord=args.type,
        PageSize=100,
    )
    records = response.get("DomainRecords", {}).get("Record", [])
    matches = [
        item
        for item in records
        if item.get("RR") == args.rr and item.get("Type") == args.type
    ]

    if len(matches) > 1:
        raise SystemExit("Multiple matching DNS records found; refusing to choose one automatically")

    if not matches:
        result = call_api(
            "AddDomainRecord",
            DomainName=args.domain,
            RR=args.rr,
            Type=args.type,
            Value=args.value,
        )
        action = "created"
        record_id = result.get("RecordId", "unknown")
    elif matches[0].get("Value") == args.value:
        action = "unchanged"
        record_id = matches[0].get("RecordId", "unknown")
    else:
        result = call_api(
            "UpdateDomainRecord",
            RecordId=matches[0]["RecordId"],
            RR=args.rr,
            Type=args.type,
            Value=args.value,
        )
        action = "updated"
        record_id = result.get("RecordId", matches[0]["RecordId"])

    print(f"dns_action={action}")
    print(f"dns_record_id={record_id}")
    print(f"dns_name={args.rr}.{args.domain}")
    print(f"dns_type={args.type}")
    print(f"dns_value={args.value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
