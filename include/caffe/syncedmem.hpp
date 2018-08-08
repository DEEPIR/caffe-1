#ifndef CAFFE_SYNCEDMEM_HPP_
#define CAFFE_SYNCEDMEM_HPP_

#include <cstdlib>
#include <mutex>

#ifdef USE_MKL
#include "mkl.h"
#endif

#include "caffe/common.hpp"

namespace caffe {

/**
 * @brief Manages memory allocation and synchronization between the host (CPU)
 *        and device (GPU).
 *
 * TODO(dox): more thorough description.
 */
class SyncedMemory final {
public:
  explicit SyncedMemory(size_t size);
  ~SyncedMemory();
  const void *cpu_data();
  void set_cpu_data(void *data);
  const void *gpu_data();
  void set_gpu_data(void *data);
  void *mutable_cpu_data();
  void *mutable_gpu_data();
  size_t size() { return size_; }
  enum SyncedHead { UNINITIALIZED, HEAD_AT_CPU, HEAD_AT_GPU, SYNCED };
  SyncedHead head() const { return head_; }

private:
  void check_device();

  void to_cpu();
  void to_gpu(bool init_gpu_data);
  void *cpu_ptr_;
  void *gpu_ptr_;
  size_t size_;
  SyncedHead head_;
  bool own_cpu_data_;
  bool cpu_malloc_use_cuda_;
  bool own_gpu_data_;

  void *host_malloc(size_t size);
  void host_free(void *ptr);

  void *gpu_malloc(size_t size);
  void gpu_free(void *data);
  //std::mutex mem_mutex;

  std::shared_ptr<deepir::allocator::buddy_pool> host_pool_;
  std::shared_ptr<deepir::allocator::buddy_pool> device_pool_;

  DISABLE_COPY_AND_ASSIGN(SyncedMemory);
}; // class SyncedMemory

} // namespace caffe

#endif // CAFFE_SYNCEDMEM_HPP_
