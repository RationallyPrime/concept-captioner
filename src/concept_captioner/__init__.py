"""concept-captioner: concept-boundary captions for diffusion LoRA training.

Compose a run from the injected parts: a model, a skill, a profile, a source and a sink::

    job = Job.load("job.yaml")
    runner = Runner(job=job, captioner=resolve("google:gemini-3.8-flash"))
    await runner.run(LocalFolderSource("images"), SidecarSink("captions"))
"""

from . import skills
from .job import Concept, EndpointSpec, Job
from .models import Resolved, resolve
from .runner import Outcome, Runner, RunSummary
from .skills import Skill
from .sources import LocalFolderSource, SidecarSink

__all__ = [
    "Concept",
    "EndpointSpec",
    "Job",
    "LocalFolderSource",
    "Outcome",
    "Resolved",
    "RunSummary",
    "Runner",
    "SidecarSink",
    "Skill",
    "resolve",
    "skills",
]
__version__ = "0.2.0"
