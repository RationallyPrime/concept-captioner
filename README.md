# ConceptStudio

A native Mac application for turning your photos or video clips into a diffusion LoRA:
prepare the training data, write and review captions, rent a GPU, train, and collect the model.
The Mac manages the project; training and result generation run on RunPod.

ConceptStudio is for people who have no programming or machine-learning experience, with
direct controls for people who already know their tools. A LoRA is an adapter that teaches a
compatible image or video model a concept, such as a person, object, visual style or movement.
The default workflow teaches one concept. Multiple concepts and detailed settings are available
under Advanced.

**Development preview.** The app and offline demo work, and the repository records successful
live captioning and training runs. A signed, notarized app download is not yet available.
The current preview is built from source; release permission checks and several advanced
training paths still need live verification. See [current status](app/docs/APP-STATUS.md).

## Try the offline demo

You need **macOS 15 or later** and a current Xcode installation with its Swift toolchain.
Development and native verification have used Apple Silicon Macs; Intel distribution has not
been verified. Open Xcode once to finish its setup before building.

```sh
git clone https://github.com/RationallyPrime/concept-captioner.git
cd concept-captioner
scripts/build-app.sh debug
open app/dist/ConceptStudio.app
```

Choose **Try the demo** in the Welcome window. It uses bundled synthetic photos, prepared
captions and simulated computers. It needs no accounts, rents nothing and spends no money.
Definitions are available throughout the app and in searchable Help, with **Plain language**
and **Show me the good stuff** explanations.

The source build is an unsigned development preview. Build instructions, account setup and the
signing/notarization procedure are in [Running ConceptStudio](app/docs/RUNNING.md).

## From examples to a trained model

| Step | What you do |
| --- | --- |
| **Images** | Import photos or clips, inspect duplicates, include or exclude examples, and approve crops or exact video segments. |
| **Concepts** | Choose what the LoRA should learn and the trigger that names it in captions. |
| **Mapping** | Confirm which subject the concept belongs to. Whole-target style and motion concepts skip this step. |
| **Captioning** | Choose a provider and model, generate descriptions, and optionally have a second model review them. |
| **Review** | Edit captions beside the actual training media and protect finished captions from model runs. |
| **Publish** | Prepare the included media and saved captions; publish a Hub dataset or prepare a direct upload to the training computer. |
| **GPU pods** | Choose hardware and storage, review the price, and set spending and idle limits before renting. |
| **Training** | Set the training recipe, start a run, or reuse settings from a saved run. |
| **Monitor** | Follow progress, retrieve the LoRA, and try supported base-versus-trained comparisons with matched prompts and seeds. |

Captions name the concept with its trigger and describe the visible details outside that
concept. This is the *concept boundary*: it guides what training should associate with the
trigger. It does not guarantee that the model separates every correlated detail in the data;
dataset choice and evaluation still matter.

## Accounts, data and costs

- **Captioning:** use an eligible ChatGPT account, connect OpenRouter, supply a provider or
  gateway key, or use a compatible vLLM server. The app keeps the selected account and billing
  route explicit. Image and video support depend on both the provider route and chosen model.
- **Training:** use your RunPod account. Hugging Face is optional for publishing datasets and
  trained models; direct dataset upload and saving results to the Mac are supported. Gated
  base models may still require a Hugging Face token and acceptance of their license.
- **Storage:** choose a reusable network volume or a persistent disk attached to the rented
  computer. Stopping a computer ends GPU billing but retains saved storage and its charges.
  Removing a computer deletes its attached disk; separate network storage remains.
- **Credentials and project files:** credentials stay in Keychain. The project is an ordinary
  folder containing a job file, media, caption sidecars and saved run information. A custom
  captioning skill is copied into that folder. The selected captioning service receives the
  media it needs, and the training computer receives the approved training set.

**Budget and idle shutdown depend on this Mac.** Keep ConceptStudio running and the Mac awake
while a computer is rented. Those controls cannot stop a rental while the app is closed or
the Mac is asleep. GPU estimates exclude separately billed storage. These are current runtime
limits, not a guarantee of a server-enforced spending cap.

## What has been verified

The [app status](app/docs/APP-STATUS.md) and [pod status](pod/docs/POD-STATUS.md) separate source
tests, native interaction checks and actual service runs. Recorded live evidence includes
ChatGPT and OpenRouter captioning, bounded FLUX/LTX training and result checks, and a completed
H3 identity run using 69 still images and 3,000 training steps. Those checks used the specific
images and settings recorded there; they do not establish every combination or model quality.

H3 clip training, external warm-start, same-run Resume and matched H3 generation still need
live acceptance. Signed sandbox behavior, Photos and folder-permission persistence across
builds, VoiceOver acceptance and notarization remain release checks. ChatGPT plan access is
shown, but the in-app remaining-allowance display is still unfinished.

## CLI and project interoperability

The repository also contains **`concept-captioner`**, the Python reference implementation and
CLI. It shares the app's job, skill, profile and caption-record formats. The native app calls
its providers and pod services directly; using it does not require installing Python.

For command-line use, install from this checkout with Python 3.11 or later and
[uv](https://docs.astral.sh/uv/):

```sh
uv venv
uv pip install -e ".[hf]"
.venv/bin/concept-captioner --help
```

There is currently no published `concept-captioner` package on PyPI. The
[CLI guide](docs/CLI.md) covers a complete job example, providers, custom skills, all caption
profiles, Hugging Face sources/sinks, reruns and library use. Existing `.txt`/`.json` caption
companions can be imported into the app; captions marked `source: human` remain protected.

## Repository and documentation

| Component | Role |
| --- | --- |
| [`app/`](app/) | SwiftUI application and the native ConceptCore captioning library. |
| [`src/concept_captioner/`](src/concept_captioner/) | Python reference implementation and CLI, using pydantic-ai for model calls. |
| [`pod/`](pod/) | Authenticated control agent, trainer/generation wrappers, container images and podctl. |

- [Run the app](app/docs/RUNNING.md) · [Use the CLI](docs/CLI.md) · [Operate the pod services](pod/README.md)
- [Product brief](app/docs/APP-BRIEF.md) · [Architecture decisions](docs/ADR-LOG.md)
- [Shared captioning contract](app/docs/CORE-SPEC.md) · [Pod contract](pod/docs/POD-SPEC.md)
- [App status](app/docs/APP-STATUS.md) · [Core status](app/docs/CORE-STATUS.md) · [Pod status](pod/docs/POD-STATUS.md)

Accepted decisions remain in the brief and decision log after their implementation. Dated
verification records retain the scope of what was actually tested.

MIT licensed. Model licenses and service access requirements are separate from the code license.
