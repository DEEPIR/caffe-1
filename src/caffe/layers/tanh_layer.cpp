// TanH neuron activation function layer.
// Adapted from ReLU layer code written by Yangqing Jia

#include <vector>

#include "caffe/layers/tanh_layer.hpp"

namespace caffe {


template <typename Dtype>
void TanHLayer<Dtype>::Forward_cpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  Forward_const_cpu(bottom,top);
}

template <typename Dtype>
void TanHLayer<Dtype>::Forward_const_cpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) const {
  const Dtype* bottom_data = bottom[0]->cpu_data();
  Dtype* top_data = top[0]->mutable_cpu_data();
  const int count = bottom[0]->count();
  for (int i = 0; i < count; ++i) {
    top_data[i] = tanh(bottom_data[i]);
  }
}


#ifdef CPU_ONLY
STUB_GPU(TanHLayer);
STUB_GPU_FORWARD_CONST(TanHLayer,Forward_const);
#endif

INSTANTIATE_CLASS(TanHLayer);

}  // namespace caffe
