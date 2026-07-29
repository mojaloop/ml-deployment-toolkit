#!/usr/bin/env python3
"""Minimal JSON Schema validator (stdlib only).

Implements exactly the keyword subset used by config/schemas/*.json:
type, properties, required, additionalProperties, enum, pattern, items,
minimum, maximum. Anything else in a schema is ignored.

Usage: yq -o json e '.' file.yaml | python3 tools/validate.py <schema.json>
Exits non-zero with one line per violation.
"""
import json
import re
import sys

TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "null": type(None),
}


def check_type(value, expected):
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPES[expected])


def validate(value, schema, path, errors):
    expected = schema.get("type")
    if expected is not None:
        allowed = expected if isinstance(expected, list) else [expected]
        if not any(check_type(value, t) for t in allowed):
            errors.append(f"{path}: expected {expected}, got {type(value).__name__}")
            return

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in {schema['enum']}")

    if "pattern" in schema and isinstance(value, str):
        if not re.search(schema["pattern"], value):
            errors.append(f"{path}: {value!r} does not match /{schema['pattern']}/")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} < minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} > maximum {schema['maximum']}")

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required key '{key}'")
        for key, sub in value.items():
            if key in props:
                validate(sub, props[key], f"{path}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unknown key '{key}'")
            elif isinstance(schema.get("additionalProperties"), dict):
                validate(sub, schema["additionalProperties"], f"{path}.{key}", errors)

    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            validate(item, schema["items"], f"{path}[{i}]", errors)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: validate.py <schema.json> < document.json")
    with open(sys.argv[1]) as f:
        schema = json.load(f)
    try:
        document = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        sys.exit(f"invalid JSON on stdin: {exc}")

    errors = []
    validate(document, schema, "$", errors)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
