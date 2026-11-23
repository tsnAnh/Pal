# ESC dismiss audit

Every popup on Mac now closes through one stack, `MacEscapeStack` (apps/ios/Packages/PalDesign/Sources/PalDesign/Components/EscapeStack.swift). The root owns the only cancel key and presses the top entry. Entries are ordered panel, stepFlow, sheet, menu, dialog, with nested Back steps above their host.
The policy lives in `EscapePolicy.swift` and is declared on the popup content with `.palEscapePolicy(...)`. `.dismisses` closes it. `.blocked(.unsavedInput)` asks "Discard changes?" through the dialog layer. `.blocked(.inFlight | .requiredStep | .blockingError)` ignores ESC.
Before means main at 7837054d, read with `git show`. Rows marked iOS/iPad only are compiled for iOS and left to UIKit. Files added after 7837054d say so. Line numbers are the current tree (e4897b63).

| file:line | kind | before (ESC on main, reason) | decision | change |
|---|---|---|---|---|
| `App/PalApp.swift:216` | macSheet | partly: macSheetDismissDisabled(isCreating) removed the layer key, but Close in the sheet chrome called an unguarded onLeading and kept its cancel shortcut, so ESC closed it mid-create; system sheet on iPhone/iPad | blocked(inFlight) while creating; blocked(unsavedInput) with a name or members typed | RoomSheets.swift policy replaces macSheetDismissDisabled |
| `App/PalApp.swift:242` | native sheet, iOS/iPad only | system sheet; SheetChrome Close carries the cancel shortcut (iPad hardware keyboard); CreateBotSheet blocks while creating | left to system | none (allowlisted) |
| `App/PalApp.swift:269` | fullScreenCover, iOS/iPad only | partly: system full-screen cover, Kanban chrome Close is the exit; ESC route not verified | left to system | none |
| `App/PalApp.swift:272` | fullScreenCover, iOS/iPad only | partly: system full-screen cover, SearchView chrome Close is the exit; ESC route not verified | left to system | none |
| `App/ChatView.swift:79` | fullScreenCover | Mac: works, native sheet closed by the SheetChrome Close cancel shortcut (VoiceModeView). iPhone/iPad: full-screen cover, Close button only | left alone; no panel hosts it, so the chrome keeps its own shortcut | none |
| `App/ChatView.swift:83` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Platform/AdaptiveNavigation.swift:141` | fullScreenCover, iOS/iPad only | helper behind `.fullCover` on iOS; system cover, Close button only | left to system | none |
| `App/Platform/AdaptiveNavigation.swift:143` | native sheet | helper behind `.fullCover` on Mac (voice mode): native AppKit sheet closed by the content's own cancel shortcut | left alone | none |
| `App/Platform/CameraCapture.swift:6` | fullScreenCover, iOS/iPad only | system camera (UIImagePickerController); Cancel button is the exit | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/MacSheet.swift:124` | native sheet, iOS/iPad only | system sheet on iPhone/iPad; also the Mac fallback when no sheet host is in the environment | left to system | environment resets `escapeHostLayer` so chrome buttons keep their own shortcut |
| `App/Platform/Sharing.swift:6` | native sheet, iOS/iPad only | system share sheet (UIActivityViewController) | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/Sharing.swift:27` | system panel (share), iOS/iPad only | system activity view | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/Sharing.swift:36` | system panel (share), iOS/iPad only | system activity view | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/Sharing.swift:51` | alert (UIAlertController), iOS/iPad only | system alert, OK is the only exit | left to system | none |
| `App/Platform/Sharing.swift:83` | system panel (share) | AppKit share picker popover, AppKit owns ESC | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/Sharing.swift:90` | NSAlert | partly: raw NSAlert with one OK button; ESC on a lone OK button not verified | shared helper PalAlert.notice | three copy-pasted NSAlert blocks collapsed into one helper; the alert itself is unchanged |
| `App/Profile/TemplateSharer.swift:22` | NSAlert / UIAlertController | Mac: partly, NSAlert with one OK button (ESC unverified). iPhone/iPad: system alert | shared helper | goes through SharePresenter.alert, no change here |
| `App/Platform/DocumentActions.swift:7` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/DocumentActions.swift:14` | NSAlert | partly: raw NSAlert with one OK button; ESC unverified | shared helper PalAlert.notice | raw NSAlert replaced by PalAlert.notice |
| `App/Platform/ImageActions.swift:26` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/ImageActions.swift:32` | NSAlert | partly: private NSAlert.show helper, one OK button; ESC unverified | shared helper PalAlert.notice | private helper removed |
| `App/Platform/ImageActions.swift:38` | NSAlert | partly: private NSAlert.show helper, one OK button; ESC unverified | shared helper PalAlert.notice | private helper removed |
| `App/Platform/MediaFileActions.swift:12` | system panel | works: system panel, ESC handled by the OS (file added after 7837054d) | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/MediaFileActions.swift:21` | NSAlert | partly: raw NSAlert with one OK button; ESC unverified (file added after 7837054d) | left alone: allowlisted until the media preview units merge | none; still a raw NSAlert, not PalAlert |
| `App/Platform/PalAlert.swift:7` | NSAlert | n/a: new helper; behaves like the three raw alerts it replaced | single OK button, no cancel key | see Not verified |
| `App/Mac/MacOwnerPhotoPicker.swift:10` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Platform/InAppBrowser.swift:26` | fullScreenCover, iOS/iPad only | SFSafariViewController; Done is owned by Safari | system owns ESC (AppKit/UIKit) | none (allowlisted) |
| `App/Platform/InAppBrowser.swift:32` | native sheet | none (not verified): Mac browser sheet, Done button has no cancel shortcut and focus can sit in a WebView | dismisses | BrowserFrame registers `.palEscape(.native)` (hidden cancel button, native fallback) |
| `App/Setup/StepFlowChoices.swift:72` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Setup/OwnerSetupView.swift:16` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Setup/OwnerSetupView.swift:26` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `Packages/PalDesign/Sources/PalDesign/Components/MacDialog.swift:217` | alert, iOS/iPad only | system alert fallback when no dialog host exists; cancel-role button is the exit | left to system | none |
| `Packages/PalDesign/Sources/PalDesign/Components/MacDialog.swift:223` | confirmationDialog, iOS/iPad only | system confirmationDialog fallback; tap-away or the cancel-role button closes it | left to system | none |
| `App/CreateBotImport.swift:51` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/CreateBotImport.swift:64` | macSheet | works: layer key removed while importing and Close's onLeading guarded on isBusy, so the lock held; system sheet on iPhone/iPad | blocked(inFlight) while the import runs | macSheetDismissDisabled replaced by `.palEscapePolicy` (CreateBotImport.swift) |
| `App/Chat/ChatComposer.swift:153` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Chat/ChatComposer.swift:159` | fullScreenCover, iOS/iPad only | see CameraCapture.swift | system owns ESC (AppKit/UIKit) | none |
| `App/Chat/ChatComposer.swift:161` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Chat/ChatComposer.swift:277` | inline suggestion menu | works: ESC dismisses the slash and file-reference menu while it has matches, otherwise passes through | left alone (edit-first) | none (allowlisted) |
| `App/Chat/MessageMenu.swift:85` | native sheet, iOS/iPad only | system sheet (MessageSheet); VoiceOver escape action pops page or closes | left to system | none (allowlisted) |
| `App/Settings/AccountScreen.swift:87` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Settings/AccountScreen.swift:93` | native sheet, iOS/iPad only (SettingsSheet is iOS only) | system sheet; Close in SheetChrome, `interactiveDismissDisabled(isBusy)` locks swipe | left to system | none |
| `App/Settings/AccountScreen.swift:108` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/AccountScreen.swift:117` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/VaultScreen.swift:113` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with a login or API key typed: ESC asks Discard changes? | `.palEscapePolicy` in AddVaultSheet (VaultScreen.swift) |
| `App/Settings/VaultScreen.swift:116` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses (no policy declared, typed edits are discarded without asking) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Settings/VaultScreen.swift:119` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/VaultScreen.swift:142` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/HostKitScreen.swift:47` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/HostKitScreen.swift:57` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/SpeechMemoryScreen.swift:31` | macSheet | works: sheet layer cancel key, plus SecretEntry's own cancelAction button (two cancel buttons) | dismisses (SecretEntry left alone) | layer key removed; panel registers a `.sheet` entry in the root stack; SecretEntry keeps its own shortcut (allowlisted) |
| `App/Settings/SpeechMemoryScreen.swift:37` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/ModelProvidersScreen.swift:191` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/BotKeysScreen.swift:25` | macSheet | works: sheet layer cancel key, plus SecretEntry's own cancelAction button (two cancel buttons) | dismisses (SecretEntry left alone) | layer key removed; panel registers a `.sheet` entry in the root stack; SecretEntry keeps its own shortcut (allowlisted) |
| `App/Settings/BotKeysScreen.swift:28` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/PublicAccessScreen.swift:79` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with a route draft typed and no secret issued yet | `.palEscapePolicy` in AddPublicRouteSheet (PublicAccessScreen.swift) |
| `App/Settings/PublicAccessScreen.swift:82` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/PublicAccessScreen.swift:89` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/OwnerIntroPresenter.swift:45` | macSheet | works: sheet layer cancel key unless saving (macSheetDismissDisabled(isSaving)); dismissal maps to `intro.escape()` (crop step back, else Not now) | blocked(inFlight) while saving | `.palEscapePolicy` in OwnerIntroSheet (MacOwnerIntro.swift); Mac only |
| `App/Settings/GitHubTokenScreen.swift:62` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Settings/SettingsSheet.swift:109` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/SettingsSheet.swift:118` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/DiagnosticsScreen.swift:202` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/DiagnosticsScreen.swift:252` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/ComputerAndDevicesScreens.swift:89` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/ComputerAndDevicesScreens.swift:99` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/ComputerAndDevicesScreens.swift:244` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/ComputerAndDevicesScreens.swift:256` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Chat/ChatImages.swift:316` | system panel (share) | system share popover, owned by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Chat/MessageSheet.swift:152` | system panel (share), iOS/iPad only | system share sheet | system owns ESC (AppKit/UIKit) | none |
| `App/Chat/FilePreviewSheet.swift:115` | system panel (share), iOS/iPad only | system share sheet | system owns ESC (AppKit/UIKit) | none |
| `App/Chat/ImageViewer/ViewerImageStage.swift:180` | system panel (share) | system share popover inside the viewer's context menu | system owns ESC (AppKit/UIKit) | none |
| `App/Settings/HostUpdateScreen.swift:49` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/HostUpdateScreen.swift:59` | macSheet | works: layer key unless updating (macSheetDismissDisabled(isUpdating)); its own Close has escapes:false and is disabled while updating | blocked(inFlight) while the update runs | `.palEscapePolicy` replaces macSheetDismissDisabled (HostUpdateScreen.swift) |
| `App/Settings/PreferenceScreens.swift:165` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/PreferenceScreens.swift:303` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/PreferenceScreens.swift:391` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/PermissionsScreen.swift:91` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Settings/PermissionsScreen.swift:95` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Settings/PermissionsScreen.swift:108` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Computer/TeachViews.swift:276` | macSheet | works: layer key unless busy (macSheetDismissDisabled(busy)); Close's onLeading guarded on busy, so the lock held | blocked(inFlight) while teaching saves | `.palEscapePolicy` replaces macSheetDismissDisabled (TeachViews.swift) |
| `App/Computer/TeachViews.swift:279` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Computer/ComputerView.swift:81` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Mac/MacSettings.swift:215` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:221` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:227` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:405` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:415` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:430` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:532` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Mac/MacSettings.swift:535` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:544` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:692` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with a login or API key typed | `.palEscapePolicy` in AddVaultSheet |
| `App/Mac/MacSettings.swift:695` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses (no policy declared) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Mac/MacSettings.swift:698` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacSettings.swift:707` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacInspector.swift:67` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with a title, prompt or schedule typed | `.palEscapePolicy` in NewRoutineSheet |
| `App/Mac/MacInspector.swift:70` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with name, look, photo or persona changes | `.palEscapePolicy` in EditBotSheet |
| `App/Mac/MacInspector.swift:73` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/SlackLinkView.swift:22` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacAboutYou.swift:50` | macSheet | works: layer key unless busy (macSheetDismissDisabled(isBusy)) | blocked(inFlight) while the photo saves | `.palEscapePolicy` replaces macSheetDismissDisabled (MacAboutYou.swift) |
| `App/Mac/MacShortcutSettings.swift:60` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/LocalEngine/LocalEngineSettingsSection.swift:76` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacModelProviders.swift:147` | popover | partly: AppKit transient popover; ESC with focus in the address text field not verified | dismisses | MacProviderAddressEditor registers `.palEscape(.native)` |
| `App/Mac/LocalEngine/LocalEngineSetupHost.swift:14` | step flow panel (MacModalPanel) | works: own hidden cancel key and panel Close shortcut, both off while installing or signing in (closeDisabled); PanelButton Cancel also carried a cancel shortcut | blocked(inFlight) while installing, signing in or provider sign-in busy | host key and closeDisabled removed; `layer: .stepFlow` plus `.palEscapePolicy`; PanelButton uses palCancelShortcut |
| `App/Mac/MacSheetLayer.swift:23` | MacModalPanel (sheet host) | works: hidden cancel key for the top sheet unless dismiss-locked; panel Close hidden by preference | dismisses (per-sheet policy) | `layer: .sheet`; isTop and lock state removed |
| `App/Mac/MacModals.swift:34` | MacModalPanel | works: panel Close carried the cancel shortcut (shortcuts sheet) | dismisses | close button no longer carries the shortcut; panel registers with the root stack |
| `App/Mac/MacModals.swift:39` | surface (Kanban) | works: page chrome Close carries its cancel shortcut; the card page sets escapes:false so its Back is mouse-only | left alone: not registered with the stack, chrome keeps its shortcut (hostLayer nil) | none |
| `App/Mac/MacModals.swift:51` | MacModalPanel | works: panel Close shortcut (rename bot) plus the Cancel button's own cancelAction (two cancel buttons) | blocked(inFlight) while saving | Cancel uses palCancelShortcut; `.palEscapePolicy` replaces interactiveDismissDisabled |
| `App/Mac/MacModals.swift:58` | MacModalPanel (command palette) | works: hidden cancel button plus `onKeyPress(.escape)` on the search field, panel Close hidden | dismisses | both keys removed; panel registers with the stack |
| `App/Mac/MacModals.swift:99` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacModals.swift:108` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Mac/MacModals.swift:127` | MacModalPanel (settings) | works: panel Close shortcut | dismisses | close button no longer carries the shortcut; panel registers with the root stack |
| `App/Mac/MacModals.swift:132` | MacModalPanel (create bot) | partly: Close disabled while creating (closeDisabled), nothing guards typed input | blocked(inFlight) while creating; blocked(unsavedInput) with a name typed | createBotEscape policy replaces closeDisabled |
| `App/Mac/MacModals.swift:141` | MacModalPanel (connect apps) | works: panel Close shortcut; hidden by preference while a nested page shows its own Back | dismisses; nested Back is a stack entry above the panel | Back registers `.palEscape(nested: true)` through SheetChrome |
| `App/Mac/MacModals.swift:193` | menu | works: hidden cancel button | dismisses | button replaced by `.palEscape(.menu)` |
| `App/Mac/MacMessageMenu.swift:105` | menu | works: hidden cancel button | dismisses | button replaced by `.palEscape(.menu)` |
| `App/Mac/MacMessageMenuView.swift:38` | menu | works: hidden cancel button | dismisses | button replaced by `.palEscape(.menu)` |
| `App/Mac/MacMessageMenuView.swift:130` | system panel (share) | system share popover, owned by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Mac/MacPalette.swift:92` | menu (command palette content) | works: panel Close hidden, own hidden cancel button and `onKeyPress(.escape)` on the field | dismisses | both removed; the panel owns ESC |
| `App/Kanban/KanbanFilterBar.swift:91` | inline suggestion menu (search field) | works: ESC clears the search text first | left alone (edit-first) | none (allowlisted) |
| `App/Kanban/KanbanFilterBar.swift:117` | menu | system Menu, AppKit owns ESC | system owns ESC (AppKit/UIKit) | none |
| `App/Profile/SlackSettingsView.swift:54` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/SlackSettingsView.swift:66` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/SlackSettingsView.swift:265` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Profile/RoutinesView.swift:46` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with a title, prompt or schedule typed | `.palEscapePolicy` in NewRoutineSheet |
| `App/Profile/RoutinesView.swift:49` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/EditBotSheet.swift:82` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Rooms/RoomView.swift:79` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Rooms/RoomView.swift:80` | system panel | works: system panel, ESC handled by the OS | system owns ESC (AppKit/UIKit) | none |
| `App/Rooms/RoomView.swift:83` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/ServiceSignIn/ServiceSignInView.swift:428` | macSheet | partly: macSheetDismissDisabled(true) removed the layer key and the binding ignored dismissal; ESC worked only through the Close or Not now button's cancelAction, and not at all in the signed-in phase | dismisses (same as Not now) | binding setter now calls `center.notNow()`; ESC reaches it through the sheet entry; buttons use palCancelShortcut |
| `App/Profile/BotModelView.swift:51` | native sheet, iOS/iPad only | system sheet; BotModelPicker's SheetChrome Close carries the cancel shortcut (iPad keyboard) | left to system | none (allowlisted) |
| `App/Profile/BotModelView.swift:55` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/BotModelView.swift:256` | native sheet, iOS/iPad only | system sheet; closes through its page Back | left to system | none (allowlisted) |
| `App/Profile/SlackChannelsScreen.swift:43` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/TelegramView.swift:50` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with a bot token typed | `.palEscapePolicy` in TelegramTokenSheet |
| `App/Profile/TelegramView.swift:53` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/BotProfileView.swift:40` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | blocked(unsavedInput) with name, look, photo or persona changes | `.palEscapePolicy` in EditBotSheet |
| `App/Profile/BotProfileView.swift:43` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/BotManagementDialogs.swift:22` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/BotManagementDialogs.swift:34` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/BotManagementDialogs.swift:43` | alert (rename), iOS/iPad only | system alert with a text field; Cancel button is the exit | left to system | none (allowlisted) |
| `App/Profile/SlackAudienceSection.swift:43` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsModel+GoogleAds.swift:39` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/Profile/LibraryView.swift:48` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/ConnectApps/ShopifyFlowSheet.swift:17` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsEntry.swift:38` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/ConnectApps/CustomConnectorForm.swift:54` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/ConnectApps/T3CodeFlowSheet.swift:27` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsScreen.swift:110` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/ConnectApps/ConnectAppsScreen.swift:117` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/ConnectApps/ConnectAppsScreen.swift:127` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack; the catalog's nested detail Back is a nested stack entry |
| `App/ConnectApps/ConnectAppsScreen.swift:130` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsScreen.swift:131` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsScreen.swift:138` | macSheet | works: sheet layer cancel key, plus SecretEntry's own cancelAction button (two cancel buttons) | dismisses (SecretEntry left alone) | layer key removed; panel registers a `.sheet` entry in the root stack; SecretEntry keeps its own shortcut (allowlisted) |
| `App/ConnectApps/ConnectAppsScreen.swift:142` | macSheet | works: sheet layer hid a cancel key on the top sheet; system sheet on iPhone/iPad | dismisses | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsScreen.swift:154` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/ConnectAppsModel+Discord.swift:39` | step flow panel (macSheet) | works: sheet layer hid a cancel key on the top sheet (StepFlow chrome keys unchanged) | dismisses (StepFlow chrome left alone) | layer key removed; panel registers a `.sheet` entry in the root stack |
| `App/ConnectApps/SkillsCatalogSheet.swift:43` | macSheet | works: sheet layer cancel key, plus SecretEntry's own cancelAction button (two cancel buttons) | dismisses (SecretEntry left alone) | layer key removed; panel registers a `.sheet` entry in the root stack; SecretEntry keeps its own shortcut (allowlisted) |
| `App/ConnectApps/SkillsCatalogSheet.swift:48` | macAlert | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system alert on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Profile/EditBotPersonaSection.swift:80` | macConfirm | works: dialog layer cancel key pressed the cancel role (plain dismiss if none); system confirmationDialog on iPhone/iPad | shared dialog layer | layer cancel key replaced by `.palEscape(.dialog)` |
| `App/Chat/ImageViewer/ImageViewerPresenter.swift:32` | viewer, iOS/iPad only | system full-screen cover, PalCloseButton is the exit | left to system | none (file added after 7837054d) |
| `App/Chat/ImageViewer/ImageViewerPresenter.swift:37` | viewer, iOS/iPad only | works: full-screen cover with `onKeyPress(.escape)` on the focused view (needs focus) and PalCloseButton | left alone (owned by media units) | none (allowlisted) |
| `App/Chat/ImageViewer/ImageViewerPresenter.swift:42` | viewer | works: own `onKeyPress(.escape)` on the focused viewer (MacImageViewer.swift) | left alone (owned by media units) | none (allowlisted) |
| `App/Chat/ImageViewer/ImageViewerPresenter.swift:43` | viewer | works: own `onKeyPress(.escape)` on the focused viewer (MacDocumentViewer.swift) | left alone (owned by media units) | none (allowlisted) |
| `App/Chat/ImageViewer/ImageViewerPresenter.swift:44` | viewer | works: own `onKeyPress(.escape)` on the focused viewer (MacMediaViewer.swift, added after 7837054d) | left alone (owned by media units) | none (allowlisted) |

## Exceptions for the owner to review

Every site that declares a blocked reason. No site declares `requiredStep` or `blockingError`.

| file:line | reason | when it blocks | what ESC does |
|---|---|---|---|
| `App/Mac/MacModals.swift:120` | inFlight | the new bot is being created | ignored, Close disabled |
| `App/Mac/MacModals.swift:120` | unsavedInput | a bot name is typed | asks Discard changes? |
| `App/Rooms/RoomSheets.swift:70` | inFlight | the room is being created | ignored |
| `App/Rooms/RoomSheets.swift:70` | unsavedInput | a name or members are entered | asks Discard changes? |
| `App/Settings/VaultScreen.swift:288` | unsavedInput | a login or API key draft differs from empty | asks Discard changes? |
| `App/Settings/PublicAccessScreen.swift:284` | unsavedInput | a route draft is typed and no secret was issued yet | asks Discard changes? |
| `App/Profile/NewRoutineSheet.swift:58` | unsavedInput | title, prompt or schedule typed | asks Discard changes? |
| `App/Profile/EditBotSheet.swift:64` | unsavedInput | name, look, photo or persona fields changed | asks Discard changes? |
| `App/Profile/TelegramView.swift:250` | unsavedInput | a bot token is typed | asks Discard changes? |
| `App/CreateBotImport.swift:102` | inFlight | the template import is running | ignored |
| `App/Settings/HostUpdateScreen.swift:61` | inFlight | the host update is running | ignored |
| `App/Mac/MacOwnerIntro.swift:156` | inFlight | the owner intro is saving | ignored |
| `App/Mac/MacAboutYou.swift:147` | inFlight | the owner photo is saving | ignored |
| `App/Mac/MacRenameBot.swift:72` | inFlight | the rename is saving | ignored |
| `App/Computer/TeachViews.swift:149` | inFlight | the taught skill is saving | ignored |
| `App/Mac/LocalEngine/LocalEngineSetupHost.swift:22` | inFlight | install, sign-in or provider sign-in is running | ignored |

Native locks that are not stack policies. `App/ServiceSignIn/ServiceSignInView.swift:430` sets `interactiveDismissDisabled(true)` for the iOS swipe, and on Mac ESC reaches `center.notNow()` through the sheet entry, so it dismisses. `App/Settings/AccountScreen.swift:106` and `App/CreateBotSheet.swift:44` are iOS swipe locks only.

## Left alone on purpose

Listed in `scripts/ci/esc_dismiss_allowlist.txt`, which the ESC lint reads.

- Viewers. `ChatImages.swift`, `MacImageViewer.swift`, `MacDocumentViewer.swift` and `MacMediaViewer.swift` keep their own `onKeyPress(.escape)` (owned by the media preview units, migrate after they merge). Before: works, but only while the viewer holds focus. `MediaPlayerCover` is an iOS cover with its own close button.
- `SecretEntry.swift` keeps its own `.keyboardShortcut(.cancelAction)` (glass input work in PRs 364 and 365). StepFlow chrome, SetupButtons, ClearGlass and PalTextInput are untouched for the same reason.
- `App/Platform/MediaFileActions.swift:21` is still a raw NSAlert, allowlisted until the media units merge.
- Kanban surface. It has its own handler and is not registered with the stack. Before and after: the page chrome Close (`KanbanSurface.swift` `KanbanPage`) carries the SheetChrome cancel shortcut. `KanbanCardView.swift:47` sets `escapes: false`, so Back from a card is mouse only. Root cancel key is disabled while the stack is empty, so the two do not clash.
- Edit-first rule. `ChatComposer.swift` slash and file-reference menu and the `KanbanFilterBar.swift` search field handle ESC first (dismiss the menu, clear the text) and pass it on when there is nothing to undo.
- System panels (NSOpenPanel, NSSavePanel, fileImporter, fileExporter, photosPicker, ShareLink, share pickers). AppKit and UIKit own ESC.
- SwiftUI `Menu` and `.contextMenu` controls (composer, headers, Kanban, ConnectApps cards, MacInspector). The OS owns ESC.
- `MacInspector.swift` is a docked side panel, not a popup. Its Close sets `escapes: false`.
- iOS/iPad native sheets, covers and alerts. UIKit owns dismissal, hardware ESC on iPad not verified.

## Not verified

No Mac build or UI run was possible, so these are open.

- IME composition. ESC during marked text may cancel the composition or hit the root cancel key. `ChatComposer` guards it with `isComposingText`. Palette, sheet and dialog fields have no such guard.
- Focus inside a WebView. ESC in the Mac browser sheet (`InAppBrowser.swift`) may go to the page, not the sheet.
- Shortcut resolution with two hidden cancel buttons. SecretEntry's own cancelAction button inside a hosted sheet, and any chrome button outside a host (`palCancelShortcut` falls back to `.cancelAction`), sit beside the root key. Which one SwiftUI fires first is not confirmed.
- NSAlert with a single OK button. `PalAlert.swift` adds no cancel key, so ESC may beep and not close it. Same for `MediaFileActions.swift:21`.
- ESC with focus in the provider address text field inside the `.popover` (`MacModelProviders.swift:147`).
- The Discard changes? dialog layering above a sheet that is above a panel (ordering rests on the layer enum, not a UI run).
- ESC from a Kanban card page and iPad hardware ESC on native sheets.

## Row counts per kind

| kind | rows |
|---|---|
| macSheet | 31 |
| step flow panel | 8 |
| MacModalPanel | 7 |
| macConfirm | 39 |
| macAlert | 23 |
| native sheet | 9 |
| fullScreenCover | 7 |
| alert (system) | 3 |
| confirmationDialog | 1 |
| popover | 1 |
| NSAlert (incl. UIAlertController helper) | 7 |
| system panel | 18 |
| menu | 5 |
| viewer | 5 |
| Kanban surface | 1 |
| inline suggestion menu | 2 |
| total | 167 |
