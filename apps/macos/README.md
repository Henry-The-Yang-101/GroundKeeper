# GroundKeeper macOS app

This folder is the home for the native macOS app. The initial recommendation is
SwiftUI. It currently contains a tracked source-folder scaffold only: no Xcode
project, app target, dependencies, or runnable interface has been created.

The iPhone side is Apple Shortcuts only. iCloud Drive is the file handoff between
the iPhone capture workflow and this app.

## Folder responsibilities

```text
macos/
  GroundKeeper/
    App/                  # app entry point, scenes, navigation, composition
    Features/             # Transactions/, Review/, Summary/, Settings/ as needed
    Models/               # app-facing transaction and review models
    Services/             # iCloud file access, storage, classifier integration
    Resources/            # asset catalogs, localization, safe bundled resources
  GroundKeeperTests/      # macOS-specific unit and integration tests
```

Keep each feature's views and state together inside `Features/<Feature>/`.
Keep filesystem access and classifier calls in `Services/`, so views do not
need to manage iCloud files or launch Python processes directly.

When creating the Xcode macOS app target, use `GroundKeeper/` for its sources and
`GroundKeeperTests/` for its tests, and save the project alongside this README.
Decide the minimum macOS version and bundle identifier at that point.

## Integration boundaries

- **Capture:** iPhone Shortcuts writes events to iCloud Drive. This folder does
  not contain an iPhone app.
- **Import:** the Mac reads incoming files through a service using an agreed,
  versioned file contract. File availability, partial writes, retries, and
  duplicate imports need explicit handling when implemented.
- **Classification:** the existing Python code lives in `../../groundkeeper/`.
  The app-to-Python interface and distribution approach are still undecided;
  training and evaluation scripts stay outside the app source tree.
- **Storage:** live database, keys, and downloaded models stay outside the
  repository and the synced capture folder. Choose their exact runtime location
  when storage is implemented.
- **Policy:** follow `../../TRANSACTION_CATEGORIES.md`. Preserve the
  Uncategorized/Other fallback and a separate Needs review status.

Start implementation with an Xcode app target, a minimal window, and an import
service tested against redacted fixtures. Add the classifier connection after
its request/response contract is settled.
