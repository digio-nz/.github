import copy
from pathlib import Path

import yaml

TYPES = {"opened", "synchronize", "reopened", "ready_for_review", "edited"}


def check(workflow):
    events = workflow["on"]
    pull_request = events["pull_request"]
    assert "paths" not in pull_request and "paths-ignore" not in pull_request, "Discipline must run for every changed path"
    missing = TYPES - set(pull_request["types"])
    assert not missing, f"Discipline must run on these pull request types: {sorted(missing)}"
    assert "merge_group" in events, "Discipline must run on merge groups"
    assert workflow["permissions"].get("pull-requests") == "write", "The sticky comment needs pull-requests: write"


root = Path(__file__).resolve().parents[2]
discipline = yaml.load((root / "workflows/discipline.yml").read_text(), Loader=yaml.BaseLoader)
check(discipline)
mutations = [
    lambda w: w["on"]["pull_request"].update(paths=["src/**"]),
    lambda w: w["on"]["pull_request"].update({"paths-ignore": ["docs/**"]}),
    lambda w: w["on"]["pull_request"]["types"].remove("edited"),
    lambda w: w["on"]["pull_request"]["types"].remove("ready_for_review"),
    lambda w: w["on"].pop("merge_group"),
    lambda w: w["permissions"].update({"pull-requests": "read"}),
]
for mutate in mutations:
    broken = copy.deepcopy(discipline)
    mutate(broken)
    try:
        check(broken)
    except AssertionError:
        continue
    raise AssertionError("The trigger guard accepted a known broken workflow")
print(f"trigger selftest: discipline.yml passes; {len(mutations)} broken workflows fail")
