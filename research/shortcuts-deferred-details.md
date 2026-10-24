# Deferring iPhone capture details behind a notification

Investigation date: 2026-10-24. This is research, not implemented capture behavior.

## Desired behavior

Save each Wallet/CIBC payment immediately without presenting a menu. Later,
opening its notification should start a fresh receipt/note flow for that exact
payment. Several pending payments must retain independent identities. Additional
third-party iPhone apps are outside the requested scope.

The current shared writer calls `optional_details` before its JSON Save File
action. Its optional menus therefore block saving, and cancellation aborts the
capture. Standalone receipt attachments already have explicit parent identities;
standalone captured notes do not yet have an equivalent import path. Editing an
already imported payment is unsuitable because changed bytes for an existing
event identity are treated as a collision.

## Findings and remaining leads

| Mechanism | Evidence | Status for this requirement |
| --- | --- | --- |
| Native Show Notification with a shortcut URL in its body | An older firsthand report says expanding a native notification makes the URL tappable. Another report describes the same approach, followed by a reply that could not trigger it. | The user confirmed that the URL-only probe launched the target on their physical iPhone. Per-event dispatch, persistence, and failure cases still need testing. |
| Native Show Notification attachment | Apple's guide describes rich media previews. A more recent firsthand attempt to attach a URL produced an image preview. | No verified arbitrary callback/input mechanism found. |
| Show Notification followed by Wait to Return | A user confirmed this resumes a shortcut after tapping the notification. A separate user reports tapping one of several notifications resumes the other waiting shortcuts too. | A foreground-return workaround, not a verified per-notification dispatch mechanism. Unsuitable as the sole durable routing design. |
| Confirmation before running the original capture | Apple documents confirmation notifications for automations generally. | Delays the initial save; does not provide save-now/enrich-later by itself. Availability must be checked for the exact trigger/OS. |
| Notification relay: first save, then notify; second automation listens and asks for confirmation | The notification-source picker accepts Shortcuts on the tested Mac and iOS simulator. A firsthand report confirms using a Reminders notification to trigger another shortcut. | Interesting relay primitive. A deferred-confirmation control was not exposed for the notification trigger in the tested iOS 27.0 UI; no successful deferred relay established. |
| Shortcuts + built-in Reminders with a shortcut URL | Apple supports reminder links and launching shortcuts with text input. A shared shortcut uses reminder URLs to restart its workflow. | Plausible durable alternative with an extra interaction. Still needs an iPhone prototype and testing. |
| App-open dispatch when Shortcuts opens | A firsthand report says Shortcuts is excluded from the app-open trigger picker; the thread reports an app-based Focus schedule workaround. | Focus changes would affect user settings and still do not identify which notification was tapped. Not verified here. |

## Local checks

### Existing capture configuration

The CIBC app label temporarily disappeared from the Mac editor after inspecting
and dismissing its notification-source picker. Exporting the shortcut showed
that the original `com.CIBC.mobilebanking` selection and trigger UUID remained
present, and its actions matched the existing saved installed-shortcut backup.
Closing and reopening the editor restored the label. The CIBC automation remained
off. No production capture workflow was replaced or intentionally reconfigured.

### macOS 27.0.1

Two separate research shortcuts were created:

- `GK Research Notification Sender`: emits a notification containing fictional
  `event-A` data.
- `GK Research Notification Receiver`: watches Shortcuts notifications whose
  title contains `GroundKeeper Research`, and would display the trigger body in
  an alert. It emits no notifications, avoiding a notification loop.

The receiver did not visibly run after the sender emitted its native
notification. This is inconclusive: macOS delivery/permission behavior was not
isolated, and this does not establish iPhone behavior. The receiver was disabled
after the experiment.

The initial attempt to edit the installed sender did not persist. The user's
physical-iPhone screenshot showed the original `GKRESEARCH_INPUT event-A` body,
so that run did not test hyperlink behavior. A locally updated source file was
insufficient evidence that the installed or synced shortcut had changed.

The installed sender was subsequently edited through the native text controls,
closed and reopened, and exported from Shortcuts. The exported `Shortcut.wflow`
was inspected and confirmed to contain one native Show Notification action with:

- Title: `GroundKeeper URL Test v2`
- Body: `shortcuts://run-shortcut?name=GK%20Research%20Link%20Target&input=text&text=event-A`

The body contains only the URL, with no attachment or automatic Open URL action.
The harmless target shortcut is named `GK Research Link Target`. These research
shortcuts remain available for a physical-iPhone check through the user's existing
Shortcuts sync. The user subsequently confirmed on their physical iPhone that
the notification link opened the target, providing a screenshot of its success
alert. The exact phone OS version and interaction sequence were not recorded.
They do not access the inbox or real transaction data.

### iOS 27.0 simulator

A disposable `GroundKeeper Notification Research` device was exercised through
Xcode's Device Hub. No Apple Account or personal financial data was used.
The disposable simulator was shut down and removed after the checks.

A native shortcut containing Wait (1 second) and Show Notification successfully
displayed a notification containing:

```text
GK Link Test
shortcuts://run-shortcut?name=GK%20Research%20Link%20Target&input=text&text=event-A
```

Tapping the notification normally opened the sender's shortcut editor. It did
not dispatch the embedded URL. Expanded-notification hyperlink behavior was not
verified: the available simulator UI interactions did not establish the required
long-press state. This is a testing limitation, not proof that the older report
is false.

The simulator's native Notification automation picker allowed Shortcuts as its
source. Expanding this trigger exposed Automation and Notify switches, without a
Confirm Before Run switch. No successful deferred-confirmation relay was tested.

## Physical-phone result and remaining tests

The user confirmed that the URL-only sender opened the
`GroundKeeper Research Link Worked` alert on their physical iPhone. The earlier
`GroundKeeper Research A` / `GKRESEARCH_INPUT event-A` notification is obsolete
and contains no link.

Repeat with two different event IDs, display the received input in the target,
and reverse the order of taps. Then test long delays, locking/unlocking,
force-quitting Shortcuts, and restarting the phone. A successful launch of a
single fixed-message target does not establish durable multi-transaction routing.

The proposed production design should save payment
JSON first and embed only a validated event ID and safe relative filename in
each callback. The details helper should validate both against the saved payment
and write independent attachment events. Notification dismissal must not delete
the payment or its pending-details record.

## Labeled hyperlink probe

After the URL-only success, the user requested a label such as “Add receipt or
note” instead of the visible URL. No native separate link-label parameter was
found. Apple's notification-body API exposes a string; this suggests rich-text
link attributes may be lost, but does not establish the behavior of the current
iPhone Shortcuts notification renderer.

A separate `GK Research Styled Link` shortcut was generated locally, signed, and
installed through Shortcuts. Its native action sequence is:

1. Text: `[Add receipt or note](shortcuts://run-shortcut?name=GK%20Research%20Link%20Target&input=text&text=event-A)`
2. Make Rich Text from Markdown.
3. Show Notification with title `GroundKeeper Styled Link Test`, using the
   conversion output as its body.

An export of the installed shortcut was extracted and inspected: the body magic
variable references the native converter's output UUID. The working URL-only
sender was kept unchanged. A Mac run remained active without a visible
notification and was stopped; this is inconclusive for Mac behavior.

The user ran the probe on their physical iPhone and reported: “Label appears but
isn’t tappable.” This establishes that the tested Markdown → rich-text → native
notification body path does not preserve an actionable labeled hyperlink on that
phone. The URL-only sender remains the working approach. No supported separate
label/destination setting was found in the native action. A shorter helper name
and compact event token could reduce the visible URL length, but would not create
a labeled link; these changes have not been implemented. Other conversions and
custom notification extensions were not tested.

## Sources

- [Apple: notification body API](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/body?changes=_7)
- [Apple: notification appearance customization](https://developer.apple.com/documentation/usernotificationsui/customizing-the-appearance-of-notifications)
- [Apple: Show Notification](https://support.apple.com/en-ie/guide/shortcuts/apd2175adcab/ios)
- [Apple: run a shortcut using a URL scheme](https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios)
- [Apple: automation confirmation overview](https://support.apple.com/en-euro/guide/shortcuts/apd690170742/ios)
- [Apple: add a shortcut to Reminders](https://support.apple.com/en-euro/guide/shortcuts/apdacfdf1802/ios)
- [Native notification URL claim](https://www.reddit.com/r/shortcuts/comments/gx1qc3/shortcut_on_lock_screen/)
- [Notification text URL claim and conflicting reply](https://www.reddit.com/r/shortcuts/comments/lf8vy9/is_there_a_way_to_run_an_action_only_if_you_click/)
- [Confirmed notification + Wait to Return example; URL-attachment attempt](https://www.reddit.com/r/shortcuts/comments/1m5352e/is_there_a_way_to_add_an_action_to_a_notification/)
- [Multiple waiting shortcuts resume together](https://www.reddit.com/r/shortcuts/comments/1pbiulf/wait_for_return_timeout/)
- [Reminders notification relay firsthand test](https://www.reddit.com/r/shortcuts/comments/1u49od2/theres_finally_a_reliable_way_to_schedule/)
- [Shared reminder-link workflow](https://www.reddit.com/r/shortcuts/comments/1q8dpsn/i_built_a_selfperpetuating_reminder_shortcut_that/)
- [Shortcuts app-open restriction and Focus workaround](https://www.reddit.com/r/shortcuts/comments/1k1555k/automated_shortcut_when_shortcuts_opened_not/)
