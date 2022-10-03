# Copyright (c) 2022, NVIDIA CORPORATION.

from __future__ import annotations

import gc
import io
import os
import threading
import traceback
import warnings
import weakref
from dataclasses import dataclass
from typing import List, MutableMapping, Optional, Tuple

import rmm.mr

from cudf.core.buffer.spillable_buffer import SpillableBuffer
from cudf.utils.string import format_bytes


def get_traceback() -> str:
    with io.StringIO() as f:
        traceback.print_stack(file=f)
        f.seek(0)
        return f.read()


def get_rmm_memory_resource_stack(
    mr: rmm.mr.DeviceMemoryResource,
) -> List[rmm.mr.DeviceMemoryResource]:
    if hasattr(mr, "upstream_mr"):
        return [mr] + get_rmm_memory_resource_stack(mr.upstream_mr)
    return [mr]


@dataclass
class ExposeStatistic:
    traceback: str
    count: int = 1
    total_nbytes: int = 0
    spilled_nbytes: int = 0


class SpillManager:
    _base_buffers: MutableMapping[int, SpillableBuffer]
    _expose_statistics: Optional[MutableMapping[str, ExposeStatistic]]

    def __init__(
        self,
        *,
        spill_on_demand=False,
        device_memory_limit=None,
        expose_statistics=False,
    ) -> None:
        self._lock = threading.Lock()
        self._base_buffers = weakref.WeakValueDictionary()
        self._id_counter = 0
        self._spill_on_demand = spill_on_demand
        self._device_memory_limit = device_memory_limit
        self._expose_statistics = {} if expose_statistics else None

        if self._spill_on_demand:
            # Set the RMM out-of-memory handle if not already set
            mr = rmm.mr.get_current_device_resource()
            if all(
                not isinstance(m, rmm.mr.FailureCallbackResourceAdaptor)
                for m in get_rmm_memory_resource_stack(mr)
            ):
                rmm.mr.set_current_device_resource(
                    rmm.mr.FailureCallbackResourceAdaptor(
                        mr, self._out_of_memory_handle
                    )
                )

    def _out_of_memory_handle(self, nbytes: int, *, retry_once=True) -> bool:
        """Try to handle an out-of-memory error by spilling

        This can by used as the callback function to RMM's
        `FailureCallbackResourceAdaptor`

        Parameters
        ----------
        nbytes : int
            Number of bytes to try to spill.
        retry_once : bool, optional
            If True, call `gc.collect()` and retry once.

        Return
        ------
        bool
            True if any buffers were freed otherwise False.

        Warning
        -------
        In order to avoid deadlock, this function should not lock
        already locked buffers.
        """

        # Keep spilling until `nbytes` been spilled
        total_spilled = 0
        while total_spilled < nbytes:
            spilled = self.spill_device_memory()
            if spilled == 0:
                break  # No more to spill!
            total_spilled += spilled

        if total_spilled > 0:
            return True  # Ask RMM to retry the allocation

        if retry_once:
            # Let's collect garbage and try one more time
            gc.collect()
            return self._out_of_memory_handle(nbytes, retry_once=False)

        # TODO: write to log instead of stdout
        print(
            f"[WARNING] RMM allocation of {format_bytes(nbytes)} bytes "
            "failed, spill-on-demand couldn't find any device memory to "
            f"spill:\n{repr(self)}\ntraceback:\n{get_traceback()}"
        )
        if self._expose_statistics is None:
            print("Set `CUDF_SPILL_STAT_EXPOSE=on` for expose statistics")
        else:
            print(self.pprint_expose_statistics())

        return False  # Since we didn't find anything to spill, we give up

    def add(self, buffer: SpillableBuffer) -> None:
        if buffer.size > 0 and not buffer.exposed:
            with self._lock:
                self._base_buffers[self._id_counter] = buffer
                self._id_counter += 1
        self.spill_to_device_limit()

    def base_buffers(
        self, order_by_access_time: bool = False
    ) -> Tuple[SpillableBuffer, ...]:
        with self._lock:
            ret = tuple(self._base_buffers.values())
        if order_by_access_time:
            ret = tuple(sorted(ret, key=lambda b: b.last_accessed))
        return ret

    def spill_device_memory(self) -> int:
        """Try to spill device memory

        This function is safe to call doing spill-on-demand
        since it does not lock buffers already locked.

        Return
        ------
        int
            Number of bytes spilled.
        """
        for buf in self.base_buffers(order_by_access_time=True):
            if buf.lock.acquire(blocking=False):
                try:
                    if not buf.is_spilled and buf.spillable:
                        buf.__spill__(target="cpu")
                        return buf.size
                finally:
                    buf.lock.release()
        return 0

    def spill_to_device_limit(self, device_limit: int = None) -> int:
        limit = (
            self._device_memory_limit if device_limit is None else device_limit
        )
        if limit is None:
            return 0
        ret = 0
        while True:
            unspilled = sum(
                buf.size for buf in self.base_buffers() if not buf.is_spilled
            )
            if unspilled < limit:
                break
            nbytes = self.spill_device_memory()
            if nbytes == 0:
                break  # No more to spill
            ret += nbytes
        return ret

    def lookup_address_range(
        self, ptr: int, size: int
    ) -> List[SpillableBuffer]:
        ret = []
        for buf in self.base_buffers():
            if buf.is_overlapping(ptr, size):
                ret.append(buf)
        return ret

    def log_expose(self, buf: SpillableBuffer) -> None:
        if self._expose_statistics is None:
            return
        tb = get_traceback()
        stat = self._expose_statistics.get(tb, None)
        spilled_nbytes = buf.nbytes if buf.is_spilled else 0
        if stat is None:
            self._expose_statistics[tb] = ExposeStatistic(
                traceback=tb,
                total_nbytes=buf.nbytes,
                spilled_nbytes=spilled_nbytes,
            )
        else:
            stat.count += 1
            stat.total_nbytes += buf.nbytes
            stat.spilled_nbytes += spilled_nbytes

    def get_expose_statistics(self) -> List[ExposeStatistic]:
        if self._expose_statistics is None:
            return []
        return sorted(self._expose_statistics.values(), key=lambda x: -x.count)

    def pprint_expose_statistics(self) -> str:
        ret = "Expose Statistics:\n"
        for s in self.get_expose_statistics():
            ret += (
                f" Count: {s.count}, total: {format_bytes(s.total_nbytes)}, "
            )
            ret += f"spilled: {format_bytes(s.spilled_nbytes)}\n"
            ret += s.traceback
            ret += "\n"
        return ret

    def __repr__(self) -> str:
        spilled = sum(
            buf.size for buf in self.base_buffers() if buf.is_spilled
        )
        unspilled = sum(
            buf.size for buf in self.base_buffers() if not buf.is_spilled
        )
        unspillable = 0
        for buf in self.base_buffers():
            if not (buf.is_spilled or buf.spillable):
                unspillable += buf.size
        unspillable_ratio = unspillable / unspilled if unspilled else 0

        return (
            f"<SpillManager spill_on_demand={self._spill_on_demand} "
            f"device_memory_limit={self._device_memory_limit} | "
            f"{format_bytes(spilled)} spilled | "
            f"{format_bytes(unspilled)} ({unspillable_ratio:.0%}) "
            f"unspilled (unspillable)>"
        )


# TODO: do we have a common "get-value-from-env" in cuDF?
def _env_get_int(name, default):
    try:
        return int(os.getenv(name, default))
    except (ValueError, TypeError):
        return default


def _env_get_bool(name, default):
    env = os.getenv(name)
    if env is None:
        return default
    as_a_int = _env_get_int(name, None)
    env = env.lower().strip()
    if env == "true" or env == "on" or as_a_int:
        return True
    if env == "false" or env == "off" or as_a_int == 0:
        return False
    return default


def _get_manager_from_env() -> Optional[SpillManager]:
    if not _env_get_bool("CUDF_SPILL", False):
        return None
    return SpillManager(
        spill_on_demand=_env_get_bool("CUDF_SPILL_ON_DEMAND", True),
        device_memory_limit=_env_get_int("CUDF_SPILL_DEVICE_LIMIT", None),
        expose_statistics=_env_get_bool("CUDF_SPILL_STAT_EXPOSE", False),
    )


# The global manager has three states:
#   - Uninitialized
#   - Initialized to None (spilling disabled)
#   - Initialized to a SpillManager instance (spilling enabled)
_global_manager_uninitialized: bool = True
_global_manager: Optional[SpillManager] = None


def global_manager_reset(manager: Optional[SpillManager]) -> None:
    """Set the global manager, which if None disables spilling"""

    global _global_manager, _global_manager_uninitialized
    if _global_manager is not None:
        gc.collect()
        base_buffers = _global_manager.base_buffers()
        if len(base_buffers) > 0:
            warnings.warn(f"overwriting non-empty manager: {base_buffers}")

    _global_manager = manager
    _global_manager_uninitialized = False


def global_manager_get() -> Optional[SpillManager]:
    """Get the global manager or None if spilling is disabled"""
    global _global_manager_uninitialized
    if _global_manager_uninitialized:
        global_manager_reset(_get_manager_from_env())
    return _global_manager
