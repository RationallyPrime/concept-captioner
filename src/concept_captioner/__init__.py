"""concept-captioner: concept-boundary captions for diffusion LoRA training.

Compose a run from four injected parts::

    endpoint = build_endpoint("openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct")
    profile  = load_profile("h3-still")
    job      = Job.load("job.yaml")
    runner   = Runner(job=job, profile=profile, captioner_endpoint=endpoint)
    await runner.run(LocalFolderSource("images"), SidecarSink("captions"))
"""

from .endpoints import build_endpoint
from .job import Concept, Job
from .profiles import load_profile
from .runner import Runner, RunSummary
from .sources import LocalFolderSource, SidecarSink

__all__ = [
    "Concept",
    "Job",
    "LocalFolderSource",
    "RunSummary",
    "Runner",
    "SidecarSink",
    "build_endpoint",
    "load_profile",
]
__version__ = "0.1.0"
