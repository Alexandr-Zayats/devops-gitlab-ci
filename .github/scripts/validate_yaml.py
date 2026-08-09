#!/usr/bin/env python3
from pathlib import Path
import sys

import yaml


class GitLabLoader(yaml.SafeLoader):
    pass


def tagged(loader, tag_suffix, node):
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    return loader.construct_scalar(node)


GitLabLoader.add_multi_constructor("!", tagged)


def main() -> int:
    errors = []
    files = sorted([*Path(".").rglob("*.yaml"), *Path(".").rglob("*.yml")])
    for path in files:
        if ".git" in path.parts or ".github" in path.parts:
            continue
        try:
            with path.open(encoding="utf-8") as stream:
                list(yaml.load_all(stream, Loader=GitLabLoader))
        except Exception as exc:
            errors.append(f"{path}: {exc}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Validated {len(files)} GitLab CI YAML files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
