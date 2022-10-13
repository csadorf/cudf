/*
 * Copyright (c) 2020-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cudf/strings/detail/utf8.hpp>
#include <cudf/strings/detail/utilities.cuh>
#include <cudf/strings/side_type.hpp>
#include <cudf/strings/string_view.cuh>

namespace cudf {
namespace strings {
namespace detail {

__device__ size_type compute_padded_size(string_view d_str,
                                         size_type width,
                                         size_type fill_char_size)
{
  auto const length = d_str.length();
  auto bytes        = d_str.size_bytes();
  if (width > length)                            // no truncating;
    bytes += fill_char_size * (width - length);  // add padding
  return bytes;
}

template <side_type side = side_type::RIGHT>
__device__ void pad_impl(cudf::string_view d_str,
                         cudf::size_type width,
                         cudf::char_utf8 fill_char,
                         char* output)
{
  auto length = d_str.length();
  if constexpr (side == side_type::LEFT) {
    while (length++ < width) {
      output += from_char_utf8(fill_char, output);
    }
    copy_string(output, d_str);
  }
  if constexpr (side == side_type::RIGHT) {
    output = copy_string(output, d_str);
    while (length++ < width) {
      output += from_char_utf8(fill_char, output);
    }
  }
  if constexpr (side == side_type::BOTH) {
    auto const pad_size = width - length;
    // an odd width will right-justify
    auto right_pad = (width & 1) ? pad_size / 2 : (pad_size - pad_size / 2);
    auto left_pad  = pad_size - right_pad;  // e.g. width=7: "++foxx+"; width=6: "+fox++"
    while (left_pad-- > 0) {
      output += from_char_utf8(fill_char, output);
    }
    output = copy_string(output, d_str);
    while (right_pad-- > 0) {
      output += from_char_utf8(fill_char, output);
    }
  }
}

__device__ void zfill_impl(cudf::string_view d_str, cudf::size_type width, char* output)
{
  auto length = d_str.length();
  auto in_ptr = d_str.data();
  // if the string starts with a sign, output the sign first
  if (!d_str.empty() && (*in_ptr == '-' || *in_ptr == '+')) {
    *output++ = *in_ptr++;
    d_str     = cudf::string_view{in_ptr, d_str.size_bytes() - 1};
  }
  while (length++ < width)
    *output++ = '0';  // prepend zero char
  copy_string(output, d_str);
}

}  // namespace detail
}  // namespace strings
}  // namespace cudf
