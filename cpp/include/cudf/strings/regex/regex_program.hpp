/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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

#include <cudf/strings/regex/flags.hpp>
#include <cudf/types.hpp>

#include <memory>
#include <string>

namespace cudf {
namespace strings {

/**
 * @addtogroup strings_regex
 * @{
 */

/**
 * @brief Regex program class.
 *
 * Create an instance from a regex pattern and use it to call
 * strings APIs. An instance can be reused.
 *
 * See the @ref md_regex "Regex Features" page for details on patterns and APIs the support regex.
 */
struct regex_program {
  struct regex_program_impl;

  /**
   * @brief Create a program from a pattern
   *
   * @param pattern Regex pattern
   * @param flags Regex flags for interpreting special characters in the pattern
   * @param capture Control how capture groups in the pattern are used
   * @return Instance of this object
   */
  static std::unique_ptr<regex_program> create(std::string_view pattern,
                                               regex_flags flags      = regex_flags::DEFAULT,
                                               capture_groups capture = capture_groups::EXTRACT);

  regex_program(regex_program&& other);
  regex_program& operator=(regex_program&& other);

  /**
   * @brief Return the pattern used to create this instance
   *
   * @return regex pattern as a string
   */
  std::string pattern() const;

  /**
   * @brief Return the regex_flags used to create this instance
   *
   * @return regex flags setting
   */
  regex_flags flags() const;

  /**
   * @brief Return the capture_groups used to create this instance
   *
   * @return capture groups setting
   */
  capture_groups capture() const;

  /**
   * @brief Return the number of instructions in this instance
   *
   * @return Number of instructions
   */
  int32_t instructions_count() const;

  /**
   * @brief Return the number of capture groups in this instance
   *
   * @return Number of groups
   */
  int32_t groups_count() const;

  /**
   * @brief Return implementation object
   *
   * @return impl object instance
   */
  regex_program_impl* get_impl() const;

  /**
   * @brief Return the pattern used to create this instance
   *
   * @return regex pattern as a string
   */
  std::size_t compute_working_memory_size(int32_t num_threads) const;

 private:
  regex_program();

  std::string _pattern;
  regex_flags _flags;
  capture_groups _capture;

  std::unique_ptr<regex_program_impl> _impl;

  regex_program(std::string_view pattern, regex_flags flags, capture_groups capture);
};

/** @} */  // end of doxygen group
}  // namespace strings
}  // namespace cudf
