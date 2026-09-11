#!/usr/bin/env python3
"""Validate the proposed manager contract, not a running service or client."""

import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import unicodedata

import yaml
from jsonschema import Draft202012Validator, FormatChecker, validators
from jsonschema_path import SchemaPath
from openapi_spec_validator import OpenAPIV31SpecValidator
from referencing import Registry


BASE_URI = "https://agent-cat.invalid/manager-contract"
READ_PATHS = {
    "/capabilities", "/profiles", "/workflows", "/workflows/{id}",
    "/requests", "/requests/{id}", "/preparations/{id}", "/runs",
    "/runs/{id}", "/runs/{id}/snapshot", "/runs/{id}/control",
    "/decisions", "/decisions/{id}", "/commands/{id}",
    "/runs/{id}/outputs", "/artifacts/{id}", "/runs/{id}/exports",
    "/exports/{id}", "/runs/{id}/lineage-requests", "/snapshot", "/events",
}
POST_SCOPES = {
    "/requests": {"submit"}, "/requests/{id}": {"submit"},
    "/captures": {"submit"}, "/preparations/{id}": {"submit", "control"},
    "/runs/{id}/control": {"control"}, "/decisions/{id}": {"control"},
    "/runs/{id}/exports": {"observe", "export"},
    "/runs/{id}/lineage-requests": {"observe", "submit"},
}
EVENT_NAMES = {
    "request.changed", "preparation.changed", "run.changed", "decision.changed",
    "command.changed", "artifact.changed", "service.changed",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


class UniqueYamlLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        keys = set()
        for key_node, _ in node.value:
            if key_node.tag == "tag:yaml.org,2002:merge":
                continue
            key = self.construct_object(key_node, deep=deep)
            require(key not in keys, "duplicate OpenAPI YAML key")
            keys.add(key)
        return super().construct_mapping(node, deep=deep)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError("non-finite JSON number")


def parse_json(raw):
    require(len(raw) <= 2097152, "JSON fixture exceeds request byte bound")
    value = json.loads(raw.decode("utf-8", errors="strict"),
                       object_pairs_hook=unique_object,
                       parse_int=Decimal, parse_float=Decimal,
                       parse_constant=reject_constant)
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        if isinstance(item, str):
            item.encode("utf-8", errors="strict")
        elif isinstance(item, (dict, list)):
            require(depth < 64, "JSON nesting exceeds 64 containers")
            if isinstance(item, dict):
                pending.extend((key, depth + 1) for key in item)
                pending.extend((child, depth + 1) for child in item.values())
            else:
                pending.extend((child, depth + 1) for child in item)
    return value


def integer_value(_checker, value):
    return (isinstance(value, int) and not isinstance(value, bool)
            or isinstance(value, Decimal) and value.is_finite()
            and value == value.to_integral_value())


ContractValidator = validators.extend(
    Draft202012Validator,
    type_checker=Draft202012Validator.TYPE_CHECKER.redefine("integer", integer_value),
)
FORMATS = FormatChecker()


def decimal_string(value, maximum):
    return (isinstance(value, str) and len(value) <= 20
            and re.fullmatch(r"0|[1-9][0-9]*", value) is not None
            and int(value) <= maximum)


@FORMATS.checks("uint64-decimal")
def uint64(value):
    return decimal_string(value, 2**64 - 1)


@FORMATS.checks("uint32-decimal")
def uint32(value):
    return decimal_string(value, 2**32 - 1)


@FORMATS.checks("strong-etag")
def strong_etag(value):
    return (isinstance(value, str) and len(value) <= 1024
            and re.fullmatch(r'"[!#-~]*"', value) is not None)


@FORMATS.checks("idempotency-key")
def idempotency_key(value):
    return (isinstance(value, str) and len(value) <= 128
            and re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{22,}", value) is not None)


@FORMATS.checks("export-name", raises=UnicodeError)
def export_name(value):
    return (isinstance(value, str) and 1 <= len(value.encode("utf-8")) <= 255
            and value not in {".", ".."}
            and not any(c in "/\\" or unicodedata.category(c) == "Cc" for c in value))


def fixture_path(root, name):
    require(isinstance(name, str), "fixture path must be text")
    path = (root / name).resolve()
    require(path.is_relative_to(root) and path.is_file(), "fixture path escapes its directory or is missing")
    return path


def resolve(document, value):
    seen = set()
    while isinstance(value, dict) and "$ref" in value:
        reference = value["$ref"]
        require(isinstance(reference, str) and (reference == "#" or reference.startswith("#/")),
                "external contract reference")
        require(reference not in seen, "cyclic non-schema reference")
        seen.add(reference)
        value = document
        for part in reference[2:].split("/") if reference != "#" else []:
            token = part.replace("~1", "/").replace("~0", "~")
            if isinstance(value, list):
                require(re.fullmatch(r"0|[1-9][0-9]*", token), "invalid JSON pointer array index")
                value = value[int(token)]
            else:
                value = value[token]
    return value


def response_schemas(document, operation, successful, encoding):
    schemas = []
    for status, response in operation.get("responses", {}).items():
        if successful != (str(status).startswith("2")):
            continue
        response = resolve(document, response)
        for media_type, media in response.get("content", {}).items():
            matches = (media_type == "application/octet-stream" if encoding == "utf8"
                       else media_type == "application/json" or media_type.endswith("+json"))
            if matches:
                schemas.append(media["schema"])
    return schemas


def parse_sse(raw):
    text = raw.decode("utf-8", errors="strict")
    require("\r" not in text, "server SSE fixtures use LF framing")
    events = []
    blocks = text.split("\n\n")
    require(len(blocks[-1].encode("utf-8")) <= 16384, "incomplete SSE block exceeds byte bound")
    for block in blocks[:-1]:
        require(len(block.encode("utf-8")) + 2 <= 16384, "SSE block exceeds byte bound")
        fields = {}
        data = []
        for line in block.split("\n"):
            if not line or line.startswith(":"):
                continue
            name, separator, value = line.partition(":")
            require(separator and name in {"id", "event", "data"}, "noncanonical SSE field")
            value = value.removeprefix(" ")
            if name == "data":
                data.append(value)
            else:
                require(name not in fields, "duplicate SSE identity field")
                fields[name] = value
        if not data:
            require(not fields, "heartbeat cannot advance event identity")
            continue
        require(set(fields) == {"id", "event"} and fields["id"]
                and "\0" not in fields["id"] and fields["event"] in EVENT_NAMES,
                "invalid SSE event identity")
        payload = parse_json("\n".join(data).encode("utf-8"))
        require(isinstance(payload, dict) and set(payload) == {"version", "resource", "revision"},
                "invalid invalidation fields")
        require(integer_value(None, payload["version"]) and payload["version"] == 1,
                "unsupported invalidation version")
        require(isinstance(payload["resource"], str) and payload["resource"].startswith("/v1/")
                and isinstance(payload["revision"], str) and payload["revision"],
                "invalid invalidation resource or revision")
        events.append({**fields, "data": payload})
    return events


def validate_contract(openapi_path, fixture_root):
    document = yaml.load(openapi_path.read_text(), Loader=UniqueYamlLoader)
    require(document.get("openapi") == "3.1.1", "contract must declare OpenAPI 3.1.1")
    # Both standard resolvers are offline. A reference is never a fetch instruction.
    schema_path = SchemaPath.from_dict(document, base_uri=BASE_URI, handlers={})
    OpenAPIV31SpecValidator(schema_path).validate()

    def valid(schema, value):
        rooted = {"$id": BASE_URI, "components": document["components"], "allOf": [schema]}
        validator = ContractValidator(rooted, registry=Registry(), format_checker=FORMATS)
        return next(validator.iter_errors(value), None) is None

    schemas = document["components"]["schemas"]
    for schema in schemas.values():
        ContractValidator.check_schema(schema)
    manifest = parse_json((fixture_root / "manifest.json").read_bytes())
    require(manifest["version"] == 1 and not isinstance(manifest["version"], bool), "unsupported fixture manifest")
    cases = {}
    visited = set()
    for case in manifest["cases"]:
        name = case["name"]
        require(name not in cases and case["schema"] in schemas and isinstance(case["valid"], bool),
                "invalid or duplicate fixture definition")
        path = fixture_path(fixture_root, case["file"])
        visited.add(path)
        encoding = case.get("encoding", "json")
        require(encoding in {"json", "utf8"}, "unsupported fixture encoding")
        try:
            raw = path.read_bytes()
            require(len(raw) <= 67108864, "payload fixture exceeds content byte bound")
            value = raw.decode("utf-8", errors="strict") if encoding == "utf8" else parse_json(raw)
        except (ValueError, UnicodeError, RecursionError):
            value = None
            actual = False
        else:
            actual = valid(schemas[case["schema"]], value)
        require(actual == case["valid"], f"fixture {name}: expected valid={case['valid']}")
        cases[name] = (case, value)

    expected = {("get", path): {"observe"} for path in READ_PATHS}
    expected.update({("post", path): scopes for path, scopes in POST_SCOPES.items()})
    actual_operations = {(method, path): operation
                         for path, item in document["paths"].items()
                         for method, operation in resolve(document, item).items()
                         if method in {"get", "post"}}
    require(set(actual_operations) == set(expected), "OpenAPI operations differ from approved resource ledger")
    recorded = set()
    for item in manifest["operations"]:
        key = (item["method"], item["path"])
        require(key not in recorded and key in expected and set(item["scopes"]) == expected[key],
                "operation scope ledger differs from approved contract")
        recorded.add(key)
        operation = actual_operations[key]
        require(set(operation.get("x-required-scopes", [])) == expected[key],
                f"operation {key}: OpenAPI scope metadata differs")
        security = operation.get("security", document.get("security"))
        schemes = document["components"]["securitySchemes"]
        require(security and all(any(schemes[name].get("type") == "http"
                                     and schemes[name].get("scheme") == "bearer"
                                     for name in alternative) for alternative in security),
                "application operation lacks bearer authentication")
        if key == ("get", "/commands/{id}"):
            require(operation.get("x-additional-scopes"), "command lookup omitted original-operation authorization")
        if key[0] == "post":
            path_item = resolve(document, document["paths"][key[1]])
            parameters = [resolve(document, parameter) for parameter in
                          path_item.get("parameters", []) + operation.get("parameters", [])]
            headers = {parameter["name"].lower(): parameter for parameter in parameters
                       if parameter.get("in") == "header"}
            require(headers.get("idempotency-key", {}).get("required"), "POST omitted idempotency key")
            existing = key[1] not in {"/requests", "/captures"}
            require(bool(headers.get("if-match", {}).get("required")) == existing,
                    "POST precondition differs from resource contract")
        for label, successful in [("success", True), ("refusal", False)]:
            case, value = cases[item[label]]
            require(case["valid"], "operation example refers to a negative schema fixture")
            choices = response_schemas(document, operation, successful, case.get("encoding", "json"))
            require(choices and any(valid(schema, value) for schema in choices),
                    f"operation {key}: {label} example does not match its response")
    require(recorded == set(expected), "fixture ledger omitted operations")

    for case in manifest["sse"]:
        path = fixture_path(fixture_root, case["file"])
        visited.add(path)
        try:
            events = parse_sse(path.read_bytes())
        except (ValueError, UnicodeError, RecursionError):
            events = []
            actual = False
        else:
            actual = all(valid(schemas["Event"], event) for event in events)
        require(actual == case["valid"], f"SSE fixture {case['name']}: validity differs")
        if actual:
            require(events == case["events"], f"SSE fixture {case['name']}: completed events differ")
    for download in manifest.get("downloads", []):
        path = fixture_path(fixture_root, download["file"])
        visited.add(path)
        case, value = cases[download["receipt"]]
        require(case["valid"], "download receipt is not a valid representation")
        pointer = download["metadataPointer"]
        require(isinstance(pointer, str) and (not pointer or pointer.startswith("/")),
                "download metadata pointer is invalid")
        metadata = resolve(value, {"$ref": "#" + pointer})
        raw = path.read_bytes()
        require(len(raw) <= 67108864 and uint64(metadata["bytes"]), "download byte bound is invalid")
        require(int(metadata["bytes"]) == len(raw)
                and metadata["sha256"] == hashlib.sha256(raw).hexdigest(),
                f"download {download['name']}: receipt does not bind its exact bytes")
    require(visited == {p.resolve() for p in fixture_root.rglob("*")
                        if p.is_file() and p.name != "manifest.json"},
            "fixture directory contains unvalidated payloads")
    print(f"manager contract: {len(schemas)} schemas, {len(recorded)} operations, "
          f"{len(cases)} payload cases, {len(manifest['sse'])} SSE cases and "
          f"{len(manifest.get('downloads', []))} byte-bound downloads passed; no service execution claimed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openapi", type=Path, default=Path("doc/api/openapi.yaml"))
    parser.add_argument("--fixtures", type=Path, default=Path("test/fixtures/manager/v1"))
    args = parser.parse_args()
    validate_contract(args.openapi.resolve(), args.fixtures.resolve())


if __name__ == "__main__":
    main()
