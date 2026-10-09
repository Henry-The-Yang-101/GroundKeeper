# GroundKeeper macOS app

This folder contains the native SwiftUI macOS app and its Xcode project.
The current app is a resizable window with a narrow icon sidebar. Home,
Full insights, Sync, and Settings each open an empty page with its subtitle.
The selected icon is highlighted; hovering shows the page name. Command-1
through Command-4 also switch pages. Colors follow the system appearance.
The gray sidebar has smaller icons with Settings pinned to its bottom, and no
divider between the sidebar and page.

The iPhone side is Apple Shortcuts only. iCloud Drive is the file handoff between
the iPhone capture workflow and this app.

## Build and launch

Requires Xcode 16 or later with its command-line tools selected. The deployment
target is macOS 14 or later; the app was built locally with Xcode 27.

From the repository root:

```sh
./apps/macos/run.sh
```

The script builds and launches `GroundKeeper.app`, using the ignored directory
`.local/macos/DerivedData/` for build output. For debugging and previews, open
`GroundKeeper.xcodeproj`, select the GroundKeeper scheme, and press Run.
The project uses ad hoc signing for local development without a developer team.
Its current bundle identifier is `com.groundkeeper.macos`.

The window opens at 1000 × 680, has a small minimum size of 400 × 340, and
has no app-defined maximum size. Standard macOS resizing and full screen remain
available. The sidebar stays 88 points wide while the page fills the window.

## Folder responsibilities

```text
macos/
  GroundKeeper.xcodeproj/  # macOS app target and shared scheme
  run.sh                  # build and launch locally
  GroundKeeper/
    App/
      GroundKeeperApp.swift # app entry point and window configuration
      RootView.swift        # selected tab state and page routing
      SidebarView.swift     # icon buttons, selection styling, keyboard shortcuts
    Features/
      Home/HomeView.swift
      FullInsights/FullInsightsView.swift
      Sync/SyncView.swift
      Settings/SettingsView.swift
      Shared/PlaceholderPage.swift # shared subtitle and empty-page layout
    Models/
      AppTab.swift          # tab names, icons, and keyboard shortcuts
    Services/             # iCloud file access, storage, classifier integration
    Resources/            # asset catalogs, localization, safe bundled resources
  GroundKeeperTests/      # reserved for future tests; no test target yet
```

Keep each feature's views and state together inside `Features/<Feature>/`.
Each of the four tabs already has its own file. Replace that view's placeholder
when implementing the feature; keep common presentation in `Features/Shared/`.
Keep filesystem access and classifier calls in `Services/`, so views do not
need to manage iCloud files or launch Python processes directly.

The Xcode target uses a synchronized `GroundKeeper/` source folder, so new Swift
files in that tree are picked up automatically. Add a test target when there
is service or feature behavior to test.

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

Next, define the file contract and implement an import service tested against
redacted fixtures. Add the classifier connection after its request/response
contract is settled. The Sync and Settings pages are placeholders, with no
iCloud access or application settings implemented yet.
