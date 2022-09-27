# Copyright (c) 2022, NVIDIA CORPORATION.

from libcpp.memory cimport unique_ptr
from libcpp.utility cimport move

from cudf.core.buffer import as_device_buffer_like

from cudf._lib.column cimport Column
from cudf._lib.cpp.column.column cimport column, column_view
from rmm._lib.device_buffer cimport DeviceBuffer, device_buffer

from strings_udf._lib.cpp.strings_udf cimport (
    to_string_view_array as cpp_to_string_view_array,
)


def to_string_view_array(Column strings_col):
    cdef unique_ptr[device_buffer] c_buffer
    cdef column_view input_view = strings_col.view()
    c_buffer = move(cpp_to_string_view_array(input_view))
    device_buffer = DeviceBuffer.c_from_unique_ptr(move(c_buffer))
    return as_device_buffer_like(device_buffer, exposed=False)
