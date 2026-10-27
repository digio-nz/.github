#!/usr/bin/env python3
"""Fail when an input default of an action.yml holds a ${{ }} expression.

GitHub evaluates no vars or secrets context in an action's input default, so
such an action fails at setup. The workflow passes the value with `with:`.
Usage: python3 -I action-defaults.py <action.yml>...
Exit: 0 clean, 1 a default holds an expression or a key repeats, 2 bad input.
"""
import sys

try:
    import yaml
except ImportError:
    print("action-defaults: PyYAML is not installed, so no action.yml can be checked", file=sys.stderr)
    sys.exit(2)


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node, deep=False):
    keys = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in keys:
            raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key!r}", key_node.start_mark)
        keys.add(key)
    return loader.construct_mapping(node, deep)


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def main(paths):
    if not paths:
        print("action-defaults: usage: action-defaults.py <action.yml>...", file=sys.stderr)
        return 2
    found = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                action = yaml.load(handle, Loader=UniqueKeyLoader)
        except OSError as error:
            print(f"action-defaults: {path}: {error.strerror}", file=sys.stderr)
            return 2
        except yaml.constructor.ConstructorError as error:
            found.append(f"{path}: {error.problem} at line {error.problem_mark.line + 1}")
            continue
        except yaml.YAMLError as error:
            print(f"action-defaults: {path}: not YAML: {error}", file=sys.stderr)
            return 2
        inputs = action.get("inputs") if isinstance(action, dict) else None
        if inputs is None:
            continue
        if not isinstance(inputs, dict):
            print(f"action-defaults: {path}: inputs is not a mapping", file=sys.stderr)
            return 2
        for name, spec in inputs.items():
            default = spec.get("default") if isinstance(spec, dict) else None
            if isinstance(default, str) and "${{" in default:
                found.append(f"{path}: inputs.{name}.default holds an expression: {default!r}")
    for line in found:
        print(line, file=sys.stderr)
    if found:
        print("action-defaults: an action input default holds an expression. Pass the value from the workflow with `with:`.", file=sys.stderr)
        return 1
    print("action-defaults: no action input default holds an expression. OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
