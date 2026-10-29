import copy
from pathlib import Path

import yaml


def workflow(path):
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def check(discipline, reusable):
    events = discipline["on"]["pull_request"]
    assert "paths" not in events and "paths-ignore" not in events, "Discipline must label every changed path"
    assert set(["opened", "synchronize", "edited", "reopened", "ready_for_review", "labeled"]).issubset(events["types"]), "Discipline must handle drafts and legacy label writes"
    labels = discipline["jobs"]["labels"]
    assert "needs" not in labels, "Labelling must not depend on a gate passing"
    assert "draft" not in labels["if"] and "github.repository !=" not in labels["if"], "Labelling must include drafts and the workflow repository"
    assert "workflow_call" in reusable["on"], "Factory repositories need a reusable labelling workflow"
    for job in [labels, reusable["jobs"]["labels"]]:
        assert job["runs-on"] == "${{ vars.PROCESS_HOSTED_RUNNER || 'ubuntu-latest' }}", "Labelling with an App key must use a hosted runner"
        assert any(step.get("uses", "").endswith("/pr-labels-apply@main") for step in job["steps"]), "The labelling job must call pr-labeller"
    return True


root = Path(__file__).resolve().parents[2]
discipline = workflow(root / "workflows/discipline.yml")
reusable = workflow(root / "workflows/label-pr.yml")
check(discipline, reusable)
mutations = [
    lambda d, r: d["on"]["pull_request"].update(paths=["src/**"]),
    lambda d, r: d["on"]["pull_request"]["types"].remove("labeled"),
    lambda d, r: d["jobs"]["labels"].update(needs="discipline"),
    lambda d, r: d["jobs"]["labels"].update({"if": "!github.event.pull_request.draft"}),
    lambda d, r: r["on"].pop("workflow_call"),
    lambda d, r: d["jobs"]["labels"].update(steps=[]),
]
for mutate in mutations:
    d, r = copy.deepcopy(discipline), copy.deepcopy(reusable)
    mutate(d, r)
    try:
        check(d, r)
    except AssertionError:
        continue
    raise AssertionError("Coverage guard accepted a known broken workflow")
print(f"label coverage: shipped workflows pass; {len(mutations)} broken workflows fail")
