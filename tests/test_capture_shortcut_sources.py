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
    save = max(i for i, action in enumerate(actions) if action["WFWorkflowActionIdentifier"] == "is.workflow.actions.documentpicker.save")
    assert actions[save]["WFWorkflowActionParameters"]["WFAskWhereToSave"] is True
    assert actions[save-1]["WFWorkflowActionParameters"]["WFName"]["Value"]["string"].endswith(".json")
    assert len([a for a in actions if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.number.random"]) == 2
    keys = {a["WFWorkflowActionParameters"].get("WFDictionaryKey") for a in actions}
    assert {"schema_version", "event_id", "captured_at", "input_shape"} <= keys


def test_adapters_use_one_writer_and_receipts_remain_optional():
    for name in ("Wallet", "CIBC"):
        workflow = plistlib.loads((ROOT / f"GroundKeeper {name} Automation.plist").read_bytes())
        calls = [a["WFWorkflowActionParameters"]["WFWorkflowName"] for a in workflow["WFWorkflowActions"] if a["WFWorkflowActionIdentifier"].endswith(".runworkflow")]
        assert calls == ["GroundKeeper Capture Transaction"]
    ocr = plistlib.loads((ROOT / "GK Receipt OCR.plist").read_bytes())
    assert ocr["WFWorkflowActions"][0]["WFWorkflowActionIdentifier"] == "is.workflow.actions.extracttextfromimage"
    actions = plistlib.loads((ROOT / "GroundKeeper Capture Transaction.plist").read_bytes())["WFWorkflowActions"]
    menus = [a["WFWorkflowActionParameters"].get("WFMenuItems") for a in actions]
    assert ["Add receipt", "Add note", "Skip adding receipt"] in menus
    assert ["Add note", "Save transaction"] in menus
    assert ["Add receipt", "Skip adding receipt"] in menus
    assert ["Text only", "Keep image"] in menus
    assert not any("and note" in choice.lower() for menu in menus if menu for choice in menu)
    # No save can execute before the final optional-details menu ends.
    last_menu = max(i for i, a in enumerate(actions) if a["WFWorkflowActionIdentifier"].endswith(".choosefrommenu"))
    saves = [i for i, a in enumerate(actions) if a["WFWorkflowActionIdentifier"].endswith(".documentpicker.save")]
    assert len(saves) == 2  # Optional image, then one combined capture JSON.
    assert min(saves) > last_menu
    assert saves[-1] == len(actions) - 5
    # Cancellation/no-output guards stop before the final JSON write.
    guards = [a["WFWorkflowActionParameters"] for a in actions[:saves[-1]] if a["WFWorkflowActionIdentifier"].endswith(".conditional")]
    assert sum(g.get("WFCondition") == 101 for g in guards) >= 10


def test_filename_structure_and_safe_components():
    import re
    actions = plistlib.loads((ROOT / "GroundKeeper Capture Transaction.plist").read_bytes())["WFWorkflowActions"]
    filename = next(a["WFWorkflowActionParameters"]["WFName"]["Value"] for a in reversed(actions) if a["WFWorkflowActionIdentifier"].endswith(".setitemname"))
    assert filename["string"] == "\ufffc_\ufffc_CAPTURE_\ufffc.json"
    assert [v.get("VariableName") for v in list(filename["attachmentsByRange"].values())[:2]] == ["Filename Description", "Filename App"]
    replacements = [a["WFWorkflowActionParameters"] for a in actions if a["WFWorkflowActionIdentifier"].endswith(".text.replace")]
    safe = next(p for p in replacements if p["WFReplaceTextFind"] == "[^A-Za-z0-9_-]")
    for description in ("Coffee Shop", "Store / Online: Order", "A\nB\tC", "../Cafe", "🦊 café"):
        result = re.sub(safe["WFReplaceTextFind"], safe["WFReplaceTextReplace"], description)
        assert re.fullmatch(r"[A-Za-z0-9_-]+", result)
    assert any(a["WFWorkflowActionParameters"].get("WFDateFormat") == "yyyy-MM-dd_HH-mm-ss-SSS" for a in actions)


def test_generator_is_repeatable(tmp_path, monkeypatch):
    import importlib.util
    import shutil
    spec = importlib.util.spec_from_file_location("capture_builder", ROOT.parents[1] / "scripts/build_receipt_shortcuts.py")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    for path in ROOT.glob("*.plist"):
        shutil.copy(path, tmp_path / path.name)
    monkeypatch.setattr(builder, "ROOT", tmp_path)
    builder.main()
    first = {p.name: p.read_bytes() for p in tmp_path.glob("*.plist")}
    builder.main()
    assert first == {p.name: p.read_bytes() for p in tmp_path.glob("*.plist")}
    assert first == {p.name: p.read_bytes() for p in ROOT.glob("*.plist")}


def test_dynamic_text_parameters_use_native_text_token_serialization():
    # Attachment tokens import without an error but render blank in these fields.
    for path in ROOT.glob("*.plist"):
        for action in plistlib.loads(path.read_bytes())["WFWorkflowActions"]:
            params = action["WFWorkflowActionParameters"]
            for key in ("WFDictionaryValue", "WFOutput"):
                value = params.get(key)
                if isinstance(value, dict):
                    assert value["WFSerializationType"] == "WFTextTokenString", (path.name, key)


def test_native_replace_and_match_use_text_token_fields():
    for path in ROOT.glob("*.plist"):
        for action in plistlib.loads(path.read_bytes())["WFWorkflowActions"]:
            params = action["WFWorkflowActionParameters"]
            if action["WFWorkflowActionIdentifier"].endswith(".text.replace"):
                assert params["WFInput"]["WFSerializationType"] == "WFTextTokenString"
            if action["WFWorkflowActionIdentifier"].endswith(".text.match"):
                assert params["text"]["WFSerializationType"] == "WFTextTokenString"


def test_success_notification_requires_saved_result_and_description():
    for kind, key in (("Wallet", "merchant"), ("CIBC", "subtitle")):
        name = f"GroundKeeper {kind} Automation"
        actions = plistlib.loads((ROOT / (name + ".plist")).read_bytes())["WFWorkflowActions"]
        notifications = [i for i, a in enumerate(actions) if a["WFWorkflowActionIdentifier"].endswith(".notification")]
        assert len(notifications) == 1
        index = notifications[0]
        params = actions[index]["WFWorkflowActionParameters"]
        assert params["WFNotificationActionTitle"]["Value"]["string"] == name
        assert params["WFNotificationActionBody"]["Value"]["string"] == "Successfully captured and saved \ufffc!"
        assert actions[index-2]["WFWorkflowActionParameters"]["WFDictionaryKey"] == key
        # All three success guards surround the notification; empty returns,
        # missing IDs and missing descriptions cannot fall through to it.
        guards = [a["WFWorkflowActionParameters"] for a in actions[2:index] if a["WFWorkflowActionIdentifier"].endswith(".conditional")]
        assert len(guards) == 3
        assert all(g["WFControlFlowMode"] == 0 and g["WFCondition"] == 100 for g in guards)
        assert [a["WFWorkflowActionParameters"]["GroupingIdentifier"] for a in actions[index+1:]] == [g["GroupingIdentifier"] for g in reversed(guards)]
    writer = plistlib.loads((ROOT / "GroundKeeper Capture Transaction.plist").read_bytes())["WFWorkflowActions"]
    save, guard, stop, end, result = writer[-5:]
    assert save["WFWorkflowActionIdentifier"].endswith(".documentpicker.save")
    assert guard["WFWorkflowActionParameters"]["WFCondition"] == 101
    assert guard["WFWorkflowActionParameters"]["WFInput"]["Variable"]["Value"]["OutputUUID"] == save["WFWorkflowActionParameters"]["UUID"]
    assert stop["WFWorkflowActionIdentifier"].endswith(".exit")
    assert result["WFWorkflowActionIdentifier"].endswith(".output")


def test_wallet_category_slot_does_not_guess_an_unsupported_property():
    workflow = plistlib.loads((ROOT / "GroundKeeper Wallet Automation.plist").read_bytes())
    fields = workflow["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["WFItems"]["Value"]["WFDictionaryFieldValueItems"]
    category = next(f for f in fields if f["WFKey"]["Value"]["string"] == "wallet_category_raw")
    assert category["WFValue"]["Value"] == {"string": ""}
    assert not any(value.get("PropertyName") == "Category" for value in walk(workflow))
    for name in ("GK Categorize Cloud", "GK Categorize On-Device"):
        workflow = plistlib.loads((ROOT / (name + ".plist")).read_bytes())
        assert "wallet_category_raw is an untrusted" in str(workflow)
