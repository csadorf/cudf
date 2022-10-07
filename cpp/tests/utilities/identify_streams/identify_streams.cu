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

#include <cxxabi.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <iostream>

/*
  Print the stack trace from the current frame.
  Adapted from from https://panthema.net/2008/0901-stacktrace-demangled/
*/
__host__ void print_trace()
{
#ifdef __GNUC__
  // Try to get the stack trace.
  constexpr int kMaxStackDepth = 64;
  void* stack[kMaxStackDepth];
  auto depth   = backtrace(stack, kMaxStackDepth);
  auto strings = backtrace_symbols(stack, depth);

  if (strings == nullptr) {
    std::cout << "No stack trace could be found!" << std::endl;
  } else {
    // If we were able to extract a trace, parse it, demangle symbols, and
    // print a readable output.

    // allocate string which will be filled with the demangled function name
    size_t funcnamesize = 256;
    char* funcname      = (char*)malloc(funcnamesize);

    // Start at frame 1 to skip print_trace itself.
    for (int i = 1; i < depth; ++i) {
      char* begin_name   = nullptr;
      char* begin_offset = nullptr;
      char* end_offset   = nullptr;

      // find parentheses and +address offset surrounding the mangled name:
      // ./module(function+0x15c) [0x8048a6d]
      for (char* p = strings[i]; *p; ++p) {
        if (*p == '(') {
          begin_name = p;
        } else if (*p == '+') {
          begin_offset = p;
        } else if (*p == ')' && begin_offset) {
          end_offset = p;
          break;
        }
      }

      if (begin_name && begin_offset && end_offset && begin_name < begin_offset) {
        *begin_name++   = '\0';
        *begin_offset++ = '\0';
        *end_offset     = '\0';

        // mangled name is now in [begin_name, begin_offset) and caller offset
        // in [begin_offset, end_offset). now apply __cxa_demangle():

        int status;
        char* ret = abi::__cxa_demangle(begin_name, funcname, &funcnamesize, &status);
        if (status == 0) {
          funcname = ret;  // use possibly realloc()-ed string (__cxa_demangle may realloc funcname)
          std::cout << "#" << i << " in " << strings[i] << " : " << funcname << "+" << begin_offset
                    << std::endl;
        } else {
          // demangling failed. Output function name as a C function with no arguments.
          std::cout << "#" << i << " in " << strings[i] << " : " << begin_name << "()+"
                    << begin_offset << std::endl;
        }
      } else {
        std::cout << "#" << i << " in " << strings[i] << std::endl;
      }
    }

    free(funcname);
  }
  free(strings);
#else
  std::cout << "Backtraces are only support on GNU systems." << std::endl;
#endif  // __GNUC__
}

// clang-format off
/*
   We need to overload all the functions from the runtime API (assuming that we
   don't use the driver API) that accept streams. Here's a complete listing of
   the API pages that contain any APIs using streams as of 9/20/2022:
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__STREAM.html
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__EVENT.html#group__CUDART__EVENT
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__EXTRES__INTEROP.html#group__CUDART__EXTRES__INTEROP
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__EXECUTION.html#group__CUDART__EXECUTION
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__MEMORY.html#group__CUDART__MEMORY
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__MEMORY__POOLS.html#group__CUDART__MEMORY__POOLS
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__OPENGL__DEPRECATED.html#group__CUDART__OPENGL__DEPRECATED
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__EGL.html#group__CUDART__EGL
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__INTEROP.html#group__CUDART__INTEROP
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__GRAPH.html#group__CUDART__GRAPH
   - https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__HIGHLEVEL.html#group__CUDART__HIGHLEVEL
 */
// clang-format on

using cudaLaunchKernel_t = cudaError_t (*)(const void*, dim3, dim3, void**, size_t, cudaStream_t);

static cudaLaunchKernel_t cudaLaunchKernel_original;

void __attribute__((constructor)) init();
void init()
{
  cudaLaunchKernel_original = (cudaLaunchKernel_t)dlsym(RTLD_NEXT, "cudaLaunchKernel");
}

__host__ cudaError_t cudaLaunchKernel(
  const void* func, dim3 gridDim, dim3 blockDim, void** args, size_t sharedMem, cudaStream_t stream)
{
  if (stream == static_cast<cudaStream_t>(0) || (stream == cudaStreamLegacy) ||
      (stream == cudaStreamPerThread)) {
    std::cout << "Found unexpected default stream!" << std::endl;
    print_trace();
    std::cout << std::endl;
  }
  return cudaLaunchKernel_original(func, gridDim, blockDim, args, sharedMem, stream);
}
