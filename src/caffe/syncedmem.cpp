#include <map>
#include <memory>
#include <shared_mutex>
#include <stdexcept>
#include <thread>

#ifndef CPU_ONLY
#include <deepir/allocator/buddy_pool.hpp>
#endif

#include "caffe/common.hpp"
#include "caffe/syncedmem.hpp"
#include "caffe/util/math_functions.hpp"

#ifndef CPU_ONLY

#endif

namespace caffe {

SyncedMemory::SyncedMemory(size_t size)
    : cpu_ptr_(NULL), gpu_ptr_(NULL), size_(size), head_(UNINITIALIZED),
      own_cpu_data_(false), cpu_malloc_use_cuda_(false), own_gpu_data_(false) {}

SyncedMemory::~SyncedMemory() {
  check_device();
  if (cpu_ptr_ && own_cpu_data_) {
    host_free(cpu_ptr_);
  }

#ifndef CPU_ONLY
  if (gpu_ptr_ && own_gpu_data_) {
    gpu_free(gpu_ptr_);
  }
#endif // CPU_ONLY
}

inline void SyncedMemory::to_cpu() {
  check_device();
  switch (head_) {
  case UNINITIALIZED:
    cpu_ptr_ = host_malloc(size_);
    caffe_memset(size_, 0, cpu_ptr_);
    head_ = HEAD_AT_CPU;
    own_cpu_data_ = true;
    break;
  case HEAD_AT_GPU:
#ifndef CPU_ONLY
    if (cpu_ptr_ == NULL) {
      cpu_ptr_ = host_malloc(size_);
      own_cpu_data_ = true;
    }
    CUDA_CHECK(cudaMemcpyAsync(cpu_ptr_, gpu_ptr_, size_, cudaMemcpyDefault,
                               cudaStreamPerThread)); // NOLINT(caffe/alt_fn)
    CUDA_CHECK(cudaStreamSynchronize(cudaStreamPerThread));
    head_ = SYNCED;
#else
    NO_GPU;
#endif
    break;
  case HEAD_AT_CPU:
  case SYNCED:
    break;
  }
}

inline void SyncedMemory::to_gpu(bool init_gpu_data) {
  check_device();
#ifndef CPU_ONLY
  switch (head_) {
  case UNINITIALIZED:
    gpu_ptr_ = gpu_malloc(size_);
    if (init_gpu_data) {
      CUDA_CHECK(cudaMemsetAsync(gpu_ptr_, 0, size_, cudaStreamPerThread));
    }
    head_ = HEAD_AT_GPU;
    own_gpu_data_ = true;
    break;
  case HEAD_AT_CPU:
    if (gpu_ptr_ == NULL) {
      gpu_ptr_ = gpu_malloc(size_);
      own_gpu_data_ = true;
    }
    CUDA_CHECK(cudaMemcpyAsync(gpu_ptr_, cpu_ptr_, size_, cudaMemcpyDefault,
                               cudaStreamPerThread)); // NOLINT(caffe/alt_fn)
    CUDA_CHECK(cudaStreamSynchronize(cudaStreamPerThread));
    head_ = SYNCED;
    break;
  case HEAD_AT_GPU:
  case SYNCED:
    break;
  }
#else
  NO_GPU;
#endif
}

const void *SyncedMemory::cpu_data() {
  check_device();
  to_cpu();
  return (const void *)cpu_ptr_;
}

void SyncedMemory::set_cpu_data(void *data) {
  check_device();
  CHECK(data);
  if (own_cpu_data_) {
    host_free(cpu_ptr_);
  }
  cpu_ptr_ = data;
  head_ = HEAD_AT_CPU;
  own_cpu_data_ = false;
}

const void *SyncedMemory::gpu_data() {
  check_device();
#ifndef CPU_ONLY
  to_gpu(true);
  return (const void *)gpu_ptr_;
#else
  NO_GPU;
  return NULL;
#endif
}

void SyncedMemory::set_gpu_data(void *data) {
  check_device();
#ifndef CPU_ONLY
  CHECK(data);
  if (own_gpu_data_) {
    gpu_free(gpu_ptr_);
  }
  gpu_ptr_ = data;
  head_ = HEAD_AT_GPU;
  own_gpu_data_ = false;
#else
  NO_GPU;
#endif
}

void *SyncedMemory::mutable_cpu_data() {
  check_device();
  to_cpu();
  head_ = HEAD_AT_CPU;
  return cpu_ptr_;
}

void *SyncedMemory::mutable_gpu_data() {
  check_device();
#ifndef CPU_ONLY
  to_gpu(true);
  head_ = HEAD_AT_GPU;
  return gpu_ptr_;
#else
  NO_GPU;
  return NULL;
#endif
}

void SyncedMemory::check_device() {
#ifndef CPU_ONLY
#ifdef DEBUG
  int device;
  cudaGetDevice(&device);
  CHECK(device == device_);
  if (gpu_ptr_ && own_gpu_data_) {
    cudaPointerAttributes attributes;
    CUDA_CHECK(cudaPointerGetAttributes(&attributes, gpu_ptr_));
    CHECK(attributes.device == device_);
  }
#endif
#endif
}

#ifndef CPU_ONLY
void *SyncedMemory::gpu_malloc(size_t size) {
  device_id_ = Caffe::GetDevice();
  CHECK(device_id_ >= 0) << "device allocation of size " << size << " failed";

  void *ptr = deepir::allocator::buddy_pool::alloc_device(device_id_, size);
  if (ptr) {
    return ptr;
  }

  CUDA_CHECK(cudaMalloc(&ptr, size));
  return ptr;
}

void SyncedMemory::gpu_free(void *data) {
  if (!data) {
    return;
  }

  CUDA_CHECK(cudaStreamSynchronize(cudaStreamPerThread));
  if (deepir::allocator::buddy_pool::free_device(device_id_, data)) {
    return;
  }
  CUDA_CHECK(cudaFree(data));
}
#endif

// If CUDA is available and in GPU mode, host memory will be allocated pinned,
// using cudaMallocHost. It avoids dynamic pinning for transfers (DMA).
// The improvement in performance seems negligible in the single GPU case,
// but might be more significant for parallel training. Most importantly,
// it improved stability for large models on many GPUs.
void *SyncedMemory::host_malloc(size_t size) {
  void *ptr = nullptr;
#ifndef CPU_ONLY
  constexpr size_t pinned_memory_max_size = 128;
  if (Caffe::mode() == Caffe::GPU && size <= pinned_memory_max_size) {
    ptr = deepir::allocator::buddy_pool::alloc_host(size);
    if (ptr) {
      cpu_malloc_use_cuda_ = true;
      return ptr;
    }

    if (cudaMallocHost(&ptr, size) == cudaSuccess) {
      CHECK(ptr) << "host allocation of size " << size << " failed";
      cpu_malloc_use_cuda_ = true;
      return ptr;
    }
  }
#endif
#ifdef USE_MKL
  ptr = mkl_malloc(size ? size : 1, 64);
#else
  ptr = malloc(size);
#endif
  cpu_malloc_use_cuda_ = false;
  CHECK(ptr) << "host allocation of size " << size << " failed";
  return ptr;
}

void SyncedMemory::host_free(void *ptr) {
#ifndef CPU_ONLY
  if (cpu_malloc_use_cuda_) {
    if (deepir::allocator::buddy_pool::free_host(ptr)) {
      return;
    }
    CUDA_CHECK(cudaFreeHost(ptr));
    return;
  }
#endif
#ifdef USE_MKL
  mkl_free(ptr);
#else
  free(ptr);
#endif
}

} // namespace caffe
