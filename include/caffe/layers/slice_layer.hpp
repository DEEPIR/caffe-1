#ifndef CAFFE_SLICE_LAYER_HPP_
#define CAFFE_SLICE_LAYER_HPP_

#include <vector>

#include "caffe/blob.hpp"
#include "caffe/layer.hpp"
#include "caffe/proto/caffe.pb.h"

namespace caffe {

/**
 * @brief Takes a Blob and slices it along either the num or channel dimension,
 *        outputting multiple sliced Blob results.
 *
 * TODO(dox): thorough documentation for Forward, Backward, and proto params.
 */
template <typename Dtype>
class SliceLayer : public Layer<Dtype> {
 public:
  explicit SliceLayer(const LayerParameter& param)
      : Layer<Dtype>(param) {}
  virtual void LayerSetUp(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  virtual void Reshape(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  void Reshape_const(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) const override;

  virtual inline const char* type() const { return "Slice"; }
  virtual inline int ExactNumBottomBlobs() const { return 1; }
  virtual inline int MinTopBlobs() const { return 1; }

 protected:
  virtual void Forward_cpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  void Forward_const_cpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) const override;
  virtual void Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  void Forward_const_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) const override;

  int get_slice_axis(const vector<Blob<Dtype>*>& bottom) const;
  int count_;
  int num_slices_;
  int slice_size_;
  vector<int> slice_point_;
};

}  // namespace caffe

#endif  // CAFFE_SLICE_LAYER_HPP_
