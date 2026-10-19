"""Portable checks for distributable, device-independent capture workflows."""
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1] / "shortcuts" / "sources"


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def test_capture_sources_have_no_device_permissions_or_trigger_selections():
    sources = list(ROOT.glob("*.plist"))
    assert len(sources) == 3
    for path in sources:
        workflow = plistlib.loads(path.read_bytes())
        assert "WFWorkflowTriggers" not in workflow
        seen = set()
        for action in workflow["WFWorkflowActions"]:
            for value in walk(action):
                assert not ({"WFFolder", "TriggerIdentifier", "workflowIdentifier", "BookmarkData"} & value.keys())
                assert value.get("Type") != "TriggerOutput"
                if "OutputUUID" in value:
                    assert value["OutputUUID"] in seen, f"Forward/broken variable reference in {path.name}"
            identifier = action["WFWorkflowActionParameters"].get("UUID")
            if identifier:
                seen.add(identifier)


def test_writer_prompts_for_receiving_users_folder_and_preserves_unique_filenames():
    workflow = plistlib.loads((ROOT / "GroundKeeper Capture Transaction.plist").read_bytes())
    actions = workflow["WFWorkflowActions"]
    assert actions[-1]["WFWorkflowActionIdentifier"] == "is.workflow.actions.documentpicker.save"
    assert actions[-1]["WFWorkflowActionParameters"]["WFAskWhereToSave"] is True
    assert actions[-2]["WFWorkflowActionParameters"]["WFName"]["Value"]["string"].endswith(".json")
    assert len([a for a in actions if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.number.random"]) == 2
    keys = {a["WFWorkflowActionParameters"].get("WFDictionaryKey") for a in actions}
    assert {"schema_version", "event_id", "captured_at", "input_shape"} <= keys
