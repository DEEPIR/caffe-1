#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layers/normalize2_layer.hpp"

namespace caffe {

template <typename Dtype>
void Normalize2Layer<Dtype>::LayerSetUp(const vector<Blob<Dtype> *> &bottom,
                                        const vector<Blob<Dtype> *> & /*top*/) {
  CHECK_GE(bottom[0]->num_axes(), 2)
      << "Number of axes of bottom blob must be >=2.";
  NormalizeParameter2 norm_param = this->layer_param().norm_param();
  across_spatial_ = norm_param.across_spatial();
  eps_ = norm_param.eps();
  int channels = bottom[0]->channels();
  channel_shared_ = norm_param.channel_shared();
  if (!this->blobs_.empty()) {
    LOG(INFO) << "Skipping parameter initialization";
  } else {
    this->blobs_.resize(1);
    if (channel_shared_) {
      this->blobs_[0].reset(new Blob<Dtype>(vector<int>(0)));
    } else {
      this->blobs_[0].reset(new Blob<Dtype>(vector<int>(1, channels)));
    }
    shared_ptr<Filler<Dtype>> scale_filler;
    if (norm_param.has_scale_filler()) {
      scale_filler.reset(GetFiller<Dtype>(norm_param.scale_filler()));
    } else {
      FillerParameter filler_param;
      filler_param.set_type("constant");
      filler_param.set_value(1.0);
      scale_filler.reset(GetFiller<Dtype>(filler_param));
    }
    scale_filler->Fill(this->blobs_[0].get());
  }
  if (channel_shared_) {
    CHECK_EQ(this->blobs_[0]->count(), 1)
        << "Scale size is inconsistent with prototxt config";
  } else {
    CHECK_EQ(this->blobs_[0]->count(), channels)
        << "Scale size is inconsistent with prototxt config";
  }
}

template <typename Dtype>
void Normalize2Layer<Dtype>::Reshape(const vector<Blob<Dtype> *> &bottom,
                                     const vector<Blob<Dtype> *> &top) {
  Reshape_const(bottom, top);
}

template <typename Dtype>
void Normalize2Layer<Dtype>::Reshape_const(
    const vector<Blob<Dtype> *> &bottom,
    const vector<Blob<Dtype> *> &top) const {
  CHECK_GE(bottom[0]->num_axes(), 2)
      << "Number of axes of bottom blob must be >=2.";
  top[0]->ReshapeLike(*bottom[0]);
}

template <typename Dtype>
void Normalize2Layer<Dtype>::Forward_cpu(const vector<Blob<Dtype> *> &bottom,
                                         const vector<Blob<Dtype> *> &top) {
  Forward_const_cpu(bottom, top);
}

template <typename Dtype>
void Normalize2Layer<Dtype>::Forward_const_cpu(
    const vector<Blob<Dtype> *> &bottom,
    const vector<Blob<Dtype> *> &top) const {
  const Dtype *bottom_data = bottom[0]->cpu_data();
  int channels = bottom[0]->channels();
  Dtype *top_data = top[0]->mutable_cpu_data();
  Blob<Dtype> norm;
  Dtype *norm_data{nullptr};
  if (across_spatial_) {
    norm.Reshape(bottom[0]->num(), 1, 1, 1);
    norm_data = norm.mutable_cpu_data();
  } else {
    norm.Reshape(bottom[0]->num(), 1, bottom[0]->height(), bottom[0]->width());
    norm_data = norm.mutable_cpu_data();
    // add eps to avoid overflow
    caffe_set<Dtype>(norm.count(), Dtype(eps_), norm_data);
  }
  Blob<Dtype> sum_channel_multiplier;
  sum_channel_multiplier.Reshape(1, channels, 1, 1);
  caffe_set(channels, Dtype(1), sum_channel_multiplier.mutable_cpu_data());
  int num = bottom[0]->num();
  int dim = bottom[0]->count() / num;
  int spatial_dim = bottom[0]->height() * bottom[0]->width();
  Blob<Dtype> buffer;
  buffer.Reshape(1, 1, 1, dim);
  Dtype *buffer_data = buffer.mutable_cpu_data();
  for (int n = 0; n < num; ++n) {
    caffe_powx<Dtype>(dim, bottom_data, Dtype(2), buffer_data);
    if (across_spatial_) {
      // add eps to avoid overflow
      norm_data[n] =
          pow(caffe_cpu_asum<Dtype>(dim, buffer_data) + eps_, Dtype(0.5));
      caffe_cpu_scale<Dtype>(dim, Dtype(1.0 / norm_data[n]), bottom_data,
                             top_data);
    } else {
      caffe_cpu_gemv<Dtype>(CblasTrans, channels, spatial_dim, Dtype(1),
                            buffer_data, sum_channel_multiplier.cpu_data(),
                            Dtype(1), norm_data);
      // compute norm
      caffe_powx<Dtype>(spatial_dim, norm_data, Dtype(0.5), norm_data);
      for (int i = 0; i < dim; i++) {
        top_data[i] = bottom_data[i] / norm_data[i % spatial_dim];
      }
      norm_data += spatial_dim;
    }
    // scale the output
    const Dtype *scale = this->blobs_[0]->cpu_data();
    if (channel_shared_) {
      caffe_scal<Dtype>(dim, scale[0], top_data);
    } else {
      for (int i = 0; i < dim; i++) {
        int r = (i / spatial_dim) % channels;
        top_data[i] *= scale[r];
      }
    }
    bottom_data += dim;
    top_data += dim;
  }
}

#ifdef CPU_ONLY
STUB_GPU(Normalize2Layer);
STUB_GPU_FORWARD_CONST(Normalize2Layer, Forward_const);
#endif

INSTANTIATE_CLASS(Normalize2Layer);
REGISTER_LAYER_CLASS(Normalize2);

} // namespace caffe
