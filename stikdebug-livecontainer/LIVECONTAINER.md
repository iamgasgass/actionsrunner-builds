# StikDebug-LC — StikDebug inside the *same* LiveContainer

Fork of [StikDebug](https://github.com/StephenDev0/StikDebug) **3.2.2** (upstream commit `7a80dfc`, 12 Nov 2026)
that lets StikDebug, installed **inside LiveContainer**, enable JIT for **another app installed in the same
LiveContainer**.

> 🇮🇹 Versione italiana più sotto.

## The problem

With the normal flow ("Run with JIT" in LiveContainer + StikDebug), StikDebug asks debugserver to relaunch the
LiveContainer app and attaches to it. When StikDebug is itself a guest of that LiveContainer, relaunching
LiveContainer kills StikDebug before it can attach: the new LiveContainer process stays suspended and nothing works.
Upstream StikDebug therefore only supports a *second* LiveContainer copy (LiveContainer2) or a Home Screen install.

## How this fork solves it

The only process StikDebug can debug without killing itself is a *different* process of the same LiveContainer:
a **LiveProcess (Multitask)** extension process.

1. The new **LiveContainer** tab (shown automatically when StikDebug runs inside LiveContainer) lists the apps
   installed in the hosting LiveContainer (private apps from `Documents/Applications` and shared apps from the
   app group).
2. When you tap an app, StikDebug waits for the device tunnel + Developer Disk Image, then calls LiveContainer's own
   `+[LCUtils launchMultitaskGuestApp:completionHandler:]` (loaded at runtime from
   `LiveContainerSwiftUI.framework`) to start the app in a Multitask window, and gets its **PID**.
3. StikDebug attaches to that PID (`debugApp(withPID:)`). On TXM devices (iOS 26+) the app's LiveContainer JIT
   script (`jitLaunchScriptJs`) or StikDebug's assigned script is run, without "returning" to the host app.

Safety guards added everywhere in the app:

| Situation | Upstream | This fork |
|---|---|---|
| Enable JIT for the LiveContainer that hosts StikDebug (by bundle ID) | relaunches LC → StikDebug dies, LC stuck suspended | blocked with an explanation, button to the LiveContainer tab |
| Attach to StikDebug's own PID | deadlock | blocked |
| Script "resume" to the host LC bundle (TXM) | relaunches LC → kills StikDebug and the target | skipped |
| "Auto quit after enabling JIT" in LC main process | `exit(0)` kills LC and the Multitask window | skipped (still works in a LiveProcess / outside LC) |
| "Launch app" / "relaunch" of the host LC | kills StikDebug | blocked |
| LocalDevVPN callback | always `livecontainer://` | the real scheme of the hosting copy (`livecontainer2://`, …) |
| `stikjit://enable-jit?bundle-id=<LC>&pid=<pid>` sent by LiveContainer's "StikDebug (Another LiveContainer/Multitask)" option | works | still works (pid path), never relaunches the host |

New URL: `stikdebug://livecontainer` opens the LiveContainer tab.

## Requirements

* iOS 17.4+ (JIT in a Multitask window), LocalDevVPN, a valid pairing file imported in StikDebug.
* LiveContainer with **Multitask** support, installed with **"Keep Extensions"** (the LiveProcess extension must exist).
* iOS 26+: LiveContainer requires JITLess mode for normal guests; JIT is still needed by apps that generate code
  (emulators). On TXM devices a JIT script is required (set it in LiveContainer's app settings or assign one in
  StikDebug → Scripts).

## Usage

1. Install LiveContainer (Keep Extensions). Enable Multitask in its settings.
2. Install the StikDebug-LC IPA **into LiveContainer** (shared or private).
3. Open StikDebug from LiveContainer, import the pairing file, connect LocalDevVPN, wait for "Connected" and
   "DDI mounted".
4. Open the **LiveContainer** tab → tap the app → *Launch with JIT*.
5. The app appears in a Multitask window with JIT enabled. Keep StikDebug open while a TXM script is running.

Alternative (LiveContainer-driven): in LiveContainer settings choose JIT enabler
**"StikDebug (Another LiveContainer/Multitask)"**, mark the app "Run with JIT", open it **in Multitask**;
LiveContainer sends `stikjit://enable-jit?…&pid=…` to StikDebug-LC, which attaches by PID.

## Building

The project uses the Xcode 27 project format. CI (`.github/workflows/build_ipa.yml`) builds an unsigned
`StikDebug-LC-<sha>.ipa` on every push. In a fork set the repository variables `RUNNER_LABEL`
(default `macos-26`) and `XCODE_VERSION` (default `latest-stable`) to a macOS image that has Xcode 27.

Locally:

```sh
xcodebuild archive -project StikDebug.xcodeproj -scheme StikDebug -configuration Debug \
  -archivePath build/StikDebug.xcarchive -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
mkdir -p Payload && cp -R build/StikDebug.xcarchive/Products/Applications/StikDebug.app Payload/ && zip -r StikDebug-LC.ipa Payload
```

## Files changed

* `StikDebug/LiveContainer/LiveContainerBridge.swift` — new: LiveContainer detection, host info, guest app scan,
  Multitask launch via the Objective-C runtime.
* `StikDebug/LiveContainer/LiveContainerAppsView.swift` — new: the LiveContainer tab.
* `StikDebug/Device/JITEnableContext.swift` — guards against launching/relaunching the host LC or attaching to self.
* `StikDebug/Views/HomeView.swift` — host-LC alert, no resume to host, no `exit(0)` inside LC.
* `StikDebug/App/AppFeature.swift`, `StikDebug/Views/MainTabView.swift` — new tab / tool and URL route.
* `StikDebug/Views/SettingsView.swift` — LocalDevVPN callback uses the real LiveContainer scheme.
* `.github/workflows/build_ipa.yml` — runs on hosted macOS runners in forks; website update only upstream.

## Known limitations (not verified on a device)

* This fork was written without access to a Mac/iPhone: it has **not been compiled or tested** yet. Build it in CI
  and test before relying on it.
* It depends on LiveContainer internals (`LCUtils`, `NSUserDefaults(LiveContainer)` class methods,
  `LCAppInfo.plist` keys) as of LiveContainer `main` in Nov 2026; future LiveContainer changes may break it.
* LiveContainer's multitask controller reads `NSHomeDirectory()`; the bridge temporarily points `HOME` at the
  LiveContainer home while the window is created and then restores it.
* For non-JITLess LiveContainer setups LiveContainer only waits ~1 s for JIT before starting a guest; apps that need
  JIT immediately at launch may still fail in a Multitask window. JITLess setups (required on iOS 26) are not affected.
* Apple TV manual pairing Bonjour browsing (`_remotepairing-manual-pairing._tcp`) is not declared in LiveContainer's
  Info.plist, so that feature does not work inside LiveContainer.

---

## 🇮🇹 In italiano

**Obiettivo:** StikDebug installato *dentro* LiveContainer abilita il JIT per un'altra app installata nello *stesso*
LiveContainer.

**Perché l'originale non funziona:** per dare il JIT, StikDebug rilancia LiveContainer con il debugger. Se StikDebug
gira dentro quello stesso LiveContainer, il rilancio chiude StikDebug prima che possa agganciarsi.

**Soluzione del fork:** l'app viene avviata in una finestra **Multitask** di LiveContainer (processo LiveProcess
separato, con un suo PID) e StikDebug si aggancia a quel PID. Tutte le operazioni che chiuderebbero StikDebug
(rilancio dell'LC ospite, attach a se stesso, `exit(0)`, "ritorno" all'LC dopo lo script) sono bloccate.

**Uso:**
1. Installa LiveContainer con "Keep Extensions" e attiva Multitask nelle impostazioni.
2. Installa l'IPA StikDebug-LC dentro LiveContainer.
3. Apri StikDebug da LiveContainer, importa il pairing file, attiva LocalDevVPN e attendi "Connected" + DDI montata.
4. Scheda **LiveContainer** → tocca l'app → *Launch with JIT*. L'app si apre in una finestra Multitask con JIT attivo.

In alternativa: in LiveContainer scegli "StikDebug (Another LiveContainer/Multitask)", attiva "Run with JIT"
sull'app e aprila in Multitask.

**Attenzione:** il codice non è stato compilato né provato su un dispositivo (nessun Mac disponibile); compila con la
GitHub Action e prova prima di affidarti al fork.
