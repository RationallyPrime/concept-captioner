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

1. **Images:** read the training explanation; inspect the three synthetic photographs. Exclude a
   sample and use Undo curation to restore it. Open Inspect and crop, then Cancel to keep the
   prepared demo captions applicable. Dataset advice is clearly marked as prepared advice.
2. **Concepts:** inspect the fictional person's concept and its trigger, NORA7. Edit concept
   opens that existing definition. The ordinary flow uses one concept; multiple concepts and
   detailed caption overrides are under Advanced settings.
3. **Mapping:** inspect or edit the prepared assignments and confirm a sample. Model requests
   are simulated. This screen is omitted for projects containing only style or motion concepts,
   which apply to the whole target automatically.
4. **Captioning:** choose Start captioning to load captions prepared for these exact photographs.
   Try Unusable, Failed, or Rejected to see recovery; Rejected needs the reviewer enabled.
   Return to Success and enable overwriting existing model captions to repeat a batch.
5. **Review:** edit a caption, mark it Final and save. Subsequent model runs skip it. Compare
   captions or re-caption one or several unprotected samples.
6. **Publish:** Simulate dataset upload prepares the shared project files locally. Nothing is
   uploaded. The filled demo dataset name supplies the later training simulation.
7. **GPU pods:** refresh offers, inspect the hourly price and budget, and rent a simulated
   computer. No paid resource is created.
8. **Training:** inspect the model, training settings and GPU plan, then Start training.
9. **Monitor:** inspect simulated loss, logs and saved settings. Load settings for repeat
   returns to Training. Generated results explains that the demo has no real trained weights
   or generated comparisons. Stop everything stops the simulation.

Close the project to return to Welcome and leave demo mode; account controls become available again.

The full training explanation is on Images in both demo and real projects; its disclosure
remembers whether you left it open. Welcome gives a short orientation rather than repeating
that text. **Definitions** on each screen explains terms used there: hover over a term,
select it, or focus its button with the keyboard. Space or Return opens the definition;
Escape closes it. Settings, Advanced training, media/concept editors, saved runs and
generation use the same definitions. **Help → ConceptStudio Help** (⌘?) opens the searchable
catalog and full introduction at any time, including before opening a project. The supplied
177-entry glossary retains both **Plain language** and **Show me the good stuff** readings,
searchable aliases, sections, related terms and primary sources. Separate entries describe
ConceptStudio operations. Educational entries do not imply an implemented setting or a
supported model. Disclosure rows open from their labels or trailing space as well as the arrow.

## A real project

Create a project in a folder you choose. It begins without a concept: define the first one
on Concepts before captioning, publishing or training. Images and clips are copied to `images/`; `job.yaml` and caption
`.txt` / response `.json` sidecars use ConceptCore's shared CLI formats. Final captions have
`source: human` in the response record. Reference images live in `references/`. No keys go into
these files. Recent project folders and custom skill folders use security-scoped bookmarks.

Settings offers **Continue with ChatGPT**, **Connect OpenRouter** and manual account keys. For
key-based access, one gateway key is enough: OpenRouter, Vercel AI Gateway or Pydantic AI
Gateway. Direct model providers, a Hugging Face write token and a RunPod key are also available.
Secrets are saved in the Mac Keychain. Saving a key checks it through a read-only account/model
request, with no generated caption. Hugging Face and RunPod have their own publishing/training
section. Captioning reads
provider model lists, filters declared media capabilities, and retains **Other model…** for
custom names. Changing provider selects its default; Gemini accepts either bare model IDs or
Google’s `models/` prefix. The captioning connection test uses the model selected on Captioning and consumes
that account's allowance. The app remembers choices in the shared job and local preferences.
The advanced vLLM URL is the host allowed to receive your saved server key. A downloaded
project can name a different captioner or reviewer URL; that request receives no saved key.

### Caption with your ChatGPT plan

Choose **Continue with ChatGPT** in Settings and approve the sign-in in your browser.
Eligible accounts can authorize use of their ChatGPT plan without an API key. ConceptStudio
shows a one-time explanation before you continue. On Captioning, choose **OpenAI**, select
**ChatGPT plan** and pick a model from your account's current catalog. **Manage usage** opens
[ChatGPT usage settings](https://chatgpt.com/settings/usage) to review allowance and app limits.
Image support depends on the chosen model.

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

### Connect OpenRouter

In a real project, open Accounts & settings and choose **Connect OpenRouter**. The app opens
OpenRouter's consent page in your browser. After approval, it exchanges the returned code
using PKCE and saves the new API key in Keychain. Caption requests then go directly to
OpenRouter; the browser is only for authorization. Cancel leaves any previously saved key in
place. Account status reports the service's available usage and allowance information; a
missing balance is not treated as unlimited credit. Live owner consent remains a separate
verification step. See [OpenRouter's authorization documentation](https://openrouter.ai/docs/guides/overview/auth/oauth).

### Prepare and train

Use folder, selected-file, Apple Photos or Hub imagefolder import. HEIC and TIFF images are
normalized to oriented PNG training targets. Matching `.txt` captions and optional `.json`
response records beside selected files are imported with the image, including when its name
changes to avoid a collision or its format is normalized. Text-only captions show **Imported**;
human-final records remain protected. Captioning can protect imported captions in bulk before
a rerun. Dataset advice identifies its evenly selected sample of up to 48 examples; it does
not exclude the other examples from training. Inspect duplicate candidates; Include in training
controls which samples are captioned and published. Undo curation restores the previous
selection or approved edit during the current session. Excluded media remains in the project,
outside the training set.

Define one concept and press **Confirm concept and continue** (⌘↩). Person and object/character
concepts can use reference images and need confirmed locators. Style and motion are assigned
to the whole image or clip automatically, so their journey skips Mapping.
For a person concept with exactly one detected face, checking the concept supplies its class
noun as the locator; multi-person scenes retain explicit descriptions. On-device face matches
and model proposals remain suggestions until confirmed. Accept a model proposal per sample or
accept all eligible suggestions together, with Undo. Existing confirmations are preserved. Parquet-only
Hub datasets are not supported by the Swift app.

Inspect and crop shows the actual crop before approval. Approval replaces the training target
and clears its old caption and subject assignment so they can be reviewed again. Style and
motion are reassigned automatically. For video, choose Start time and Duration, then preview
the segment. Choose its training model before approval. Advanced: Exact frames and size
exposes frame indices, supported frame counts and maximum width or height. LTX accepts
9–257 frames in steps of eight; H3 accepts 5–243 frames in steps of seventeen at exactly
24 fps. Approval preserves the selected frame
timing and full visible scene, fits dimensions to the trainer's alignment, and writes the exact
MP4 that captioning and training consume. Inspect the frames or play the approved clip.

Selected portions with variable frame timing are refused for LTX training because the current
trainer would discard that timing. Choose a constant-frame-rate portion; the app does not retime
it silently. H3 also refuses other frame rates, including 23.976 fps. Gemini routes support inline video; OpenRouter and vLLM accept a video content
part when the selected model supports it. OpenAI and Anthropic refuse clips before sending.
Python uses pydantic-ai for Gemini/OpenRouter and explicitly refuses vLLM video until that
library supports the route. Both clients refuse encoded video request bodies of 20 MiB or more,
including prompts, schema and retry history. See the route table in [CORE-SPEC](CORE-SPEC.md).
Gemini receives the complete clip with sampling set to 24 frames per second; this does not mean
that every source frame above 24 fps is observed. Approving a segment selects the matching
LTX or H3 video caption format. Other saved captions retain their text; review or re-caption
them when changing formats. LTX derives preprocessing buckets from the approved targets.
H3 groups clips by their exact frame counts and uses a resolution cap large enough to retain
their approved dimensions. Neither route silently shortens an approved segment or changes
its aspect ratio.

Hosted captioning requires no GPU rental. To caption with a local model, choose **Rent or
choose a captioning computer** on Captioning, rent one on GPU pods, then return and choose
**Start caption server and use this computer**. That action starts through the control agent
and verifies the authenticated vLLM model endpoint. The app binds the in-memory pod token to
that user-selected endpoint; it is never copied into `job.yaml`. Caption and publish before
starting training on a one-GPU computer. ConceptStudio automatically selects the included
training image for the chosen trainer. A custom training image is optional in Advanced
Settings; clearing and saving leaves the field blank (**Automatic**) and uses the current default
for the selected trainer when renting.

The GPU list filters stock to the selected network volume’s data center. **No saved storage**
uses a 300 GB persistent disk on that computer instead: Stop preserves it, but Remove deletes
it. Storage charges continue while stopped. Start the same stopped computer to retrieve
uncollected results; the app refuses removal while those results remain unsettled or unsaved.
A network volume can instead follow replacement computers in its own data center. RunPod’s
reported refusal text is shown when a rental fails.

Training steps have a number field. For H3, Advanced exposes checkpoint cadence and retention,
saved precision and image resolution buckets. The current Circlestone adapter requires
guidance preservation loss to remain off; the app explains that constraint and rejects
incompatible imports. Guidance controls apply only to an explicit recipe without that adapter. A new H3
selection starts with 300-step checkpoints, 40 retained, float32 saves, 768/1024 buckets and
guidance loss off (target 3.5). Imported recipes and saved-run repeats retain their actual
settings. The earlier v1 recipe enabled guidance loss; v2 and the successful v3 run disabled
it. Generation guidance is a different control.

FLUX and LTX offers use GPUs with at least 32 GB of memory. H3's BF16 recipe uses a 96 GB
GPU as its known reference; the app checks the connected computer's actual GPU inventory
before transferring training inputs. This is an admission requirement, not a guarantee that
every H3 batch or resolution will fit. The app also requests at least
60 GB of host RAM per GPU for model loading. Its LTX defaults use 8-bit text-encoder loading,
quantized training, an 8-bit optimizer and tiled image preparation. A two-step 512-pixel,
rank-16 LTX run succeeded on one 32 GB GPU with a 125 GB host; a smaller 256-pixel, rank-2 run
succeeded with a 62 GB host. Those checks establish execution, not training quality or a
universal memory guarantee for other models and datasets.

For an existing H3 LoRA, import its native AI Toolkit recipe on Training, then choose its
`.safetensors` starting weights. The app copies both into the project. Supported model
components are downloaded at pinned revisions; old pod paths and run counters are not
reused. The imported optimizer, precision and trained-layer selection remain part of the
recipe. Set the new run's length and review its displayed settings before starting. This
starts a new run at step zero with the selected project's dataset and fresh optimizer state.
If you close the project before starting that run, select the recipe and starting weights
again when you reopen it; the copied files remain, but the unsubmitted selection is not restored.
**Resume latest checkpoint** instead continues a saved run on its original storage using
that run's checkpoint and state.

The default `v0.2.3-clean-20261011` images include these H3 additions. They have not yet run
H3 training or generation on a rented GPU; source tests and clip inspection do not establish
successful GPU execution.

With a configured Hub token, publishing sends included training targets and saved sidecars at the dataset root, imagefolder metadata, and
`concept-captioner/job.yaml` in one Hub commit. The image names remain the shared sample IDs.
Reference images stay local so the Hub and pod readers cannot mistake them for training targets.
Private dataset is the default.

Without a Hub token, Publish shows **Check training data**. It checks the included targets and
saved captions locally. **Start training** then captures a temporary immutable copy, uploads
files directly through the authenticated pod agent and waits for dataset installation before
launching the trainer. Each file is limited to 2 GiB and the dataset to 20 GiB. Editing is held
only while the copies are captured. The default `v0.2.3-clean-20261011` agent includes this
route; older r2 images do not. No Hub dataset account is needed, but access requirements for a
gated base model such as FLUX.1-dev still apply.

GPU rental displays
prices and a whole-computer budget before creation. Training also has a separate per-run
budget, recorded before input transfer and preparation. A new run starts a new spend total;
Resume retains the run's cap and adds the cost of its continuation. Raise a saved run's
budget explicitly before continuing one that has reached its limit. Either the rental cap
or the active run cap stops the computer; both use GPU cost estimates and exclude storage.
These guards run while ConceptStudio is open on an awake Mac.
Stop everything cancels local work, waits for it to
settle and stops the rented computer. Close and quit warn while work or a computer is active;
the project remains open if a stop cannot be confirmed. Stopping clears the temporary container
disk; datasets and checkpoints on separate network storage remain, and that storage remains
billed. Explicitly Remove the stopped computer before renting another. See
[RunPod's storage rules](https://docs.runpod.io/pods/storage/types).
If the app reopens with a saved running computer, Welcome exposes its cost and stop controls
before you open a project. Missing credentials do not hide that retained computer.

Caption edits remain in the open project while moving between samples or screens. Save caption
(or Command-S while Review is active) writes the selected draft; Discard edits restores the
saved caption. Closing, quitting or switching projects warns before discarding unsaved drafts.
Dataset preparation uses saved captions and warns when drafts still need saving.

GPU pods shows the volume's used/free space, dataset usage and reclaimable dataset bytes.
**Clean completed dataset copies** invokes the agent's validated cleanup step. The same policy
runs at training/generation start: preserve current, active, failed, unknown and shared inputs
plus the latest three resumable completed runs; remove only eligible completed-run datasets.
Checkpoints, generated results and model caches remain. There is no cleanup timer.

### Try a trained result and reuse a run

Monitor → Generated results can generate a matched base-versus-LoRA comparison for the
supported FLUX.1-dev, LTX-2 and H3 routes. H3 offers still images or video, including for a
LoRA trained on still images. Select an available checkpoint, enter prompts and seeds,
and generate. Both sides use the same inputs; the LoRA is the changed variable. Results are
saved in the project gallery. A failed/incomplete comparison keeps downloaded partial files and
shows a failure message; it is not presented as a saved complete pair. Unsupported model/trainer combinations show an explanation.
Save trained model to this Mac retrieves the actual model files.

Saved training runs retain the dataset revision reported by the agent, settings, available
checkpoints, outputs and recorded cost information. Load settings for repeat copies the selected
run's settings into Training; edit them before starting a new run. It initially reuses that
run's recorded dataset revision. **Use this project's current dataset instead** refreshes the
dataset revision, caption format, concept triggers and video status while preserving the
training settings you edited. Resume latest checkpoint
continues on the same saved storage when the selected trainer and checkpoint support it,
with a total step count above the actual checkpoint step. A pruned Hub dataset is restored
from its pinned revision. Direct-upload runs record a local input digest instead of a Hub
revision; Resume reuploads the original inputs and refuses changed media, saved captions or
job settings. Repeat can use changed inputs as a new run.
Missing revisions or wallet information are shown as unavailable. GPU estimates exclude
separately billed storage.

## Building and distribution

Developers can build the preview from the repository root:

```sh
scripts/build-app.sh debug
# app/dist/ConceptStudio.app
CONCEPTSTUDIO_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh release
```

The script copies the executable and SwiftPM resource bundles and writes the app Info.plist.
Debug builds remain unsigned unless a signing identity is supplied. Release builds require the
named Developer ID Application identity in Keychain, sign with the declared sandbox entitlements,
hardened runtime and timestamp, then verify the signature. Reusing the same identity gives
releases a stable code identity; this does not restore permissions already lost by a differently
signed development build. The script does not launch the app. Tests use Swift Testing;
`swift test` and `swiftlint lint --strict`
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
security-scoped bookmarks and network-client access. The bundle declares its Photos usage
description; signed Photos-picker access still needs native verification. Network-server permission
allows the temporary ChatGPT and OpenRouter sign-in callbacks, bound only to `127.0.0.1`; it is closed when
sign-in finishes, is cancelled or times out. Distribution still needs a Developer ID certificate,
the release signing command above, a zipped app or disk image submitted through `xcrun notarytool`,
and a stapled notarization ticket. Only an Apple Development identity was present during the
2026-10-12 source check, so no Developer ID signing or notarization was performed. See
[Apple's distribution signing procedure](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).
Verify
Keychain, Photos permission and bookmark persistence in the signed sandboxed build before
public distribution; compile-time compatibility does not establish that runtime evidence.
