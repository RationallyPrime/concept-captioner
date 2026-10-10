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

Settings offers **Log in with ChatGPT** and account keys. For key-based access, one gateway key
is enough: OpenRouter, Vercel AI Gateway or Pydantic AI Gateway. Direct model providers,
a Hugging Face write token and a RunPod key are also available. Secrets are saved in the Mac
Keychain. The captioning connection test uses the model selected on Captioning and consumes
that account's allowance. The app remembers choices in the shared job and local preferences.
The advanced vLLM URL is the host allowed to receive your saved server key. A downloaded
project can name a different captioner or reviewer URL; that request receives no saved key.

### Caption with your ChatGPT plan

Choose **Continue with ChatGPT** in Settings and approve the sign-in in your browser.
Eligible accounts can authorize use of their ChatGPT plan without an API key. ConceptStudio
shows a one-time explanation before you continue. On Captioning, choose **OpenAI**, select
**ChatGPT plan** and pick a model from your account's current catalog. **Manage usage** opens
[ChatGPT usage settings](https://chatgpt.com/settings/usage) to review allowance and app limits.
Image support depends on the chosen model. ConceptStudio itself sells no credits.

This choice applies to all OpenAI requests in the app: captioning, the optional caption
reviewer, model comparisons and photo/concept assistance. **OpenAI API credits** uses the
separate API key instead. There is no automatic fallback between them. Other providers keep
their own accounts. ChatGPT plan usage can draw on the plan or its credits balance, according
to the permissions you approve in ChatGPT.

The ChatGPT preview supports native structured captions and JSON output, with image inputs.
Its current API does not accept an output-token cap or sampling controls such as temperature;
unsupported job settings produce an error rather than being silently ignored. Usage-limit
errors stop new captioning requests and direct you to Manage usage. Saved captions remain.

Accounts and tokens stay separate from projects. Select an existing account to reuse it, use
**Sign in again** to renew authorization, or **Continue with ChatGPT** to add another account
or workspace. **Sign out** clears that registration's local tokens and attempts remote session
revocation; the app reports when it cannot confirm revocation. You can also disconnect the
app in ChatGPT settings. Demo mode disables sign-in and stays offline.

The shared job still records the OpenAI model as `kind: openai`; it contains no OAuth tokens
or account registration. The authentication choice is local to this Mac. The Python CLI
continues using its separately configured OpenAI API credentials.

Implementation follows OpenAI's [open-source sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
and [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

### Prepare and train

Use folder, selected-file, Apple Photos or Hub imagefolder import. Check warnings, define the
learning boundary and confirm subject mappings. On-device face matches and model proposals
are suggestions; they never confirm identity automatically. Parquet-only Hub datasets are not
supported by the current Swift core.

Hosted captioning requires no GPU rental. To caption with a local model, choose **Rent or
choose a captioning computer** on Captioning, rent one on GPU pods, then return and choose
**Start caption server and use this computer**. That action starts through the control agent
and verifies the authenticated vLLM model endpoint. The app binds the in-memory pod token to
that user-selected endpoint; it is never copied into `job.yaml`. Caption and publish before
starting training on a one-GPU computer. ConceptStudio automatically selects the included
training image for the chosen trainer. A custom training image is optional in Advanced
Settings; clearing the override and saving restores the included image.

The included models use GPUs with at least 32 GB of memory. The app also requests at least
60 GB of host RAM per GPU for model loading. Its LTX defaults use 8-bit text-encoder loading,
quantized training, an 8-bit optimizer and tiled image preparation. A two-step 512-pixel,
rank-16 LTX run succeeded on one 32 GB GPU with a 125 GB host; a smaller 256-pixel, rank-2 run
succeeded with a 62 GB host. Those checks establish execution, not training quality or a
universal memory guarantee for other models and datasets.

Publishing sends training photos and sidecars at the dataset root, imagefolder metadata, and
`concept-captioner/job.yaml` in one Hub commit. The image names remain the shared sample IDs.
Reference faces stay local so the Hub and pod readers cannot mistake them for training photos.
Private dataset is the default. GPU rental displays
prices and a budget before creation. Stop everything cancels local work, waits for it to
settle and stops the rented computer. Close and quit warn while work or a computer is active;
the project remains open if a stop cannot be confirmed. Stopping clears the temporary container
disk; datasets and checkpoints on separate network storage remain, and that storage remains
billed. Explicitly Remove the stopped computer before renting another. See
[RunPod's storage rules](https://docs.runpod.io/pods/storage/types).
If the app reopens with a saved running computer, Welcome exposes its cost and stop controls
before you open a project. Missing credentials do not hide that retained computer.

Caption edits remain in the open project while moving between photos or screens. Save caption
(or Command-S while Review is active) writes the selected draft; Discard edits restores the
saved caption. Closing, quitting or switching projects warns before discarding unsaved drafts.
Publishing uploads saved captions and warns when drafts still need saving.

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

The native UI conventions are in [DESIGN.md](../DESIGN.md). To inspect actual SwiftUI content
without changing the desktop or using a live service, run this from the repository root after
the normal app build has populated its Yams checkout:

```sh
scripts/render-app-preview.sh
# Offscreen PNGs and source/render manifests in app/dist/visual-check
```

This opt-in Swift Testing render pass uses the bundled demo, fake GPU services and isolated
preferences in a temporary source snapshot. It checks the minimum and default window sizes
in light and dark appearances. The host window is never shown or activated. Offscreen bitmap
rendering does not establish live keyboard, VoiceOver, titlebar or native vibrancy behavior;
use the actual app for the human walkthrough. Ordinary `swift test` skips the render pass.

`app/ConceptStudio.entitlements` declares the sandbox, user-selected read/write access,
security-scoped bookmarks, network-client access and Photos access. Network-server permission
allows the temporary ChatGPT sign-in callback, bound only to `127.0.0.1`; it is closed when
sign-in finishes, is cancelled or times out. Distribution still needs
a Developer ID signing identity, hardened-runtime signing with those entitlements, a zipped
app or disk image submitted through `xcrun notarytool`, and a stapled notarization ticket.
Those steps need the owner's Apple developer account and have not been performed. Verify
Keychain, Photos permission and bookmark persistence in the signed sandboxed build before
public distribution; compile-time compatibility does not establish that runtime evidence.
