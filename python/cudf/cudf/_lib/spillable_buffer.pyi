# Copyright (c) 2021, NVIDIA CORPORATION.

from threading import RLock
from typing import Any, Union

from cudf.core.buffer import DeviceBufferLike
from cudf.core.spill_manager import SpillManager

class SpillLock: ...

class SpillableBuffer(DeviceBufferLike):
    def __init__(
        self,
        data: Any,
        exposed: bool,
        manager: SpillManager,
    ): ...
    @property
    def lock(self) -> RLock: ...
    @property
    def is_spilled(self) -> bool: ...
    @property
    def exposed(self) -> bool: ...
    @property
    def spillable(self) -> bool: ...
    @property
    def last_accessed(self) -> float: ...
    @property
    def expose_counter(self) -> int: ...
    def move_inplace(self, target: str) -> None: ...
    def is_overlapping(self, ptr: int, size: int): ...
    def ptr_restricted(self) -> Union[int, SpillLock]: ...
