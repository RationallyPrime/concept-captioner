# Running ConceptStudio

The development preview is `app/dist/ConceptStudio.app`. Double-click it in Finder. It is
unsigned; this preview has not been approved for distribution. If macOS blocks it, use the
explicit Open Anyway action in System Settings → Privacy & Security after attempting to open
the app. The app needs macOS 15 or newer. It needs no Python, terminal, GPU or development
environment to run.

## First run: the offline demo

Choose **Try the demo** in Welcome. The visible Demo badge stays on throughout the journey.
The demo uses three synthetic portraits and fake captioning, GPU and training services. It
does not read Keychain credentials or send network requests. Photos import is disabled in the
demo so an iCloud Photos download cannot be triggered there.

1. **Images:** inspect the bundled illustrations and their warnings; ask for dataset advice.
2. **Concepts:** inspect the learning word and reference image. Edit the boundary or draft it
   from an intended result; check the draft before saving.
3. **Mapping:** ask for model proposals, fill a suggestion and confirm each photo. You can
   also type a locator. The demo starts with confirmed mappings so you can proceed immediately.
4. **Captioning:** choose Start captioning. Try Unusable, Failed, or Rejected to see recovery;
   Rejected needs the reviewer enabled. Return to Success to continue. Re-caption existing
   model captions when repeating a run.
5. **Review:** edit a caption and save it as Final. Model runs skip it. Compare another model
   without replacing the saved caption, or re-caption one or several unprotected photos.
6. **Publish:** try publishing. This prepares the shared project files locally and uploads
   nothing. The demo dataset name is filled in for the training simulation.
7. **GPU pods:** refresh offers, choose one or two GPUs, review the hourly price and spending
   limit, then rent a simulated computer.
8. **Training:** read the GPU plan and start. One GPU is sequential; multiple GPUs keep
   captioning on GPU 0 and train on the others.
9. **Monitor:** refresh to advance the simulated curves, publish the fake result, and Stop
   everything. No real computer or charges exist in this mode.

Close the project to return to Welcome. Open or create a project to leave demo mode.

## A real project

Create a project in a folder you choose. Photos are copied to `images/`; `job.yaml` and caption
`.txt` / response `.json` sidecars use ConceptCore's shared CLI formats. Final captions have
`source: human` in the response record. Reference images live in `references/`. No keys go into
these files. Recent project folders and custom skill folders use security-scoped bookmarks.

Settings leads with one gateway key: OpenRouter, Vercel AI Gateway or Pydantic AI Gateway.
Direct model providers, a Hugging Face write token and a RunPod key are available under
Advanced. Secrets are saved in the Mac Keychain. The captioning connection test uses the model
selected on Captioning and can use provider credits. The app remembers choices in the shared
job and non-secret preferences.
The advanced vLLM URL is the host allowed to receive your saved server key. A downloaded
project can name a different captioner or reviewer URL; that request receives no saved key.

Use folder, selected-file, Apple Photos or Hub imagefolder import. Check warnings, define the
learning boundary and confirm subject mappings. On-device face matches and model proposals
are suggestions; they never confirm identity automatically. Parquet-only Hub datasets are not
supported by the current Swift core.

Hosted captioning requires no GPU rental. To caption with a local model, choose **Rent or
choose a captioning computer** on Captioning, rent one on GPU pods, then return and choose
**Start caption server and use this computer**. That action starts through the control agent
and verifies the authenticated vLLM model endpoint. The app binds the in-memory pod token to
that user-selected endpoint; it is never copied into `job.yaml`. Caption and publish before
starting training on a one-GPU computer. Select a verified project container image in Advanced
Settings before creating a real pod.

Publishing sends training photos and sidecars at the dataset root, imagefolder metadata, and
`concept-captioner/job.yaml` in one Hub commit. The image names remain the shared sample IDs.
Reference faces stay local so the Hub and pod readers cannot mistake them for training photos.
Private dataset is the default. GPU rental displays
prices and a budget before creation. Stop everything cancels local work, waits for it to
settle and stops the rented computer. Close and quit warn while work or a computer is active;
the project remains open if a stop cannot be confirmed. A stopped computer retains its billed
temporary disk; explicitly Remove it before renting another. Separate network storage is kept.
If the app reopens with a saved running computer, Welcome exposes its cost and stop controls
before you open a project. Missing credentials do not hide that retained computer.

## Building and distribution

Developers can build the preview from the repository root:

```sh
scripts/build-app.sh debug
# app/dist/ConceptStudio.app
scripts/build-app.sh release
```

The script copies the executable and both SwiftPM resource bundles, writes the app Info.plist,
and does not launch or sign it. Tests use Swift Testing; `swift test` and `swiftlint lint --strict`
run from `app/`. `swiftformat Sources Tests --lint` checks formatting.

`app/ConceptStudio.entitlements` declares the sandbox, user-selected read/write access,
security-scoped bookmarks, network-client access and Photos access. Distribution still needs
a Developer ID signing identity, hardened-runtime signing with those entitlements, a zipped
app or disk image submitted through `xcrun notarytool`, and a stapled notarization ticket.
Those steps need the owner's Apple developer account and have not been performed. Verify
Keychain, Photos permission and bookmark persistence in the signed sandboxed build before
public distribution; compile-time compatibility does not establish that runtime evidence.
