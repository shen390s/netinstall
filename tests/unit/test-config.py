#!/usr/bin/env python3
"""Self-contained validation for the DeploymentConfig schema and the OS catalog.

Task 1.3 — stage0-netboot-image.
Uses only the Python 3 standard library (json/pathlib/sys). It:
  1. loads config.schema.json and asserts it is valid JSON with the
     required-field/type/enum constraints from design.md "Data Models";
  2. validates a complete sample DeploymentConfig against the schema (pass);
  3. validates malformed configs (missing targetDisk, bad os.category enum,
     missing network) and asserts they FAIL;
  4. loads os-catalog.json and asserts it is valid JSON, non-empty, carries the
     pinned reinstall version, and lists linux/windows/dd entries whose argv
     fragments match the reinstall.sh usage text.
"""

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
NETINSTALL_DIR = REPO_ROOT / "stage0" / "payload" / "etc" / "netinstall"
SCHEMA_PATH = NETINSTALL_DIR / "config.schema.json"
CATALOG_PATH = NETINSTALL_DIR / "os-catalog.json"


# ---------------------------------------------------------------------------
# Minimal draft-07 JSON Schema validator (stdlib only).
#
# Supports the subset used by config.schema.json: type, required, properties,
# enum, items, additionalProperties (false or schema), const, allOf, if/then/else.
# This is intentionally not a complete draft-07 implementation.
# ---------------------------------------------------------------------------

def _type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _type_ok(value, expected):
    if isinstance(expected, list):
        return any(_type_ok(value, t) for t in expected)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "array":
        return isinstance(value, list)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "null":
        return value is None
    return False


def validate(instance, schema):
    """Return a list of error strings (empty means the instance is valid)."""
    errors = []

    if "const" in schema and instance != schema["const"]:
        errors.append(f"expected const {schema['const']!r}, got {instance!r}")

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"value {instance!r} not in enum {schema['enum']!r}")

    if "type" in schema and not _type_ok(instance, schema["type"]):
        errors.append(
            f"expected type {schema['type']!r}, got {_type_name(instance)}"
        )

    if errors:
        return errors

    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                errors.append(f"missing required field {req!r}")
        props = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            if key in props:
                errors.extend(validate(value, props[key]))
            elif additional is False:
                errors.append(f"unexpected field {key!r}")
            elif isinstance(additional, dict):
                errors.extend(validate(value, additional))
    elif isinstance(instance, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for i, value in enumerate(instance):
                errors.extend(validate(value, items))

    for subschema in schema.get("allOf", []):
        errors.extend(validate(instance, subschema))

    if "if" in schema:
        if not validate(instance, schema["if"]):
            if "then" in schema:
                errors.extend(validate(instance, schema["then"]))
        elif "else" in schema:
            errors.extend(validate(instance, schema["else"]))

    return errors


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


# ---------------------------------------------------------------------------
# Sample configs
# ---------------------------------------------------------------------------

_SAMPLE_DISK = {
    "id": "wwn-0x5000c500a1234567",
    "model": "Samsung SSD 870 EVO 500GB",
    "serial": "S6PXNX0R123456",
    "size": "500107862016",
}

SAMPLE_VALID = {
    "targetDisk": _SAMPLE_DISK,
    "os": {
        "category": "linux",
        "distro": "debian",
        "version": "12",
        "extra": {},
    },
    "credentials": {
        "username": "ops",
        "password": "changeme",
        "sshKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample",
        "sshPort": 22,
    },
    "network": {
        "mode": "static",
        "ipv4": "192.168.1.100/24",
        "gateway": "192.168.1.1",
        "dns": "1.1.1.1",
    },
    "proxy": {
        "http": "http://proxy.example:8080",
        "https": "http://proxy.example:8080",
        "all": "http://proxy.example:8080",
        "noProxy": ["localhost", "127.0.0.1"],
        "githubProxy": "https://ghproxy.example.com",
    },
    "access": {
        "webPort": 8080,
        "frpcConfig": "/etc/frpc.toml",
    },
}

SAMPLE_WINDOWS = {
    "targetDisk": _SAMPLE_DISK,
    "os": {
        "category": "windows",
        "distro": "windows",
        "version": "11",
        "extra": {"imageName": "Windows 11 Pro", "lang": "en-us"},
    },
    "network": {"mode": "dhcp"},
}


def _without(mapping, *keys):
    copy = json.loads(json.dumps(mapping))
    for key in keys:
        copy.pop(key, None)
    return copy


def _with_os_category(category):
    copy = json.loads(json.dumps(SAMPLE_VALID))
    copy["os"]["category"] = category
    return copy


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_schema_structure(schema):
    assert schema.get("$schema") == "http://json-schema.org/draft-07/schema#", \
        "schema must declare draft-07"
    assert schema.get("type") == "object", "top-level type must be object"
    assert {"targetDisk", "os", "network"} <= set(schema.get("required", [])), \
        "required must include targetDisk, os, network"

    props = schema["properties"]
    assert props["targetDisk"]["type"] == "object"
    assert {"id", "model", "serial", "size"} <= set(props["targetDisk"].get("required", []))

    assert props["os"]["type"] == "object"
    assert props["os"]["properties"]["category"].get("enum") == ["linux", "windows", "dd"], \
        "os.category must be the closed enum linux/windows/dd"
    assert props["os"]["properties"]["extra"]["type"] == "object"

    assert props["credentials"]["type"] == "object"
    assert props["network"]["type"] == "object"
    assert props["network"]["properties"]["mode"].get("enum") == ["dhcp", "static"]
    assert props["proxy"]["type"] == "object"
    assert props["proxy"]["properties"]["noProxy"]["type"] == "array"
    assert props["proxy"]["properties"]["noProxy"]["items"]["type"] == "string"
    assert props["access"]["type"] == "object"


def check_valid_sample(schema):
    assert validate(SAMPLE_VALID, schema) == [], \
        f"sample config should validate, got: {validate(SAMPLE_VALID, schema)}"


def check_windows_sample(schema):
    # exercises the per-category 'extra' validation for windows
    assert validate(SAMPLE_WINDOWS, schema) == [], \
        f"windows sample should validate, got: {validate(SAMPLE_WINDOWS, schema)}"


def check_missing_target_disk_fails(schema):
    assert validate(_without(SAMPLE_VALID, "targetDisk"), schema) != [], \
        "config missing targetDisk must be rejected"


def check_bad_os_category_fails(schema):
    assert validate(_with_os_category("macos"), schema) != [], \
        "config with os.category outside the enum must be rejected"


def check_missing_network_fails(schema):
    assert validate(_without(SAMPLE_VALID, "network"), schema) != [], \
        "config missing network must be rejected"


def check_windows_missing_extra_fails(schema):
    # extra is validated per category: windows requires imageName + lang
    bad = json.loads(json.dumps(SAMPLE_WINDOWS))
    bad["os"]["extra"] = {"lang": "en-us"}
    assert validate(bad, schema) != [], \
        "windows config missing extra.imageName must be rejected"


def check_catalog(catalog):
    assert isinstance(catalog, dict)
    assert catalog.get("reinstallVersion"), "catalog must carry reinstallVersion"

    import re
    assert re.fullmatch(r"[0-9a-f]{40}", catalog["reinstallVersion"]), \
        "reinstallVersion must be a 40-char commit SHA"

    entries = catalog.get("entries")
    assert isinstance(entries, list) and entries, "catalog entries must be non-empty"

    categories = {entry.get("category") for entry in entries}
    assert {"linux", "windows", "dd"} <= categories, \
        f"catalog must list linux, windows and dd; got {categories}"

    for entry in entries:
        for key in ("category", "distro", "version", "argv"):
            assert key in entry, f"entry missing {key!r}: {entry}"
        assert isinstance(entry["argv"], list) and entry["argv"], \
            f"entry argv must be non-empty: {entry}"


def check_catalog_argv_syntax(catalog):
    by_key = {
        (e["category"], e["distro"], e["version"]): e["argv"]
        for e in catalog["entries"]
    }

    assert by_key[("linux", "debian", "12")] == ["debian", "12"]
    assert by_key[("linux", "ubuntu", "24.04")] == ["ubuntu", "24.04"]
    assert by_key[("linux", "ubuntu", "24.04-minimal")] == ["ubuntu", "24.04", "--minimal"]
    assert by_key[("linux", "alpine", "3.21")] == ["alpine", "3.21"]
    assert by_key[("linux", "rocky", "9")] == ["rocky", "9"]

    windows_argv = by_key[("windows", "windows", "any")]
    assert windows_argv[0] == "windows"
    assert "--image-name" in windows_argv and "--lang" in windows_argv

    dd_argv = by_key[("dd", "dd", "any")]
    assert dd_argv[0] == "dd"
    assert "--img" in dd_argv


def main():
    schema = load_json(SCHEMA_PATH)
    catalog = load_json(CATALOG_PATH)

    checks = [
        ("schema is draft-07 with required-field/type constraints",
         lambda: check_schema_structure(schema)),
        ("sample config validates", lambda: check_valid_sample(schema)),
        ("windows sample validates per-category extra", lambda: check_windows_sample(schema)),
        ("missing targetDisk rejected", lambda: check_missing_target_disk_fails(schema)),
        ("bad os.category enum rejected", lambda: check_bad_os_category_fails(schema)),
        ("missing network rejected", lambda: check_missing_network_fails(schema)),
        ("windows missing extra.imageName rejected",
         lambda: check_windows_missing_extra_fails(schema)),
        ("os-catalog is valid JSON, non-empty, versioned",
         lambda: check_catalog(catalog)),
        ("os-catalog argv syntax matches reinstall.sh",
         lambda: check_catalog_argv_syntax(catalog)),
    ]

    failures = 0
    for name, fn in checks:
        try:
            fn()
            print(f"PASS: {name}")
        except AssertionError as exc:
            failures += 1
            print(f"FAIL: {name}: {exc}")
        except Exception as exc:  # noqa: BLE001 - report any unexpected error
            failures += 1
            print(f"ERROR: {name}: {exc!r}")

    print(f"\n{len(checks) - failures}/{len(checks)} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
