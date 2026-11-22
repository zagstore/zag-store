"""Checks the App Store Connect requests Zag Store makes, and the mock
responses its tests are built on, against Apple's published OpenAPI document
(https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip).

  python3 -I zag-asc-openapi-check.py <openapi.oas.json> <exchanges.jsonl>

The exchanges are written by ZagDeveloperAccountTests (ZAG_ASC_REQUEST_DUMP).
Every request must use a documented operation, documented query parameters
and enum values within their limits, and a body that matches the request
schema exactly (required fields present, enums valid, no undocumented fields).
Every 2xx mock response must match the documented response schema's types and
enums, so the mock cannot drift from Apple's documented shapes. Nothing here
contacts Apple.
"""
import json
import re
import sys

spec = json.load(open(sys.argv[1]))
exchanges = [json.loads(line) for line in open(sys.argv[2]) if line.strip()]


def resolve(node):
    while isinstance(node, dict) and "$ref" in node:
        _, *parts = node["$ref"].split("/")
        node = spec
        for part in parts:
            node = node[part]
    return node


def operation(method, path):
    for template, item in spec["paths"].items():
        pattern = "^" + re.sub(r"\{[^}]+\}", "[^/]+", template) + "$"
        if re.match(pattern, path) and method.lower() in item:
            return template, item[method.lower()]
    return None, None


problems = []


def check(value, schema, where, strict):
    schema = resolve(schema)
    if "oneOf" in schema or "anyOf" in schema:
        options = schema.get("oneOf") or schema.get("anyOf")
        for option in options:
            before = len(problems)
            check(value, option, where, strict)
            if len(problems) == before:
                return
            del problems[before:]
        problems.append(f"{where}: matches none of its documented forms")
        return
    kind = schema.get("type")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{where}: {value!r} is not one of {schema['enum']}")
    if kind == "object" or "properties" in schema:
        if not isinstance(value, dict):
            problems.append(f"{where}: expected an object")
            return
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                problems.append(f"{where}: missing required {name}")
        for name, item in value.items():
            if name in properties:
                check(item, properties[name], f"{where}.{name}", strict)
            elif strict:
                problems.append(f"{where}: undocumented field {name}")
    elif kind == "array":
        if not isinstance(value, list):
            problems.append(f"{where}: expected an array")
            return
        for index, item in enumerate(value):
            check(item, schema.get("items", {}), f"{where}[{index}]", strict)
    elif kind == "string" and not isinstance(value, str):
        problems.append(f"{where}: expected a string")
    elif kind == "integer" and not (isinstance(value, int) and not isinstance(value, bool)):
        problems.append(f"{where}: expected an integer")
    elif kind == "boolean" and not isinstance(value, bool):
        problems.append(f"{where}: expected a boolean")


operations = set()
for exchange in exchanges:
    method, path = exchange["method"], exchange["path"]
    template, op = operation(method, path)
    label = f"{method} {path}"
    if op is None:
        problems.append(f"{label}: not a documented operation")
        continue
    operations.add(f"{method} {template}")
    parameters = {resolve(p)["name"]: resolve(p) for p in op.get("parameters", []) if resolve(p).get("in") == "query"}
    for name, value in exchange["query"]:
        if name not in parameters:
            problems.append(f"{label}: undocumented query parameter {name}")
            continue
        schema = resolve(parameters[name]["schema"])
        if schema.get("type") == "array":
            allowed = resolve(schema.get("items", {})).get("enum")
            for item in value.split(","):
                if allowed and item not in allowed:
                    problems.append(f"{label}: {name}={item} is not one of {allowed}")
        elif schema.get("type") == "integer":
            if not value.isdigit() or ("maximum" in schema and int(value) > schema["maximum"]):
                problems.append(f"{label}: {name}={value} exceeds {schema.get('maximum')}")
    if exchange["body"] is not None:
        body_schema = op.get("requestBody", {})
        body_schema = resolve(body_schema).get("content", {}).get("application/json", {}).get("schema")
        if body_schema is None:
            problems.append(f"{label}: sends a body the operation does not take")
        else:
            check(exchange["body"], body_schema, f"{label} body", strict=True)
    status = str(exchange["status"])
    if status.startswith("2"):
        documented = op.get("responses", {})
        if status not in documented:
            problems.append(f"{label}: status {status} is not documented")
        elif exchange["response"] is not None:
            content = resolve(documented[status]).get("content", {})
            schema = content.get("application/json", {}).get("schema")
            if schema:
                check(exchange["response"], schema, f"{label} response", strict=False)

print(f"checked {len(exchanges)} exchanges over {len(operations)} operations against {spec['info']['title']} {spec['info']['version']}:")
for name in sorted(operations):
    print("  " + name)
if problems:
    for problem in sorted(set(problems))[:40]:
        print("FAIL: " + problem)
    sys.exit(1)
print("PASS: every request and mock response matches Apple's published schema")
