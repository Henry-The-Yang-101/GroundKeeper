"""Build reviewed receipt workflows from native Shortcuts action definitions.

Destinations remain import-time choices. No personal bookmarks or automations
are exported. Run sign_capture_shortcuts after generating these XML sources.
"""

import copy
import plistlib
import uuid
from pathlib import Path

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
    return {
        "Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": value}},
        "WFSerializationType": "WFTextTokenString",
    }


class Workflow:
    def __init__(self, name, template):
        self.name = name
        self.data = copy.deepcopy(template)
        self.actions = self.data["WFWorkflowActions"] = []
        self.data["WFWorkflowOutputContentItemClasses"] = ["WFDictionaryContentItem"]
        self.data["WFWorkflowTypes"] = []
        self.data.pop("WFWorkflowNoInputBehavior", None)

    def add(self, action, **params):
        identifier = str(
            uuid.uuid5(uuid.NAMESPACE_URL, f"groundkeeper/{self.name}/{len(self.actions)}")
        ).upper()
        self.actions.append(
            {
                "WFWorkflowActionIdentifier": "is.workflow.actions." + action,
                "WFWorkflowActionParameters": {"UUID": identifier, **params},
            }
        )
        return output(identifier)

    def setvar(self, name, value):
        self.add("setvariable", WFVariableName=name, WFInput=token(value))
        return variable(name)

    def get(self, dictionary, key):
        return self.add("getvalueforkey", WFInput=token(dictionary), WFDictionaryKey=key)

    def dictionary(self, values, *, numbers=()):
        fields = [
            {"WFItemType": 3 if k in numbers else 0, "WFKey": text(k), "WFValue": text(v)}
            for k, v in values.items()
        ]
        return self.add(
            "dictionary",
            WFItems={
                "Value": {"WFDictionaryFieldValueItems": fields},
                "WFSerializationType": "WFDictionaryFieldValue",
            },
        )

    def put(self, dictionary, key, value):
        return self.add(
            "setvalueforkey",
            WFDictionary=token(dictionary),
            WFDictionaryKey=key,
            WFDictionaryValue=text(value),
        )

    def menu(self, prompt, items):
        group = str(
            uuid.uuid5(uuid.NAMESPACE_URL, f"groundkeeper/{self.name}/menu/{len(self.actions)}")
        ).upper()
        self.add(
            "choosefrommenu",
            WFMenuPrompt=text(prompt),
            WFMenuItems=items,
            GroupingIdentifier=group,
            WFControlFlowMode=0,
        )
        return group

    def branch(self, group, title):
        self.add(
            "choosefrommenu", WFMenuItemTitle=title, GroupingIdentifier=group, WFControlFlowMode=1
        )

    def endmenu(self, group):
        return self.add("choosefrommenu", GroupingIdentifier=group, WFControlFlowMode=2)

    def run(self, name, value):
        return self.add(
            "runworkflow",
            WFWorkflowName=name,
            WFWorkflow={"isSelf": False, "workflowName": name},
            WFInput=token(value),
        )

    def save(self):
        (ROOT / (self.name + ".plist")).write_bytes(plistlib.dumps(self.data, sort_keys=False))


def formatted(*parts):
    string, attachments = "", {}
    for part in parts:
        if isinstance(part, str):
            string += part
        else:
            attachments[f"{{{len(string)}, 1}}"] = part
            string += "\ufffc"
    return {
        "Value": {"string": string, "attachmentsByRange": attachments},
        "WFSerializationType": "WFTextTokenString",
    }


def condition(w, value, code=100, equals=None):
    group = str(
        uuid.uuid5(uuid.NAMESPACE_URL, f"groundkeeper/{w.name}/if/{len(w.actions)}")
    ).upper()
    value = copy.deepcopy(value)
    value["Aggrandizements"] = [
        {"CoercionItemClass": "WFStringContentItem", "Type": "WFCoercionVariableAggrandizement"}
    ]
    params = dict(
        GroupingIdentifier=group,
        WFControlFlowMode=0,
        WFCondition=code,
        WFInput={"Type": "Variable", "Variable": token(value)},
    )
    if equals is not None:
        params["WFConditionalActionString"] = equals
    w.add("conditional", **params)
    return group


def endif(w, group):
    w.add("conditional", GroupingIdentifier=group, WFControlFlowMode=2)


def require(w, value, message):
    # Does not have any value. Cancellation/no output must never fall through to Save File.
    group = condition(w, value, 101)
    w.add(
        "alert",
        WFAlertActionTitle="Capture not saved",
        WFAlertActionMessage=message,
        WFAlertActionCancelButtonShown=False,
    )
    w.add("exit")
    endif(w, group)


def replace(w, value, pattern, replacement):
    return w.add(
        "text.replace",
        WFInput=text(value),
        WFReplaceTextFind=pattern,
        WFReplaceTextReplace=replacement,
        WFReplaceTextRegularExpression=True,
        WFReplaceTextCaseSensitive=True,
    )


def bounded(w, value, maximum, message):
    # Bound Unicode characters conservatively; the serialized envelope check
    # also accounts for JSON escaping. Reject overlong input without truncation.
    matched = w.add("text.match", text=text(value), WFMatchTextPattern=f"(?s)^.{{1,{maximum}}}$")
    require(w, matched, message)


def add_note(w):
    note = w.add("ask", WFInputType="Text", WFAskActionPrompt="What was this transaction for?")
    note = replace(w, note, r"^\s+|\s+$", "")
    require(w, note, "Enter a note, or cancel and run the capture again to skip it.")
    bounded(w, note, 2000, "Use a note of at most 2,000 characters.")
    w.setvar("Saved Event", w.put(variable("Saved Event"), "note", note))


def collect_receipt(w):
    menu = w.menu("Add a receipt", ["Take photo", "Choose image"])
    w.branch(menu, "Take photo")
    photo = w.add("takephoto", WFPhotoCount=1, WFShowCamera=True, WFCameraDevice="Back")
    w.setvar("Receipt Photo", photo)
    w.branch(menu, "Choose image")
    photo = w.add("selectphotos", WFSelectMultiplePhotos=False)
    w.setvar("Receipt Photo", photo)
    w.endmenu(menu)
    require(w, variable("Receipt Photo"), "No receipt image was selected.")
    recognized = w.run("GK Receipt OCR", variable("Receipt Photo"))
    w.setvar("Receipt Text", recognized)
    has_text = condition(w, variable("Receipt Text"))
    bounded(w, variable("Receipt Text"), 8000, "The recognized receipt text is too long.")
    endif(w, has_text)
    payload = w.put(
        w.dictionary({}),
        "ocr",
        w.dictionary({"producer": "apple_shortcuts", "text": variable("Receipt Text")}),
    )
    w.setvar("Receipt Payload", payload)
    keep = w.menu("Keep the receipt image too?", ["Text only", "Keep image"])
    w.branch(keep, "Text only")
    nonblank = replace(w, variable("Receipt Text"), r"^\s+|\s+$", "")
    require(w, nonblank, "No text was recognized. Run again and choose Keep image.")
    w.branch(keep, "Keep image")
    converted = w.add(
        "image.convert",
        WFInput=token(variable("Receipt Photo")),
        WFImageFormat="JPEG",
        WFImageCompressionQuality=0.85,
        WFImagePreserveMetadata=False,
    )
    require(w, converted, "The receipt could not be converted to JPEG.")
    w.setvar("Receipt JPEG", converted)
    digest = w.add("hash", WFInput=token(converted), WFHashType="SHA256")
    w.setvar("Receipt Filename", w.add("gettext", WFTextActionText=formatted(digest, ".jpg")))
    path = w.add("gettext", WFTextActionText=formatted("assets/", digest, ".jpg"))
    payload = w.put(variable("Receipt Payload"), "image", w.dictionary({"path": path}))
    w.setvar("Receipt Payload", payload)
    w.endmenu(keep)
    # No disk writes here: even the image waits until all later menus finish.
    w.setvar("Saved Event", w.put(variable("Saved Event"), "receipt", variable("Receipt Payload")))


def optional_details(w):
    menu = w.menu(
        "Add details to this transaction", ["Add receipt", "Add note", "Skip adding receipt"]
    )
    w.branch(menu, "Add receipt")
    collect_receipt(w)
    more = w.menu("Receipt added. Add a note?", ["Add note", "Save transaction"])
    w.branch(more, "Add note")
    add_note(w)
    w.branch(more, "Save transaction")
    w.add("nothing")
    w.endmenu(more)
    w.branch(menu, "Add note")
    add_note(w)
    more = w.menu("Note added. Add a receipt?", ["Add receipt", "Skip adding receipt"])
    w.branch(more, "Add receipt")
    collect_receipt(w)
    w.branch(more, "Skip adding receipt")
    w.add("nothing")
    w.endmenu(more)
    w.branch(menu, "Skip adding receipt")
    w.add("nothing")
    w.endmenu(menu)


def transaction_context(workflow):
    """Add display-only context without changing existing actions or saved data.

    The separate workflow namespace preserves existing action UUIDs, including
    those in installed writers with personal Save File destinations.
    """
    context = Workflow("GroundKeeper Transaction Context", workflow)
    saved = variable("Saved Event")
    source = context.get(saved, "source")
    wallet = condition(context, source, 4, "wallet_transaction")
    amount = context.get(saved, "amount")
    card = context.get(saved, "card_or_pass")
    summary = context.add(
        "gettext",
        WFTextActionText=formatted(
            variable("Capture Description"),
            "\nAmount: ",
            amount,
            "\n",
            variable("Capture App"),
            "\n",
            card,
        ),
    )
    context.setvar("Transaction Context", summary)
    context.add("conditional", GroupingIdentifier=wallet, WFControlFlowMode=1)
    title = context.get(saved, "title")
    body = context.get(saved, "body")
    # Keep the bank's original amount/currency wording instead of guessing at
    # notification formats or accidentally picking a card suffix as the amount.
    summary = context.add(
        "gettext",
        WFTextActionText=formatted(
            variable("Capture Description"), "\n", body, "\n", variable("Capture App"), "\n", title
        ),
    )
    context.setvar("Transaction Context", summary)
    endif(context, wallet)

    actions = workflow["WFWorkflowActions"]
    first_menu = next(
        i
        for i, action in enumerate(actions)
        if action["WFWorkflowActionIdentifier"].endswith(".choosefrommenu")
    )
    actions[first_menu:first_menu] = context.actions
    for action in actions[first_menu + len(context.actions) :]:
        params = action["WFWorkflowActionParameters"]
        for key in ("WFMenuPrompt", "WFAskActionPrompt"):
            if key in params:
                prompt = params[key]
                if isinstance(prompt, dict):
                    prompt = prompt["Value"]["string"]
                params[key] = formatted(variable("Transaction Context"), "\n\n", prompt)


def location_capture(workflow):
    """Sample once before interactive details, preserving existing action IDs.

    The native action can stop Shortcuts on permission/GPS errors; Shortcuts has
    no catch action. The adapter's capture_location=off setting bypasses it.
    A returned empty sample falls through with an explicit unavailable status.
    """
    w = Workflow("GroundKeeper Location Capture", workflow)
    saved = variable("Saved Event")
    setting = w.get(saved, "capture_location")
    w.setvar("Saved Event", w.put(saved, "location_status", "not_requested"))
    disabled = condition(w, setting, 4, "off")
    w.add("nothing")
    w.add("conditional", GroupingIdentifier=disabled, WFControlFlowMode=1)
    w.setvar("Saved Event", w.put(saved, "location_status", "unavailable"))
    sample = w.add("getcurrentlocation")
    available = condition(w, sample)
    acquired = w.add("date")
    measured = w.add(
        "format.date",
        WFDate=text(acquired),
        WFDateFormatStyle="ISO 8601",
        WFISO8601IncludeTime=True,
    )
    latitude = w.add(
        "properties.locations", WFInput=token(sample), WFContentItemPropertyName="Latitude"
    )
    longitude = w.add(
        "properties.locations", WFInput=token(sample), WFContentItemPropertyName="Longitude"
    )
    location = w.dictionary(
        {"latitude": latitude, "longitude": longitude, "measured_at": measured},
        numbers=("latitude", "longitude"),
    )
    w.setvar("Saved Event", w.put(saved, "location", location))
    w.setvar("Saved Event", w.put(saved, "location_status", "available"))
    endif(w, available)
    endif(w, disabled)

    actions = workflow["WFWorkflowActions"]
    first_menu = next(
        i
        for i, action in enumerate(actions)
        if action["WFWorkflowActionIdentifier"].endswith(".choosefrommenu")
    )
    actions[first_menu:first_menu] = w.actions


def wallet_priority(workflow, *, captured_date=None, captured_seconds=None):
    """Reserve a matching payment for Wallet before GPS or interactive menus.

    Storage is scoped to this shared writer, so simultaneous adapter runs see
    the same marker. Keep at most 256 slots, storing the full hash as well so a
    slot collision can only miss a duplicate, never suppress a different one.
    Missing/unrecognized evidence falls through to the ordinary capture flow.
    """
    w = Workflow("GroundKeeper Wallet Priority", workflow)
    if captured_seconds is None:
        captured_date = captured_date or w.add("date")
        # Keep the original native Date. Coercing two ISO 8601 strings through
        # Get Time Between Dates can silently drop their times and return zero.
        captured_seconds = w.add(
            "gettimebetweendates",
            WFInput=text(captured_date),
            WFTimeUntilFromDate="January 1, 2001",
            WFTimeUntilUnit="Seconds",
        )
    w.setvar("Priority Captured Seconds", captured_seconds)
    saved = variable("Saved Event")
    source = w.get(saved, "source")
    wallet = condition(w, source, 4, "wallet_transaction")
    w.setvar("Priority Merchant", w.get(saved, "merchant"))
    w.setvar("Priority Amount", w.get(saved, "amount"))
    w.add("conditional", GroupingIdentifier=wallet, WFControlFlowMode=1)
    w.setvar("Priority Merchant", w.get(saved, "subtitle"))
    w.setvar("Priority Amount", w.get(saved, "body"))
    endif(w, wallet)

    # Currency and group are matching hints only; never rewrite capture fields.
    currency = w.setvar("Priority Currency", w.get(saved, "wallet_priority_currency"))
    missing = condition(w, currency, 101)
    w.setvar("Priority Currency", w.add("gettext", WFTextActionText=text("CAD")))
    endif(w, missing)
    group = w.setvar("Priority Group", w.get(saved, "wallet_priority_group"))
    missing = condition(w, group, 101)
    w.setvar("Priority Group", w.add("gettext", WFTextActionText=text("default")))
    endif(w, missing)

    # Accept only a complete positive purchase amount, like the Mac parser.
    # A narrative, refund, decline or card suffix must never become an amount.
    amount = replace(w, variable("Priority Amount"), r"^\s+|\s+$", "")
    money = w.add(
        "text.match",
        text=text(amount),
        WFMatchTextPattern=r"(?i)^(?:(?:CAD|USD|EUR|GBP)\s*|[$€£]\s*)?"
        r"(?:[0-9]{1,13}|[0-9]{1,3}(?:,[0-9]{3}){1,4})"
        r"(?:\.[0-9]{1,2})?(?:\s*(?:CAD|USD|EUR|GBP))?$",
    )
    valid_money = condition(w, money)
    explicit = w.add("text.match", text=text(amount), WFMatchTextPattern=r"(?i)CAD|USD|EUR|GBP")
    has_code = condition(w, explicit)
    w.setvar("Priority Currency", explicit)
    w.add("conditional", GroupingIdentifier=has_code, WFControlFlowMode=1)
    for symbol, code in (("€", "EUR"), ("£", "GBP")):
        found = w.add("text.match", text=text(amount), WFMatchTextPattern=symbol)
        has_symbol = condition(w, found)
        w.setvar("Priority Currency", w.add("gettext", WFTextActionText=text(code)))
        endif(w, has_symbol)
    endif(w, has_code)
    currency = replace(w, variable("Priority Currency"), r"^\s+|\s+$", "")
    currency = w.add("text.changecase", text=text(currency), WFCaseType="UPPERCASE")
    valid_currency = w.add(
        "text.match", text=text(currency), WFMatchTextPattern=r"^(?:CAD|USD|EUR|GBP)$"
    )
    # A dollar sign cannot safely stand for EUR/GBP, even with a manual hint.
    dollar = w.add("text.match", text=text(amount), WFMatchTextPattern=r"\$")
    has_dollar = condition(w, dollar)
    dollar_currency = w.add("text.match", text=text(currency), WFMatchTextPattern=r"^(?:CAD|USD)$")
    w.setvar("Priority Currency Valid", dollar_currency)
    w.add("conditional", GroupingIdentifier=has_dollar, WFControlFlowMode=1)
    w.setvar("Priority Currency Valid", valid_currency)
    endif(w, has_dollar)
    valid_currency = condition(w, variable("Priority Currency Valid"))

    minor = replace(w, amount, r"[A-Za-z$€£,\s]", "")
    minor = replace(w, minor, r"^([0-9]+)$", "$1.00")
    minor = replace(w, minor, r"(?<=\.[0-9])$", "0")
    minor = replace(w, minor, r"\.", "")
    minor = replace(w, minor, r"^0+(?=[0-9])", "")
    positive = w.add("text.match", text=text(minor), WFMatchTextPattern=r"^[1-9][0-9]*$")
    positive = condition(w, positive)
    merchant = replace(w, variable("Priority Merchant"), r"^\s+|\s+$", "")
    merchant = replace(w, merchant, r"\s+", " ")
    merchant = w.add("text.changecase", text=text(merchant), WFCaseType="UPPERCASE")
    merchant = w.setvar("Priority Normalized Merchant", merchant)
    has_merchant = condition(w, merchant)
    # Fixed-order fields with no embedded newlines make a stable identity.
    # Dictionary-to-JSON key order is not stable across native shortcut runs.
    group = replace(w, variable("Priority Group"), r"^\s+|\s+$", "")
    group = replace(w, group, r"\s+", " ")
    identity = w.add(
        "gettext", WFTextActionText=formatted(group, "\n", currency, "\n", minor, "\n", merchant)
    )
    fingerprint = w.add("hash", WFInput=token(identity), WFHashType="SHA256")
    slot = replace(w, fingerprint, r"^.*(.{2})$", "$1")
    key = w.add("gettext", WFTextActionText=formatted("groundkeeper-wallet-priority-v2-", slot))
    wallet = condition(w, source, 4, "wallet_transaction")
    marker = w.dictionary({"fingerprint": fingerprint, "captured_seconds": captured_seconds})
    w.add("setstoredcontent", WFStoredContentKey=text(key), WFInput=text(marker))
    w.add("conditional", GroupingIdentifier=wallet, WFControlFlowMode=1)
    bank = condition(w, source, 4, "bank_notification")
    w.add("delay", WFDelayTime=15.0)
    marker = w.add("getstoredcontent", WFStoredContentKey=text(key))
    has_marker = condition(w, marker)
    matches = condition(w, w.get(marker, "fingerprint"), 4, text(fingerprint))
    marker_seconds = w.get(marker, "captured_seconds")
    timestamp = w.add(
        "text.match",
        text=text(marker_seconds),
        WFMatchTextPattern=r"^[0-9]{1,12}(?:\.[0-9]{1,6})?$",
    )
    has_date = condition(w, timestamp)
    age = w.add("calculateexpression", Input=formatted(captured_seconds, " - ", marker_seconds))
    # Both trigger orders count. Use their original times, before the delay.
    recent = w.add(
        "text.match", text=text(age), WFMatchTextPattern=r"^-?(?:[0-9]|[1-8][0-9])(?:\.[0-9]+)?$"
    )
    recent = condition(w, recent)
    w.add("nothing")
    w.add("exit")
    for branch in (
        recent,
        has_date,
        matches,
        has_marker,
        bank,
        wallet,
        has_merchant,
        positive,
        valid_currency,
        valid_money,
    ):
        endif(w, branch)

    actions = workflow["WFWorkflowActions"]
    first_menu = next(
        i
        for i, action in enumerate(actions)
        if action["WFWorkflowActionIdentifier"].endswith(".choosefrommenu")
    )
    actions[first_menu:first_menu] = w.actions


def save_image(w):
    group = condition(w, variable("Receipt JPEG"))
    image = w.add(
        "setitemname",
        WFInput=token(variable("Receipt JPEG")),
        WFName=text(variable("Receipt Filename")),
    )
    saved = w.add(
        "documentpicker.save",
        WFInput=token(image),
        WFAskWhereToSave=True,
        WFSaveFileOverwrite=False,
    )
    require(w, saved, "The receipt image was not saved. No capture JSON was created.")
    endif(w, group)


def filename(w, description, app, date):
    # Restrict each descriptive component to a bounded filesystem-safe subset.
    # Whitespace, path separators and punctuation become underscores.
    for name, value in [("Filename Description", description), ("Filename App", app)]:
        value = replace(w, value, r"[^A-Za-z0-9_-]", "_")
        value = replace(w, value, r"^(.{60}).*$", "$1")
        require(w, value, "The transaction description and app are required.")
        w.setvar(name, value)
    stamp = w.add(
        "format.date",
        WFDate=text(date),
        WFDateFormatStyle="Custom",
        WFDateFormat="yyyy-MM-dd_HH-mm-ss-SSS",
    )
    return formatted(
        variable("Filename Description"), "_", variable("Filename App"), "_CAPTURE_", stamp, ".json"
    )


def main():
    writer_path = ROOT / "GroundKeeper Capture Transaction.plist"
    writer = plistlib.loads(writer_path.read_bytes())
    # Stable native ID/time prelude retained from the reviewed original writer.
    actions = writer["WFWorkflowActions"][:20]
    actions[16]["WFWorkflowActionParameters"]["WFNumberActionNumber"] = "4"
    w = Workflow("GroundKeeper Capture Transaction", writer)
    w.actions.extend(actions)
    saved = w.setvar(
        "Saved Event", output(actions[-1]["WFWorkflowActionParameters"]["UUID"], "Dictionary")
    )
    # Initialize image variables on every invocation, including no-receipt runs.
    empty = w.add("nothing")
    w.setvar("Receipt JPEG", empty)
    w.setvar("Receipt Filename", empty)
    source = w.get(saved, "source")
    group = condition(w, source, 4, "receipt_attachment")
    version = w.add("number", WFNumberActionNumber="3")
    w.setvar("Saved Event", w.put(saved, "schema_version", version))
    description = w.get(saved, "capture_description")
    require(w, description, "Select an original payment with a transaction description.")
    w.setvar("Capture Description", description)
    target = w.get(saved, "target")
    w.setvar("Capture App", w.get(target, "app"))
    w.add("conditional", GroupingIdentifier=group, WFControlFlowMode=1)
    wallet = condition(w, source, 4, "wallet_transaction")
    w.setvar("Capture Description", w.get(saved, "merchant"))
    amount = w.get(saved, "amount")
    require(w, amount, "The Wallet transaction amount is missing.")
    w.add("conditional", GroupingIdentifier=wallet, WFControlFlowMode=1)
    bank = condition(w, source, 4, "bank_notification")
    w.setvar("Capture Description", w.get(saved, "subtitle"))
    require(w, w.get(saved, "body"), "The bank notification body is missing.")
    w.add("conditional", GroupingIdentifier=bank, WFControlFlowMode=1)
    w.add(
        "alert",
        WFAlertActionTitle="Capture not saved",
        WFAlertActionMessage="Unsupported transaction source.",
        WFAlertActionCancelButtonShown=False,
    )
    w.add("exit")
    endif(w, bank)
    endif(w, wallet)
    require(w, variable("Capture Description"), "The transaction description is missing.")
    w.setvar("Capture App", w.get(saved, "app"))
    require(w, variable("Capture App"), "The source app is missing.")
    optional_details(w)
    endif(w, group)
    name = filename(
        w,
        variable("Capture Description"),
        variable("Capture App"),
        output(actions[11]["WFWorkflowActionParameters"]["UUID"], "Date"),
    )
    serialized = w.add("detect.text", WFInput=token(saved))
    w.setvar("Capture JSON", serialized)
    # Conservative cap: <=16k Unicode characters fit within 64KiB UTF-8.
    bounded(w, serialized, 16000, "The capture is too large. Use a shorter note or receipt.")
    save_image(w)
    named = w.add("setitemname", WFInput=token(variable("Capture JSON")), WFName=name)
    saved_file = w.add(
        "documentpicker.save",
        WFAskWhereToSave=True,
        WFSaveFileOverwrite=False,
        WFInput=token(named),
    )
    # A cancelled Save File may return no item instead of throwing. Never return
    # a success envelope unless that final action produced a saved file.
    missing_file = condition(w, saved_file, 101)
    w.add("exit")
    endif(w, missing_file)
    w.add("output", WFOutput=text(saved))
    wallet_priority(
        w.data, captured_date=output(actions[11]["WFWorkflowActionParameters"]["UUID"], "Date")
    )
    location_capture(w.data)
    transaction_context(w.data)
    w.save()

    # Both adapters use the same writer, which now owns all optional menus.
    for name in ("GroundKeeper Wallet Automation", "GroundKeeper CIBC Automation"):
        path = ROOT / (name + ".plist")
        adapter = plistlib.loads(path.read_bytes())
        adapter["WFWorkflowActions"] = adapter["WFWorkflowActions"][:2]
        fields = adapter["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["WFItems"]["Value"][
            "WFDictionaryFieldValueItems"
        ]
        if not any(field["WFKey"]["Value"]["string"] == "capture_location" for field in fields):
            fields.append(
                {"WFItemType": 0, "WFKey": text("capture_location"), "WFValue": text("on")}
            )
        for key, value in (
            ("wallet_priority_currency", "CAD"),
            ("wallet_priority_group", "default"),
        ):
            if not any(field["WFKey"]["Value"]["string"] == key for field in fields):
                fields.append({"WFItemType": 0, "WFKey": text(key), "WFValue": text(value)})
        if name == "GroundKeeper Wallet Automation":
            fields = adapter["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["WFItems"][
                "Value"
            ]["WFDictionaryFieldValueItems"]
            if not any(
                field["WFKey"]["Value"]["string"] == "wallet_category_raw" for field in fields
            ):
                # No Category property exists in the inspected transaction picker.
                # Leave blank for Any Category; a category-filtered iPhone
                # automation can supply its exact filter label as literal text.
                fields.append(
                    {"WFItemType": 0, "WFKey": text("wallet_category_raw"), "WFValue": text("")}
                )
        a = Workflow(name, adapter)
        a.actions.extend(adapter["WFWorkflowActions"])
        result = output(a.actions[1]["WFWorkflowActionParameters"]["UUID"], "Shortcut Result")
        returned = condition(a, result)
        event_id = a.get(result, "event_id")
        saved_capture = condition(a, event_id)
        description = a.get(result, "merchant" if "Wallet" in name else "subtitle")
        has_description = condition(a, description)
        a.add(
            "notification",
            WFNotificationActionTitle=text(name),
            WFNotificationActionBody=formatted(
                "Successfully captured and saved ", description, "!"
            ),
            WFNotificationActionSound=False,
        )
        endif(a, has_description)
        endif(a, saved_capture)
        endif(a, returned)
        a.save()

    # Standalone later attachment still writes schema 3 and never another payment.
    r = Workflow("GroundKeeper Add Receipt", writer)
    payment = r.setvar(
        "Payment", r.add("detect.dictionary", WFInput=token({"Type": "ExtensionInput"}))
    )
    for key in ("source", "app", "event_id"):
        require(r, r.get(payment, key), "Select the original payment capture JSON.")
    source = r.get(payment, "source")
    group = condition(r, source, 4, "wallet_transaction")
    r.setvar("Capture Description", r.get(payment, "merchant"))
    r.add("conditional", GroupingIdentifier=group, WFControlFlowMode=1)
    bank = condition(r, source, 4, "bank_notification")
    r.setvar("Capture Description", r.get(payment, "subtitle"))
    r.add("conditional", GroupingIdentifier=bank, WFControlFlowMode=1)
    r.add("exit")
    endif(r, bank)
    endif(r, group)
    target = r.dictionary({key: r.get(payment, key) for key in ("source", "app", "event_id")})
    event = r.dictionary(
        {
            "source": "receipt_attachment",
            "app": "Shortcuts",
            "capture_description": variable("Capture Description"),
        }
    )
    event = r.put(event, "target", target)
    r.setvar("Saved Event", event)
    menu = r.menu("Add a receipt to this saved payment?", ["Add receipt", "Skip"])
    r.branch(menu, "Skip")
    r.add("exit")
    r.branch(menu, "Add receipt")
    empty = r.add("nothing")
    r.setvar("Receipt JPEG", empty)
    r.setvar("Receipt Filename", empty)
    collect_receipt(r)
    r.endmenu(menu)
    serialized = r.add("detect.text", WFInput=token(variable("Saved Event")))
    bounded(r, serialized, 15000, "The receipt is too large.")
    save_image(r)
    result = r.run("GroundKeeper Capture Transaction", variable("Saved Event"))
    r.add("output", WFOutput=text(result))
    r.save()

    later = Workflow("GroundKeeper Attach Receipt Later", writer)
    selected = later.add("documentpicker.open", WFSelectMultiple=False)
    require(later, selected, "No payment file was selected.")
    payment = later.add("detect.dictionary", WFInput=token(selected))
    later.run("GroundKeeper Add Receipt", payment)
    later.save()


if __name__ == "__main__":
    main()
