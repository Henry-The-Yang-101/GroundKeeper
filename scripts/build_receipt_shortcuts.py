"""Build reviewed receipt workflows from native Shortcuts action definitions.

Destinations remain import-time choices. No personal bookmarks or automations
are exported. Run sign_capture_shortcuts after generating these XML sources.
"""
import copy
from pathlib import Path
import plistlib
import uuid

ROOT = Path(__file__).resolve().parents[1] / "shortcuts/sources"


def token(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


def variable(name):
    return {"Type": "Variable", "VariableName": name}


def output(identifier, name="Result"):
    return {"Type": "ActionOutput", "OutputUUID": identifier, "OutputName": name}


def text(value):
    if isinstance(value, str):
        return {"Value": {"string": value}, "WFSerializationType": "WFTextTokenString"}
    return {"Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": value}}, "WFSerializationType": "WFTextTokenString"}


class Workflow:
    def __init__(self, name, template):
        self.name = name
        self.data = copy.deepcopy(template)
        self.actions = self.data["WFWorkflowActions"] = []
        self.data["WFWorkflowOutputContentItemClasses"] = ["WFDictionaryContentItem"]
        self.data["WFWorkflowTypes"] = []
        self.data.pop("WFWorkflowNoInputBehavior", None)

    def add(self, action, **params):
        identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, f"groundkeeper/{self.name}/{len(self.actions)}" )).upper()
        self.actions.append({"WFWorkflowActionIdentifier": "is.workflow.actions." + action,
                             "WFWorkflowActionParameters": {"UUID": identifier, **params}})
        return output(identifier)

    def setvar(self, name, value):
        self.add("setvariable", WFVariableName=name, WFInput=token(value))
        return variable(name)

    def get(self, dictionary, key):
        return self.add("getvalueforkey", WFInput=token(dictionary), WFDictionaryKey=key)

    def dictionary(self, values):
        fields = [{"WFItemType": 0, "WFKey": text(k), "WFValue": text(v)} for k, v in values.items()]
        return self.add("dictionary", WFItems={"Value": {"WFDictionaryFieldValueItems": fields}, "WFSerializationType": "WFDictionaryFieldValue"})

    def put(self, dictionary, key, value):
        return self.add("setvalueforkey", WFDictionary=token(dictionary), WFDictionaryKey=key,
                        WFDictionaryValue=token(value))

    def menu(self, prompt, items):
        group = str(uuid.uuid5(uuid.NAMESPACE_URL, f"groundkeeper/{self.name}/menu/{len(self.actions)}")).upper()
        self.add("choosefrommenu", WFMenuPrompt=text(prompt), WFMenuItems=items, GroupingIdentifier=group, WFControlFlowMode=0)
        return group

    def branch(self, group, title):
        self.add("choosefrommenu", WFMenuItemTitle=title, GroupingIdentifier=group, WFControlFlowMode=1)

    def endmenu(self, group):
        return self.add("choosefrommenu", GroupingIdentifier=group, WFControlFlowMode=2)

    def run(self, name, value):
        return self.add("runworkflow", WFWorkflowName=name, WFWorkflow={"isSelf": False, "workflowName": name}, WFInput=token(value))

    def save(self):
        (ROOT / (self.name + ".plist")).write_bytes(plistlib.dumps(self.data, sort_keys=False))


def main():
    writer_path = ROOT / "GroundKeeper Capture Transaction.plist"
    writer = plistlib.loads(writer_path.read_bytes())
    # Existing writer's first 20 actions establish a fresh ID and capture time.
    actions = writer["WFWorkflowActions"][:20]
    writer["WFWorkflowActions"] = actions
    envelope = output(actions[-1]["WFWorkflowActionParameters"]["UUID"], "Dictionary")
    w = Workflow("GroundKeeper Capture Transaction", writer)
    w.actions.extend(actions)
    saved = w.setvar("Saved Event", envelope)
    source = w.get(saved, "source")
    group = str(uuid.uuid5(uuid.NAMESPACE_URL, "groundkeeper/writer/receipt-schema")).upper()
    w.add("conditional", GroupingIdentifier=group, WFControlFlowMode=0, WFCondition=4,
          WFConditionalActionString="receipt_attachment", WFInput={"Type": "Variable", "Variable": token(source)})
    version = w.add("number", WFNumberActionNumber=3)
    updated = w.put(saved, "schema_version", version)
    w.setvar("Saved Event", updated)
    w.add("conditional", GroupingIdentifier=group, WFControlFlowMode=2)
    serialized = w.add("detect.text", WFInput=token(saved))
    filename = {"Value": {"string": "\ufffc.json", "attachmentsByRange": {"{0, 1}": variable("Event ID")}}, "WFSerializationType": "WFTextTokenString"}
    named = w.add("setitemname", WFInput=token(serialized), WFName=filename)
    w.add("documentpicker.save", WFAskWhereToSave=True, WFSaveFileOverwrite=False, WFInput=token(named))
    w.add("output", WFOutput=token(saved))
    w.save()

    wallet_path = ROOT / "GroundKeeper Wallet Automation.plist"
    wallet = plistlib.loads(wallet_path.read_bytes())
    wallet["WFWorkflowActions"] = wallet["WFWorkflowActions"][:2]
    first = wallet["WFWorkflowActions"][-1]["WFWorkflowActionParameters"]["UUID"]
    wallet["WFWorkflowActions"].append({"WFWorkflowActionIdentifier": "is.workflow.actions.runworkflow", "WFWorkflowActionParameters": {
        "UUID": str(uuid.uuid5(uuid.NAMESPACE_URL, "groundkeeper/wallet/add-receipt")).upper(),
        "WFWorkflowName": "GroundKeeper Add Receipt", "WFWorkflow": {"isSelf": False, "workflowName": "GroundKeeper Add Receipt"},
        "WFInput": token(output(first, "Shortcut Result"))}})
    wallet_path.write_bytes(plistlib.dumps(wallet, sort_keys=False))

    r = Workflow("GroundKeeper Add Receipt", writer)
    payment = r.setvar("Payment", r.add("detect.dictionary", WFInput=token({"Type": "ExtensionInput"})))
    # Only this explicit capture is targeted; do not search by amount or use a global last-payment variable.
    target = r.dictionary({key: r.get(payment, key) for key in ("source", "app", "event_id")})
    r.setvar("Receipt Target", target)
    menu = r.menu("Add a receipt for this payment? Your payment is already saved.", ["Skip", "Take photo", "Choose image"])
    r.branch(menu, "Skip")
    r.add("exit")
    r.branch(menu, "Take photo")
    photo = r.add("takephoto", WFPhotoCount=1, WFShowCamera=True, WFCameraDevice="Back")
    r.setvar("Receipt Photo", photo)
    r.branch(menu, "Choose image")
    photo = r.add("selectphotos", WFSelectMultiplePhotos=False)
    r.setvar("Receipt Photo", photo)
    r.endmenu(menu)
    recognized = r.run("GK Receipt OCR", variable("Receipt Photo"))
    r.setvar("Receipt Text", recognized)
    ocr = r.dictionary({"producer": "apple_shortcuts", "text": variable("Receipt Text")})
    payload = r.dictionary({})
    payload = r.put(payload, "ocr", ocr)
    r.setvar("Receipt Payload", payload)
    keep = r.menu("Keep a receipt image in iCloud and your Mac vault? Text alone is enough for classification.", ["Text only", "Keep image"])
    r.branch(keep, "Text only")
    r.add("nothing")
    r.branch(keep, "Keep image")
    converted = r.add("image.convert", WFInput=token(variable("Receipt Photo")), WFImageFormat="JPEG", WFImageCompressionQuality=0.85, WFImagePreserveMetadata=False)
    r.setvar("Receipt JPEG", converted)
    digest = r.add("hash", WFInput=token(converted), WFHashType="SHA256")
    name = {"Value": {"string": "\ufffc.jpg", "attachmentsByRange": {"{0, 1}": digest}}, "WFSerializationType": "WFTextTokenString"}
    image = r.add("setitemname", WFInput=token(variable("Receipt JPEG")), WFName=name)
    r.add("documentpicker.save", WFInput=token(image), WFAskWhereToSave=True, WFSaveFileOverwrite=False)
    path = {"Value": {"string": "assets/\ufffc.jpg", "attachmentsByRange": {"{7, 1}": digest}}, "WFSerializationType": "WFTextTokenString"}
    image_metadata = r.dictionary({})
    path_value = r.add("gettext", WFTextActionText=path)
    image_metadata = r.put(image_metadata, "path", path_value)
    # Mac hashes the actual file bytes; Shortcuts' Hash output is used only as an opaque filename.
    payload = r.put(variable("Receipt Payload"), "image", image_metadata)
    r.setvar("Receipt Payload", payload)
    r.endmenu(keep)
    event = r.dictionary({"source": "receipt_attachment", "app": "Shortcuts"})
    event = r.put(event, "target", variable("Receipt Target"))
    event = r.put(event, "receipt", variable("Receipt Payload"))
    result = r.run("GroundKeeper Capture Transaction", event)
    r.add("output", WFOutput=token(result))
    r.save()

    later = Workflow("GroundKeeper Attach Receipt Later", writer)
    selected = later.add("documentpicker.open", WFSelectMultiple=False)
    payment = later.add("detect.dictionary", WFInput=token(selected))
    later.run("GroundKeeper Add Receipt", payment)
    later.save()


if __name__ == "__main__":
    main()
