"""Compare bounded JSON Schema samples with the real Haskell answer decoder."""

import json
import sys

from jsonschema import Draft202012Validator


def main():
    with open(sys.argv[1], encoding="utf-8") as source:
        vectors = json.load(source)
    assert vectors, "no answer-schema vectors supplied"
    for vector in vectors:
        Draft202012Validator.check_schema(vector["schema"])
        accepted = Draft202012Validator(vector["schema"]).is_valid(vector["value"])
        assert accepted == vector["accepted"], vector["label"]
    print(f"answer schema probe: {len(vectors)} bounded schema/decoder comparisons passed")


if __name__ == "__main__":
    main()
