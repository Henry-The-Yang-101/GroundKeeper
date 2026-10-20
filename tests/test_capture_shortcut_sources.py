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
    assert len(sources) >= 7
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
    assert actions[-1]["WFWorkflowActionIdentifier"] == "is.workflow.actions.output"
    save = next(i for i, action in enumerate(actions) if action["WFWorkflowActionIdentifier"] == "is.workflow.actions.documentpicker.save")
    assert actions[save]["WFWorkflowActionParameters"]["WFAskWhereToSave"] is True
    assert actions[save-1]["WFWorkflowActionParameters"]["WFName"]["Value"]["string"].endswith(".json")
    assert len([a for a in actions if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.number.random"]) == 2
    keys = {a["WFWorkflowActionParameters"].get("WFDictionaryKey") for a in actions}
    assert {"schema_version", "event_id", "captured_at", "input_shape"} <= keys


def test_wallet_saves_before_optional_receipt_and_ocr_uses_native_action():
    wallet = plistlib.loads((ROOT / "GroundKeeper Wallet Automation.plist").read_bytes())
    names = [a["WFWorkflowActionParameters"].get("WFWorkflowName") for a in wallet["WFWorkflowActions"]]
    assert names[-2:] == ["GroundKeeper Capture Transaction", "GroundKeeper Add Receipt"]
    ocr = plistlib.loads((ROOT / "GK Receipt OCR.plist").read_bytes())
    assert ocr["WFWorkflowActions"][0]["WFWorkflowActionIdentifier"] == "is.workflow.actions.extracttextfromimage"
    receipt = plistlib.loads((ROOT / "GroundKeeper Add Receipt.plist").read_bytes())
    actions = receipt["WFWorkflowActions"]
    assert any(a["WFWorkflowActionParameters"].get("WFMenuItems") == ["Text only", "Keep image"] for a in actions)
    assert any(a["WFWorkflowActionParameters"].get("WFDictionaryKey") == "target" for a in actions)
