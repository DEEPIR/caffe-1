#include <algorithm>
#include <functional>
#include <map>
#include <vector>
#include <float.h>

#include "thrust/functional.h"
#include "thrust/sort.h"

#include "caffe/common.hpp"
#include "caffe/util/bbox_util.hpp"

namespace caffe {

template <typename Dtype>
__host__ __device__ Dtype BBoxSizeGPU(const Dtype* bbox,
    const bool normalized) {
  if (bbox[2] < bbox[0] || bbox[3] < bbox[1]) {
    // If bbox is invalid (e.g. xmax < xmin or ymax < ymin), return 0.
    return Dtype(0.);
  } else {
    const Dtype width = bbox[2] - bbox[0];
    const Dtype height = bbox[3] - bbox[1];
    if (normalized) {
      return width * height;
    } else {
      // If bbox is not within range [0, 1].
      return (width + 1) * (height + 1);
    }
  }
}

template __host__ __device__ float BBoxSizeGPU(const float* bbox,
    const bool normalized);
template __host__ __device__ double BBoxSizeGPU(const double* bbox,
    const bool normalized);

template <typename Dtype>
__host__ __device__ Dtype JaccardOverlapGPU(const Dtype* bbox1,
    const Dtype* bbox2) {
  if (bbox2[0] > bbox1[2] || bbox2[2] < bbox1[0] ||
      bbox2[1] > bbox1[3] || bbox2[3] < bbox1[1]) {
    return Dtype(0.);
  } else {
    const Dtype inter_xmin = max(bbox1[0], bbox2[0]);
    const Dtype inter_ymin = max(bbox1[1], bbox2[1]);
    const Dtype inter_xmax = min(bbox1[2], bbox2[2]);
    const Dtype inter_ymax = min(bbox1[3], bbox2[3]);

    const Dtype inter_width = inter_xmax - inter_xmin;
    const Dtype inter_height = inter_ymax - inter_ymin;
    const Dtype inter_size = inter_width * inter_height;

    const Dtype bbox1_size = BBoxSizeGPU(bbox1);
    const Dtype bbox2_size = BBoxSizeGPU(bbox2);

    return inter_size / (bbox1_size + bbox2_size - inter_size);
  }
}

template __host__ __device__ float JaccardOverlapGPU(const float* bbox1,
    const float* bbox2);
template __host__ __device__ double JaccardOverlapGPU(const double* bbox1,
    const double* bbox2);

template <typename Dtype>
__device__ Dtype Min(const Dtype x, const Dtype y) {
  return x < y ? x : y;
}

template <typename Dtype>
__device__ Dtype Max(const Dtype x, const Dtype y) {
  return x > y ? x : y;
}

template <typename Dtype>
__device__ void ClipBBoxGPU(const Dtype* bbox, Dtype* clip_bbox) {
  for (int i = 0; i < 4; ++i) {
    clip_bbox[i] = Max(Min(bbox[i], Dtype(1.)), Dtype(0.));
  }
}

template __device__ void ClipBBoxGPU(const float* bbox, float* clip_bbox);
template __device__ void ClipBBoxGPU(const double* bbox, double* clip_bbox);

template <typename Dtype>
__global__ void DecodeBBoxesKernel(const int nthreads,
          const Dtype* loc_data, const Dtype* prior_data,
          const CodeType code_type, const bool variance_encoded_in_target,
          const int num_priors, const bool share_location,
          const int num_loc_classes, const int background_label_id,
          const bool clip_bbox, Dtype* bbox_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    const int i = index % 4;
    const int c = (index / 4) % num_loc_classes;
    const int d = (index / 4 / num_loc_classes) % num_priors;
    if (!share_location && c == background_label_id) {
      // Ignore background class if not share_location.
      return;
    }
    const int pi = d * 4;
    const int vi = pi + num_priors * 4;
    if (code_type == PriorBoxParameter_CodeType_CORNER) {
      if (variance_encoded_in_target) {
        // variance is encoded in target, we simply need to add the offset
        // predictions.
        bbox_data[index] = prior_data[pi + i] + loc_data[index];
      } else {
        // variance is encoded in bbox, we need to scale the offset accordingly.
        bbox_data[index] =
          prior_data[pi + i] + loc_data[index] * prior_data[vi + i];
      }
    } else if (code_type == PriorBoxParameter_CodeType_CENTER_SIZE) {
      const Dtype p_xmin = prior_data[pi];
      const Dtype p_ymin = prior_data[pi + 1];
      const Dtype p_xmax = prior_data[pi + 2];
      const Dtype p_ymax = prior_data[pi + 3];
      const Dtype prior_width = p_xmax - p_xmin;
      const Dtype prior_height = p_ymax - p_ymin;
      const Dtype prior_center_x = (p_xmin + p_xmax) / 2.;
      const Dtype prior_center_y = (p_ymin + p_ymax) / 2.;

      const Dtype xmin = loc_data[index - i];
      const Dtype ymin = loc_data[index - i + 1];
      const Dtype xmax = loc_data[index - i + 2];
      const Dtype ymax = loc_data[index - i + 3];

      Dtype decode_bbox_center_x, decode_bbox_center_y;
      Dtype decode_bbox_width, decode_bbox_height;
      if (variance_encoded_in_target) {
        // variance is encoded in target, we simply need to retore the offset
        // predictions.
        decode_bbox_center_x = xmin * prior_width + prior_center_x;
        decode_bbox_center_y = ymin * prior_height + prior_center_y;
        decode_bbox_width = exp(xmax) * prior_width;
        decode_bbox_height = exp(ymax) * prior_height;
      } else {
        // variance is encoded in bbox, we need to scale the offset accordingly.
        decode_bbox_center_x =
          prior_data[vi] * xmin * prior_width + prior_center_x;
        decode_bbox_center_y =
          prior_data[vi + 1] * ymin * prior_height + prior_center_y;
        decode_bbox_width =
          exp(prior_data[vi + 2] * xmax) * prior_width;
        decode_bbox_height =
          exp(prior_data[vi + 3] * ymax) * prior_height;
      }

      switch (i) {
        case 0:
          bbox_data[index] = decode_bbox_center_x - decode_bbox_width / 2.;
          break;
        case 1:
          bbox_data[index] = decode_bbox_center_y - decode_bbox_height / 2.;
          break;
        case 2:
          bbox_data[index] = decode_bbox_center_x + decode_bbox_width / 2.;
          break;
        case 3:
          bbox_data[index] = decode_bbox_center_y + decode_bbox_height / 2.;
          break;
      }
    } else if (code_type == PriorBoxParameter_CodeType_CORNER_SIZE) {
      const Dtype p_xmin = prior_data[pi];
      const Dtype p_ymin = prior_data[pi + 1];
      const Dtype p_xmax = prior_data[pi + 2];
      const Dtype p_ymax = prior_data[pi + 3];
      const Dtype prior_width = p_xmax - p_xmin;
      const Dtype prior_height = p_ymax - p_ymin;
      Dtype p_size;
      if (i == 0 || i == 2) {
        p_size = prior_width;
      } else {
        p_size = prior_height;
      }
      if (variance_encoded_in_target) {
        // variance is encoded in target, we simply need to add the offset
        // predictions.
        bbox_data[index] = prior_data[pi + i] + loc_data[index] * p_size;
      } else {
        // variance is encoded in bbox, we need to scale the offset accordingly.
        bbox_data[index] =
          prior_data[pi + i] + loc_data[index] * prior_data[vi + i] * p_size;
      }
    } else {
      // Unknown code type.
    }
    if (clip_bbox) {
      bbox_data[index] = max(min(bbox_data[index], Dtype(1.)), Dtype(0.));
    }
  }
}

template <typename Dtype>
void DecodeBBoxesGPU(const int nthreads,
          const Dtype* loc_data, const Dtype* prior_data,
          const CodeType code_type, const bool variance_encoded_in_target,
          const int num_priors, const bool share_location,
          const int num_loc_classes, const int background_label_id,
          const bool clip_bbox, Dtype* bbox_data) {
  // NOLINT_NEXT_LINE(whitespace/operators)
  DecodeBBoxesKernel<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
      CAFFE_CUDA_NUM_THREADS>>>(nthreads, loc_data, prior_data, code_type,
      variance_encoded_in_target, num_priors, share_location, num_loc_classes,
      background_label_id, clip_bbox, bbox_data);
  CUDA_POST_KERNEL_CHECK;
}

template void DecodeBBoxesGPU(const int nthreads,
          const float* loc_data, const float* prior_data,
          const CodeType code_type, const bool variance_encoded_in_target,
          const int num_priors, const bool share_location,
          const int num_loc_classes, const int background_label_id,
          const bool clip_bbox, float* bbox_data);
template void DecodeBBoxesGPU(const int nthreads,
          const double* loc_data, const double* prior_data,
          const CodeType code_type, const bool variance_encoded_in_target,
          const int num_priors, const bool share_location,
          const int num_loc_classes, const int background_label_id,
          const bool clip_bbox, double* bbox_data);

template <typename Dtype>
__global__ void PermuteDataKernel(const int nthreads,
          const Dtype* data, const int num_classes, const int num_data,
          const int num_dim, Dtype* new_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    const int i = index % num_dim;
    const int c = (index / num_dim) % num_classes;
    const int d = (index / num_dim / num_classes) % num_data;
    const int n = index / num_dim / num_classes / num_data;
    const int new_index = ((n * num_classes + c) * num_data + d) * num_dim + i;
    new_data[new_index] = data[index];
  }
}

template <typename Dtype>
void PermuteDataGPU(const int nthreads,
          const Dtype* data, const int num_classes, const int num_data,
          const int num_dim, Dtype* new_data) {
  // NOLINT_NEXT_LINE(whitespace/operators)
  PermuteDataKernel<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
      CAFFE_CUDA_NUM_THREADS>>>(nthreads, data, num_classes, num_data,
      num_dim, new_data);
  CUDA_POST_KERNEL_CHECK;
}

template void PermuteDataGPU(const int nthreads,
          const float* data, const int num_classes, const int num_data,
          const int num_dim, float* new_data);
template void PermuteDataGPU(const int nthreads,
          const double* data, const int num_classes, const int num_data,
          const int num_dim, double* new_data);

template <typename Dtype>
__global__ void kernel_channel_max(const int num, const int channels,
    const int spatial_dim, const Dtype* data, Dtype* out) {
  CUDA_KERNEL_LOOP(index, num * spatial_dim) {
    int n = index / spatial_dim;
    int s = index % spatial_dim;
    Dtype maxval = -FLT_MAX;
    for (int c = 0; c < channels; ++c) {
      maxval = max(data[(n * channels + c) * spatial_dim + s], maxval);
    }
    out[index] = maxval;
  }
}

template <typename Dtype>
__global__ void kernel_channel_subtract(const int count,
    const int num, const int channels,
    const int spatial_dim, const Dtype* channel_data, const Dtype* channel_max,
    Dtype* data) {
  CUDA_KERNEL_LOOP(index, count) {
    int n = index / channels / spatial_dim;
    int s = index % spatial_dim;
    data[index] = channel_data[index] - channel_max[n * spatial_dim + s];
  }
}

template <typename Dtype>
__global__ void kernel_exp(const int count, const Dtype* data, Dtype* out) {
  CUDA_KERNEL_LOOP(index, count) {
    out[index] = exp(data[index]);
  }
}

template <typename Dtype>
__global__ void kernel_channel_sum(const int num, const int channels,
    const int spatial_dim, const Dtype* data, Dtype* channel_sum) {
  CUDA_KERNEL_LOOP(index, num * spatial_dim) {
    int n = index / spatial_dim;
    int s = index % spatial_dim;
    Dtype sum = 0;
    for (int c = 0; c < channels; ++c) {
      sum += data[(n * channels + c) * spatial_dim + s];
    }
    channel_sum[index] = sum;
  }
}

template <typename Dtype>
__global__ void kernel_channel_div(const int count,
    const int num, const int channels,
    const int spatial_dim, const Dtype* channel_sum, Dtype* data) {
  CUDA_KERNEL_LOOP(index, count) {
    int n = index / channels / spatial_dim;
    int s = index % spatial_dim;
    data[index] /= channel_sum[n * spatial_dim + s];
  }
}

template <typename Dtype>
void SoftMaxGPU(const Dtype* data, const int outer_num,
    const int channels, const int inner_num, Dtype* prob) {
  vector<int> shape(4, 1);
  shape[0] = outer_num;
  shape[1] = channels;
  shape[2] = inner_num;
  Blob<Dtype> scale(shape);
  Dtype* scale_data = scale.mutable_gpu_data();
  int count = outer_num * channels * inner_num;
  // We need to subtract the max to avoid numerical issues, compute the exp,
  // and then normalize.
  // compute max
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_max<Dtype><<<CAFFE_GET_BLOCKS(outer_num * inner_num),
      CAFFE_CUDA_NUM_THREADS>>>(outer_num, channels, inner_num, data,
      scale_data);
  // subtract
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_subtract<Dtype><<<CAFFE_GET_BLOCKS(count),
      CAFFE_CUDA_NUM_THREADS>>>(count, outer_num, channels, inner_num,
      data, scale_data, prob);
  // exponentiate
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_exp<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
      count, prob, prob);
  // sum after exp
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_sum<Dtype><<<CAFFE_GET_BLOCKS(outer_num * inner_num),
      CAFFE_CUDA_NUM_THREADS>>>(outer_num, channels, inner_num, prob,
      scale_data);
  // divide
  // NOLINT_NEXT_LINE(whitespace/operators)
  kernel_channel_div<Dtype><<<CAFFE_GET_BLOCKS(count),
      CAFFE_CUDA_NUM_THREADS>>>(count, outer_num, channels, inner_num,
      scale_data, prob);
}

template void SoftMaxGPU(const float* data, const int outer_num,
    const int channels, const int inner_num, float* prob);
template void SoftMaxGPU(const double* data, const int outer_num,
    const int channels, const int inner_num, double* prob);

template <typename Dtype>
__global__ void ComputeOverlappedKernel(const int nthreads,
          const Dtype* bbox_data, const int num_bboxes, const int num_classes,
          const Dtype overlap_threshold, bool* overlapped_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    const int j = index % num_bboxes;
    const int i = (index / num_bboxes) % num_bboxes;
    if (i == j) {
      // Ignore same bbox.
      return;
    }
    const int c = (index / num_bboxes / num_bboxes) % num_classes;
    const int n = index / num_bboxes / num_bboxes / num_classes;
    // Compute overlap between i-th bbox and j-th bbox.
    const int start_loc_i = ((n * num_bboxes + i) * num_classes + c) * 4;
    const int start_loc_j = ((n * num_bboxes + j) * num_classes + c) * 4;
    const Dtype overlap = JaccardOverlapGPU<Dtype>(bbox_data + start_loc_i,
        bbox_data + start_loc_j);
    if (overlap > overlap_threshold) {
      overlapped_data[index] = true;
    }
  }
}

template <typename Dtype>
void ComputeOverlappedGPU(const int nthreads,
          const Dtype* bbox_data, const int num_bboxes, const int num_classes,
          const Dtype overlap_threshold, bool* overlapped_data) {
  // NOLINT_NEXT_LINE(whitespace/operators)
  ComputeOverlappedKernel<Dtype><<<CAFFE_GET_BLOCKS(nthreads),
      CAFFE_CUDA_NUM_THREADS>>>(nthreads, bbox_data, num_bboxes, num_classes,
      overlap_threshold, overlapped_data);
  CUDA_POST_KERNEL_CHECK;
}

template void ComputeOverlappedGPU(const int nthreads,
          const float* bbox_data, const int num_bboxes, const int num_classes,
          const float overlap_threshold, bool* overlapped_data);
template void ComputeOverlappedGPU(const int nthreads,
          const double* bbox_data, const int num_bboxes, const int num_classes,
          const double overlap_threshold, bool* overlapped_data);

template <typename Dtype>
__global__ void ComputeOverlappedByIdxKernel(const int nthreads,
          const Dtype* bbox_data, const Dtype overlap_threshold,
          const int* idx, const int num_idx, bool* overlapped_data) {
  CUDA_KERNEL_LOOP(index, nthreads) {
    const int j = index % num_idx;
    const int i = (index / num_idx);
    if (i == j) {
      // Ignore same bbox.
      return;
    }
    // Compute overlap between i-th bbox and j-th bbox.
    const int start_loc_i = idx[i] * 4;
    const int start_loc_j = idx[j] * 4;
    const Dtype overlap = JaccardOverlapGPU<Dtype>(bbox_data + start_loc_i,
        bbox_data + start_loc_j);
    if (overlap > overlap_threshold) {
      overlapped_data[index] = true;
    }
  }
}


}  // namespace caffe
