# Copyright (c) 2022, NVIDIA CORPORATION.

import collections.abc
import pickle
import time
from threading import RLock
from typing import Any, Tuple

import numpy

import rmm

from cudf.core.buffer import (
    DeviceBufferLike,
    get_ptr_and_size,
    is_c_contiguous,
)
from cudf.utils.string import format_bytes

from cython.operator cimport dereference
from libc.stdint cimport uintptr_t
from libcpp.memory cimport make_shared, shared_ptr, static_pointer_cast
from libcpp.vector cimport vector


cdef shared_ptr[void] create_expose_counter():
    """Create a expose counter"""
    return static_pointer_cast[void, int](
        make_shared[int](42)
    )


class DelayedPointerTuple(collections.abc.Sequence):
    """
    A delayed version of the "data" field in __cuda_array_interface__.

    The idea is to delay the access to `Buffer.ptr` until the user
    actually accesses the data pointer.

    For instance, in many cases __cuda_array_interface__ is accessed
    only to determine whether an object is a CUDA object or not.
    """

    def __init__(self, buffer) -> None:
        self._buf = buffer

    def __len__(self):
        return 2

    def __getitem__(self, i):
        if i == 0:
            return self._buf.ptr
        elif i == 1:
            return False
        raise IndexError("tuple index out of range")


cdef class SpillableBuffer():
    """A spillable buffer that represents device memory.

    Developer Notes
    ---------------


    Parameters
    ----------
    data : buffer-like
        An buffer-like object representing device or host memory.
    exposed : bool, optional
        Whether or not a raw pointer (integer or C pointer) has
        been exposed to the outside world. If this is the case,
        the buffer cannot be spilled.
    manager : SpillManager
        The manager overseeing this buffer.
    """
    def __init__(
        self,
        object data,
        bint exposed,
        object manager,
    ):
        self._lock = RLock()
        self._expose_counter = create_expose_counter()
        self._exposed = exposed
        self._last_accessed = time.monotonic()
        self._view_desc = (
            None  # TODO: maybe make a view its own subclass?
        )

        # First, we extract the memory pointer, size, and owner.
        # If it points to host memory we either:
        #   - copy to device memory if exposed=True
        #   - or create a new buffer that are marked as spilled already.
        if isinstance(data, SpillableBuffer):
            raise ValueError(
                "Cannot create from a SpillableBuffer, "
                "use __getitem__ to create a view"
            )
        if isinstance(data, rmm.DeviceBuffer):
            self._ptr_desc = {"type": "gpu"}
            self._ptr = data.ptr
            self._size = data.size
            self._owner = data
        elif hasattr(data, "__cuda_array_interface__"):
            self._ptr_desc = {"type": "gpu"}
            ptr, size = get_ptr_and_size(data.__cuda_array_interface__)
            self._ptr = ptr
            self._size = size
            self._owner = data
        else:
            if self._exposed:
                self._ptr_desc = {"type": "gpu"}
                ptr, size = get_ptr_and_size(
                    numpy.array(data).__array_interface__
                )
                buf = rmm.DeviceBuffer(ptr=ptr, size=size)
                self._ptr = buf.ptr
                self._size = buf.size
                self._owner = buf
                # Since we are copying the data, we know that the device
                # memory has not been exposed even if the original host
                # memory has been exposed.
                self._exposed = False
            else:
                data = memoryview(data)
                if not data.c_contiguous:
                    raise ValueError("memoryview must be C-contiguous")
                self._ptr_desc = {"type": "cpu", "memoryview": data}
                self._ptr = 0
                self._size = data.nbytes
                self._owner = None

        # Then, we inform the spilling manager about this new buffer if:
        #  - it is not already known to the spilling manager
        #  - and the buffer hasn't been exposed (exposed=False)
        self._manager = manager
        base = self._manager.lookup_address_range(
            self._ptr, self._size
        )
        if base is not None:
            base.ptr  # expose base buffer
        elif not self._exposed:
            # `self` is a base buffer that hasn't been exposed
            self._manager.add(self)

        # Finally, we spill until we comply with the device limit (if any).
        self._manager.spill_to_device_limit()

    @property
    def lock(self) -> RLock:
        if self._view_desc:
            raise ValueError("views does not have a lock")
        return self._lock

    @property
    def is_spilled(self) -> bool:
        if self._view_desc:
            return self._view_desc["base"].is_spilled
        return self._ptr_desc["type"] != "gpu"

    def move_inplace(self, target: str = "cpu") -> None:
        assert self._view_desc is None
        with self._lock:
            ptr_type = self._ptr_desc["type"]
            if ptr_type == target:
                return

            if not self.spillable:
                raise ValueError(
                    f"Cannot in-place move an unspillable buffer: {self}"
                )

            if (ptr_type, target) == ("gpu", "cpu"):
                host_mem = memoryview(bytearray(self.size))
                rmm._lib.device_buffer.copy_ptr_to_host(self._ptr, host_mem)
                self._ptr_desc["memoryview"] = host_mem
                self._ptr = 0
                self._owner = None
            elif (ptr_type, target) == ("cpu", "gpu"):
                dev_mem = rmm.DeviceBuffer.to_device(
                    self._ptr_desc.pop("memoryview")
                )
                self._ptr = dev_mem.ptr
                self._size = dev_mem.size
                self._owner = dev_mem
            else:
                # TODO: support moving to disk
                raise ValueError(f"Unknown target: {target}")
            self._ptr_desc["type"] = target

    @property
    def ptr(self) -> int:
        """Access the memory directly

        Notice, this will mark the buffer as "exposed" and make
        it unspillable permanently.
        """
        if self._view_desc:
            return self._view_desc["base"].ptr + self._view_desc["offset"]
        self._manager.spill_to_device_limit()
        with self._lock:
            self.move_inplace(target="gpu")
            self._exposed = True
            self._last_accessed = time.monotonic()
            return self._ptr

    cdef void* ptr_raw(self, shared_ptr[OwnersVecT] owners) except *:
        # Get base buffer
        cdef SpillableBuffer base
        cdef size_t offset
        if self._view_desc is None:
            base = self
            offset = 0
        else:
            base = self._view_desc["base"]
            offset = self._view_desc["offset"]

        with base._lock:
            base.move_inplace(target="gpu")
            base._last_accessed = time.monotonic()
            dereference(owners).push_back(base._expose_counter)
            return <void*><uintptr_t> (base._ptr+offset)

    @property
    def owner(self) -> Any:
        return self._owner

    @property
    def exposed(self) -> bool:
        if self._view_desc:
            return self._view_desc["base"].exposed
        return self._exposed

    @property
    def expose_counter(self) -> int:
        if self._view_desc:
            return self._view_desc["base"].expose_counter
        return self._expose_counter.use_count()

    @property
    def spillable(self) -> bool:
        if self._view_desc:
            return self._view_desc["base"].spillable
        return not self._exposed and self._expose_counter.use_count() == 1

    @property
    def size(self) -> int:
        return self._size

    @property
    def nbytes(self) -> int:
        return self._size

    @property
    def last_accessed(self) -> float:
        if self._view_desc:
            return self._view_desc["base"]._last_accessed
        return self._last_accessed

    @property
    def __cuda_array_interface__(self) -> dict:
        return {
            "data": DelayedPointerTuple(self),
            "shape": (self.size,),
            "strides": None,
            "typestr": "|u1",
            "version": 0,
        }

    def memoryview(self) -> memoryview:
        # Get base buffer
        cdef SpillableBuffer base
        cdef size_t offset
        if self._view_desc is None:
            base = self
            offset = 0
        else:
            base = self._view_desc["base"]
            offset = self._view_desc["offset"]

        with base._lock:
            if base.spillable:
                base.move_inplace(target="cpu")
                return base._ptr_desc["memoryview"][
                    offset : offset + self.size
                ]
            else:
                assert base._ptr_desc["type"] == "gpu"
                ret = memoryview(bytearray(self.size))
                rmm._lib.device_buffer.copy_ptr_to_host(
                    base._ptr + offset, ret
                )
                return ret

    def __getitem__(self, slice key) -> SpillableBuffer:
        start, stop, step = key.indices(self.size)
        if step != 1:
            raise ValueError("slice must be C-contiguous")

        # TODO: use a subclass
        return create_view(self, size=stop-start, offset=start)

    def serialize(self) -> Tuple[dict, list]:
        # Get base buffer
        cdef SpillableBuffer base
        if self._view_desc is None:
            base = self
        else:
            base = self._view_desc["base"]

        with base._lock:
            header = {}
            header["type-serialized"] = pickle.dumps(self.__class__)
            header["frame_count"] = 1
            if self.is_spilled:
                frames = [self.memoryview()]
            else:
                frames = [self]
            return header, frames

    @classmethod
    def deserialize(cls, header: dict, frames: list) -> SpillableBuffer:
        from cudf.core.spill_manager import global_manager

        if header["frame_count"] != 1:
            raise ValueError(
                "Deserializing a SpillableBuffer expect a single frame"
            )
        frame, = frames
        if isinstance(frame, SpillableBuffer):
            ret = frame
        else:
            ret = cls(frame, exposed=False, manager=global_manager.get())
        return ret

    def is_overlapping(self, ptr: int, size: int):
        with self._lock:
            return (
                not self.is_spilled and
                (ptr + size) > self._ptr and
                (self._ptr + self._size) > ptr
            )

    def __repr__(self) -> str:
        if self._view_desc is not None:
            return (
                f"<SpillableBuffer size={format_bytes(self._size)} "
                f"view={self._view_desc}"
            )
        if self._ptr_desc["type"] != "gpu":
            ptr_info = str(self._ptr_desc)
        else:
            ptr_info = str(hex(self._ptr))
        return (
            f"<SpillableBuffer size={format_bytes(self._size)} "
            f"spillable={self.spillable} exposed={self.exposed} "
            f"expose_counter={self._expose_counter.use_count()} "
            f"ptr={ptr_info} owner={repr(self._owner)}"
        )

# TODO: use a subclass instead
cdef SpillableBuffer create_view(SpillableBuffer buffer, size, offset):
    if size < 0:
        raise ValueError("size cannot be negative")

    # Get base buffer
    if buffer._view_desc is None:
        base = buffer
        base_offset = 0
    else:
        base = buffer._view_desc["base"]
        base_offset = buffer._view_desc["offset"]

    cdef SpillableBuffer ret = SpillableBuffer.__new__(SpillableBuffer)
    ret._lock = None
    ret._size = size
    ret._owner = base
    ret._view_desc = {"base": base, "offset": base_offset + offset}
    return ret
