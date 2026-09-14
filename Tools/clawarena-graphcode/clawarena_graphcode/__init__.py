"""A GraphCode loop as the ClawArena-Team main agent."""

from .provider import GraphCodeProvider, stop_all
from .stub import StubPoolProvider


def register() -> None:
    from clawarena_team.provider import register_provider

    register_provider(GraphCodeProvider.name, GraphCodeProvider)
    register_provider(StubPoolProvider.name, StubPoolProvider)


__all__ = ["GraphCodeProvider", "StubPoolProvider", "register", "stop_all"]
