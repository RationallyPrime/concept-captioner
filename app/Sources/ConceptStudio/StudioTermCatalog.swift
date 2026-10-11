import Foundation

/// One definition per term, shared by the introduction, contextual controls and searchable Help.
enum StudioTerm: String, CaseIterable, Identifiable {
    case train, diffusionModels, baseModel, concept, trainingData, caption, conceptBoundary, trigger, classNoun, lora
    case mapping, locator, captionFormat, provider, apiKey, keychain, gateway, reviewer, tokens, thinking
    case structuredOutput, datasetRevision, gpu, vram, pod, networkStorage, containerImage, budget
    case checkpoint, resume, warmStart, seed, prompt, trainingSteps, learningRate, rank, alpha
    case batchSize, gradientAccumulation, resolution, fps, loss, precision, trainingRecipe, dataset

    static let introductory: [StudioTerm] = [
        .train, .diffusionModels, .baseModel, .concept, .trainingData,
        .caption, .conceptBoundary, .trigger, .classNoun, .lora,
    ]

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .train: "Train"
        case .diffusionModels: "Diffusion models"
        case .baseModel: "Base model"
        case .concept: "Concept"
        case .trainingData: "Training data"
        case .caption: "Caption"
        case .conceptBoundary: "Concept boundary"
        case .trigger: "Trigger"
        case .classNoun: "Class noun"
        case .lora: "LoRA"
        case .mapping: "Mapping"
        case .locator: "Locator"
        case .captionFormat: "Caption format"
        case .provider: "Provider"
        case .apiKey: "API key"
        case .keychain: "Keychain"
        case .gateway: "Gateway"
        case .reviewer: "Reviewer"
        case .tokens: "Tokens"
        case .thinking: "Thinking"
        case .structuredOutput: "Structured output"
        case .datasetRevision: "Dataset revision"
        case .gpu: "GPU"
        case .vram: "VRAM"
        case .pod: "Pod"
        case .networkStorage: "Network storage"
        case .containerImage: "Container image"
        case .budget: "Budget"
        case .checkpoint: "Checkpoint"
        case .resume: "Resume"
        case .warmStart: "Warm-start"
        case .seed: "Seed"
        case .prompt: "Prompt"
        case .trainingSteps: "Training steps"
        case .learningRate: "Learning rate"
        case .rank: "LoRA rank"
        case .alpha: "LoRA alpha"
        case .batchSize: "Batch size"
        case .gradientAccumulation: "Gradient accumulation"
        case .resolution: "Resolution"
        case .fps: "Frames per second"
        case .loss: "Loss"
        case .precision: "Precision"
        case .trainingRecipe: "Training recipe"
        case .dataset: "Dataset"
        }
    }

    var definition: String {
        switch self {
        case .train:
            "Adjust a model using examples so it can generate something it did not previously know well. "
                + "Training here runs on a rented GPU computer, not on your Mac."
        case .diffusionModels:
            "AI models that generate images or videos by turning noise into an image through a series of steps. "
                + "A text prompt guides what they generate."
        case .baseModel:
            "The existing image or video model you start with, before training your concept. "
                + "Your trained LoRA must be used with a compatible base model."
        case .concept:
            "The one thing you want the model to learn: for example, a person’s identity, an object, "
                + "an art style or an activity. It is the subject of this project, not a caption for one photo."
        case .trainingData:
            "The photos or video clips used as examples during training, paired with captions. "
                + "They should show the concept clearly, with enough variation to distinguish it from other details."
        case .caption:
            "Text paired with one training image or clip. It names your concept by its trigger and class noun, "
                + "then describes the other visible details or action. This helps guide what the model learns."
        case .conceptBoundary:
            "The distinction between the concept named by the trigger and everything else described in the caption. "
                + "For a person, defining appearance belongs to the concept. Pose, clothing and setting are described."
        case .trigger:
            "A distinctive identifier such as NORA7. Captions use it to name your concept, "
                + "and you include it in a generation prompt when you want that concept to appear."
        case .classNoun:
            "A general word for the kind of concept, such as person, ceramic vase or painting style. "
                + "It accompanies the trigger so the model knows what the trigger refers to."
        case .lora:
            "LoRA means Low-Rank Adaptation: a small file containing the changes learned during training. "
                + "Load it alongside a compatible base model in an image or video generation application."
        case .mapping:
            "The assignment of a concept to a subject in one training sample. Person, object and character concepts "
                + "use a locator. Style and motion concepts apply to the whole sample automatically. "
                + "Your confirmed assignment determines which triggers belong in that sample's caption."
        case .locator:
            "A short description that identifies the intended subject, such as ‘the person on the left’. "
                + "It tells the caption model which subject a trigger refers to; "
                + "it does not replace your concept boundary."
        case .captionFormat:
            "The profile of instructions that shapes caption text for the diffusion model you will train. "
                + "For example, FLUX uses prose while H3 uses three named fields. Choosing a format does not "
                + "make an incompatible clip or base model compatible."
        case .provider:
            "The service that runs your captioning or review model. Its account grants access and determines billing. "
                + "OpenAI API credits and an authorized ChatGPT plan are separate choices in this app."
        case .apiKey:
            "A credential that lets the app send requests under a provider account through its API "
                + "(application programming interface). Usage is charged or limited by that provider. "
                + "Enter the key in Settings; it is not a caption or a project instruction."
        case .keychain:
            "macOS's protected credential storage. ConceptStudio stores provider keys and sign-in tokens there, "
                + "separately from the project job, captions and exported training files."
        case .gateway:
            "A service that provides one connection to models run by several providers. Select a model through "
                + "the gateway and use its credential; its available models, prices and limits belong to that account."
        case .reviewer:
            "An optional second model that checks a proposed caption against the job instructions and supplied media. "
                + "It can approve or reject the caption with notes. It makes additional model requests and "
                + "does not replace your review of the saved text."
        case .tokens:
            "The small chunks a language model uses to process text and media. Input tokens cover the instructions "
                + "and supplied evidence; output tokens cover its reply. Providers use token counts for context limits "
                + "and often for billing. One token is not always one word."
        case .thinking:
            "A model's reasoning setting, when its provider supports one. More reasoning can take longer and "
                + "consume more allowance. A model may keep that reasoning private; the saved result is the caption."
        case .structuredOutput:
            "A request for the model to return fields in a defined schema, such as usable, caption and note. "
                + "The app decodes those fields before saving a caption. This controls the reply's structure, "
                + "not whether its observations are correct."
        case .datasetRevision:
            "The specific saved version of a dataset on Hugging Face, identified by a commit. A recorded revision "
                + "lets a run reuse that version instead of later remote edits. Direct uploads use a digest of "
                + "the local inputs instead; Resume requires those original inputs."
        case .gpu:
            "A graphics processing unit: the processor that runs the large caption and training models. "
                + "ConceptStudio rents it in a remote computer. One GPU captions then trains; with several, "
                + "GPU 0 can caption while the remaining GPUs train."
        case .vram:
            "Video random-access memory, the memory on each GPU. Models and media batches use it; it is separate "
                + "from the computer's ordinary RAM. Compatible offloading recipes can keep some state in "
                + "ordinary RAM to reduce GPU memory demand, usually slowing processing."
        case .pod:
            "A rented RunPod computer running the app's captioning or trainer image. GPU charges continue while "
                + "it runs. Stop ends GPU work; separately billed network storage remains available for saved files."
        case .networkStorage:
            "The persistent drive attached to a rented computer. Datasets, checkpoints and results stored there "
                + "survive stopping or replacing that computer. The storage is billed separately and must be "
                + "connected again to continue a saved run or retrieve its files."
        case .containerImage:
            "The packaged software environment used to start the rented computer. It includes the control agent, "
                + "trainer and required libraries. The chosen training model must have a compatible image; "
                + "it is separate from your dataset and LoRA weights."
        case .budget:
            "A GPU spending cap. The whole-computer cap covers the rental; the training-run cap covers "
                + "preparation, transfer and that run's continuations. Reaching either stops the computer. "
                + "Estimates exclude separately billed storage, and checks require this Mac awake with the app open."
        case .checkpoint:
            "A version of the trained weights saved at a particular step. A trainer may also need its saved "
                + "optimizer and random state to Resume. A LoRA weight file alone can initialize a new run "
                + "but does not by itself restore the original training state."
        case .resume:
            "Continue the same saved training run from its latest supported checkpoint and state, using its "
                + "original dataset and settings. The selected total step count includes already completed steps. "
                + "Changed inputs require a new run instead."
        case .warmStart:
            "Start a new training run using existing LoRA weights rather than the base model alone. "
                + "The new run starts its step count at zero and uses the selected dataset. Import the matching "
                + "H3 recipe and weights; this does not restore the old run's optimizer or progress."
        case .seed:
            "A number used to initialize random choices in training or generation. Matched base/LoRA comparisons "
                + "use the same seed and prompt. It helps compare results under the same choices but "
                + "does not guarantee identical results across different software or hardware."
        case .prompt:
            "The instructions given to a model. A generation prompt describes the picture or video you want "
                + "and includes your concept trigger. A training caption describes an actual example; "
                + "it should not invent what you would like that example to contain."
        case .trainingSteps:
            "The number of updates made to the model during training. More steps mean more work and GPU time, "
                + "not automatically better identity or style. Compare saved checkpoints to choose a useful result."
        case .learningRate:
            "How large each training update is, often abbreviated LR. A larger value changes the model faster "
                + "but can lose useful behavior. Keep the selected recipe's value unless you intend to test a change."
        case .rank:
            "The size of the LoRA's learned adjustment. A higher rank has more parameters and uses more memory "
                + "and disk space. Imported starting weights require their matching rank."
        case .alpha:
            "The LoRA's scaling value. Its relationship to rank controls the scale of the learned adjustment "
                + "in the selected trainer. Preserve the matching recipe's value when comparing or continuing a run."
        case .batchSize:
            "How many training examples are processed together in one batch. Larger batches use more GPU memory. "
                + "Gradient accumulation can combine several smaller batches before one model update."
        case .gradientAccumulation:
            "How many batches contribute gradients before the trainer updates the model. It increases the "
                + "effective batch without processing all those examples simultaneously, but adds work per update."
        case .resolution:
            "The pixel dimensions used for training or generation. Higher resolution requires more memory and work. "
                + "Approved video's actual dimensions are retained; changing a training cap does not silently "
                + "crop or resize that clip. Approve a different segment to change it."
        case .fps:
            "Frames per second (fps): how many video frames are shown in one second. MiniMax H3's approved clips use "
                + "exactly 24 fps and its supported frame counts. Approval preserves the selected frames and timing; "
                + "choosing a model does not silently retime another frame rate."
        case .loss:
            "The trainer's numerical measure of error on its training objective. Its curve helps you inspect "
                + "progress or failures. Lower loss alone does not establish that generated images or "
                + "videos preserve identity or look better."
        case .precision:
            "The numerical format used for model weights and computation, such as BF16 or FP16. Quantization "
                + "uses fewer bits for some values to reduce memory use. These choices affect memory and "
                + "behavior; preserve the known recipe when continuing existing work."
        case .trainingRecipe:
            "The trainer settings used for a run, including model components, precision, optimizer and LoRA layers. "
                + "Importing a supported H3 recipe preserves those choices while this project's dataset and "
                + "the new run's length are selected separately."
        case .dataset:
            "The included training images or approved video segments together with their saved captions. "
                + "A project can upload these directly when training starts or publish them to a configured "
                + "Hugging Face dataset. Excluded samples and local reference faces are not training inputs."
        }
    }

    static func matching(_ text: String) -> StudioTerm? {
        allCases.first { $0.title.localizedCaseInsensitiveCompare(text) == .orderedSame }
    }

    static func search(_ text: String) -> [StudioTerm] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = query.isEmpty ? allCases : allCases.filter {
            $0.title.localizedStandardContains(query) || $0.definition.localizedStandardContains(query)
                || $0.rawValue.localizedStandardContains(query)
        }
        return terms.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
