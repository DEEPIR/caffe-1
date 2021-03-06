#include <algorithm>
#include <cfloat>
#include <map>
#include <string>
#include <utility>
#include <vector>


#include "caffe/layers/detection_output_layer.hpp"

namespace caffe {

template <typename Dtype>
void DetectionOutputLayer<Dtype>::LayerSetUp(const vector<Blob<Dtype>*>&  /*bottom*/,
      const vector<Blob<Dtype>*>&  /*top*/) {
  const DetectionOutputParameter& detection_output_param =
      this->layer_param_.detection_output_param();
  CHECK(detection_output_param.has_num_classes()) << "Must specify num_classes";
  num_classes_ = detection_output_param.num_classes();
  share_location_ = detection_output_param.share_location();
  num_loc_classes_ = share_location_ ? 1 : num_classes_;
  background_label_id_ = detection_output_param.background_label_id();
  code_type_ = detection_output_param.code_type();
  variance_encoded_in_target_ =
      detection_output_param.variance_encoded_in_target();
  keep_top_k_ = detection_output_param.keep_top_k();
  confidence_threshold_ = detection_output_param.has_confidence_threshold() ?
      detection_output_param.confidence_threshold() : -FLT_MAX;
  // Parameters used in nms.
  nms_threshold_ = detection_output_param.nms_param().nms_threshold();
  CHECK_GE(nms_threshold_, 0.) << "nms_threshold must be non negative.";
  eta_ = detection_output_param.nms_param().eta();
  CHECK_GT(eta_, 0.);
  CHECK_LE(eta_, 1.);
  top_k_ = -1;
  if (detection_output_param.nms_param().has_top_k()) {
    top_k_ = detection_output_param.nms_param().top_k();
  }

  name_count_ = 0;
}

template <typename Dtype>
void DetectionOutputLayer<Dtype>::Reshape(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {
  Reshape_const(bottom,top);
}

template <typename Dtype>
void DetectionOutputLayer<Dtype>::Reshape_const(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) const {
  CHECK_EQ(bottom[0]->num(), bottom[1]->num());
  // num() and channels() are 1.
  vector<int> top_shape(2, 1);
  // Since the number of bboxes to be kept is unknown before nms, we manually
  // set it to (fake) 1.
  top_shape.push_back(1);
  // Each row is a 7 dimension vector, which stores
  // [image_id, label, confidence, xmin, ymin, xmax, ymax]
  top_shape.push_back(7);
  top[0]->Reshape(top_shape);
}

template <typename Dtype>
void DetectionOutputLayer<Dtype>::Forward_cpu(
    const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) {
  Forward_const_cpu(bottom,top);
}

template <typename Dtype>
void DetectionOutputLayer<Dtype>::Forward_const_cpu(
    const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) const {
  const Dtype* loc_data = bottom[0]->cpu_data();
  const Dtype* conf_data = bottom[1]->cpu_data();
  const Dtype* prior_data = bottom[2]->cpu_data();
  const int num = bottom[0]->num();

  int num_priors = bottom[2]->height() / 4;
  CHECK_EQ(num_priors * num_loc_classes_ * 4, bottom[0]->channels())
      << "Number of priors must match number of location predictions.";
  CHECK_EQ(num_priors * num_classes_, bottom[1]->channels())
      << "Number of priors must match number of confidence predictions.";

  // Retrieve all location predictions.
  vector<LabelBBox> all_loc_preds;
  GetLocPredictions(loc_data, num, num_priors, num_loc_classes_,
                    share_location_, &all_loc_preds);

  // Retrieve all confidences.
  vector<map<int, vector<float> > > all_conf_scores;
  GetConfidenceScores(conf_data, num, num_priors, num_classes_,
                      &all_conf_scores);

  // Retrieve all prior bboxes. It is same within a batch since we assume all
  // images in a batch are of same dimension.
  vector<NormalizedBBox> prior_bboxes;
  vector<vector<float> > prior_variances;
  GetPriorBBoxes(prior_data, num_priors, &prior_bboxes, &prior_variances);

  // Decode all loc predictions to bboxes.
  vector<LabelBBox> all_decode_bboxes;
  const bool clip_bbox = false;
  DecodeBBoxesAll(all_loc_preds, prior_bboxes, prior_variances, num,
                  share_location_, num_loc_classes_, background_label_id_,
                  code_type_, variance_encoded_in_target_, clip_bbox,
                  &all_decode_bboxes);

  int num_kept = 0;
  vector<map<int, vector<int> > > all_indices;
  for (int i = 0; i < num; ++i) {
    const LabelBBox& decode_bboxes = all_decode_bboxes[i];
    const map<int, vector<float> >& conf_scores = all_conf_scores[i];
    map<int, vector<int> > indices;
    int num_det = 0;
    for (int c = 0; c < num_classes_; ++c) {
      if (c == background_label_id_) {
        // Ignore background class.
        continue;
      }
      if (conf_scores.find(c) == conf_scores.end()) {
        // Something bad happened if there are no predictions for current label.
        LOG(FATAL) << "Could not find confidence predictions for label " << c;
      }
      const vector<float>& scores = conf_scores.find(c)->second;
      int label = share_location_ ? -1 : c;
      if (decode_bboxes.find(label) == decode_bboxes.end()) {
        // Something bad happened if there are no predictions for current label.
        LOG(FATAL) << "Could not find location predictions for label " << label;
        continue;
      }
      const vector<NormalizedBBox>& bboxes = decode_bboxes.find(label)->second;
      ApplyNMSFast(bboxes, scores, confidence_threshold_, nms_threshold_, eta_,
          top_k_, &(indices[c]));
      num_det += indices[c].size();
    }
    if (keep_top_k_ > -1 && num_det > keep_top_k_) {
      vector<pair<float, pair<int, int> > > score_index_pairs;
      for (auto & indice : indices) {
        int label = indice.first;
        const vector<int>& label_indices = indice.second;
        if (conf_scores.find(label) == conf_scores.end()) {
          // Something bad happened for current label.
          LOG(FATAL) << "Could not find location predictions for " << label;
          continue;
        }
        const vector<float>& scores = conf_scores.find(label)->second;
        for (int idx : label_indices) {
          CHECK_LT(idx, scores.size());
          score_index_pairs.emplace_back(
                  scores[idx], std::make_pair(label, idx));
        }
      }
      // Keep top k results per image.
      std::sort(score_index_pairs.begin(), score_index_pairs.end(),
                SortScorePairDescend<pair<int, int> >);
      score_index_pairs.resize(keep_top_k_);
      // Store the new indices.
      map<int, vector<int> > new_indices;
      for (auto & score_index_pair : score_index_pairs) {
        int label = score_index_pair.second.first;
        int idx = score_index_pair.second.second;
        new_indices[label].push_back(idx);
      }
      all_indices.push_back(new_indices);
      num_kept += keep_top_k_;
    } else {
      all_indices.push_back(indices);
      num_kept += num_det;
    }
  }

  vector<int> top_shape(2, 1);
  top_shape.push_back(num_kept);
  top_shape.push_back(7);
  Dtype* top_data;
  if (num_kept == 0) {
    LOG(INFO) << "Couldn't find any detections";
    top_shape[2] = num;
    top[0]->Reshape(top_shape);
    top_data = top[0]->mutable_cpu_data();
    caffe_set<Dtype>(top[0]->count(), -1, top_data);
    // Generate fake results per image.
    for (int i = 0; i < num; ++i) {
      top_data[0] = i;
      top_data += 7;
    }
  } else {
    top[0]->Reshape(top_shape);
    top_data = top[0]->mutable_cpu_data();
  }

  int count = 0;
  for (int i = 0; i < num; ++i) {
    const map<int, vector<float> >& conf_scores = all_conf_scores[i];
    const LabelBBox& decode_bboxes = all_decode_bboxes[i];
    for (auto it = all_indices[i].begin();
         it != all_indices[i].end(); ++it) {
      int label = it->first;
      if (conf_scores.find(label) == conf_scores.end()) {
        // Something bad happened if there are no predictions for current label.
        LOG(FATAL) << "Could not find confidence predictions for " << label;
        continue;
      }
      const vector<float>& scores = conf_scores.find(label)->second;
      int loc_label = share_location_ ? -1 : label;
      if (decode_bboxes.find(loc_label) == decode_bboxes.end()) {
        // Something bad happened if there are no predictions for current label.
        LOG(FATAL) << "Could not find location predictions for " << loc_label;
        continue;
      }
      const vector<NormalizedBBox>& bboxes =
          decode_bboxes.find(loc_label)->second;
      vector<int>& indices = it->second;
      for (int idx : indices) {
        top_data[count * 7] = i;
        top_data[count * 7 + 1] = label;
        top_data[count * 7 + 2] = scores[idx];
        const NormalizedBBox& bbox = bboxes[idx];
        top_data[count * 7 + 3] = bbox.xmin();
        top_data[count * 7 + 4] = bbox.ymin();
        top_data[count * 7 + 5] = bbox.xmax();
        top_data[count * 7 + 6] = bbox.ymax();
        ++count;
      }
    }
  }
}

#ifdef CPU_ONLY
STUB_GPU_FORWARD(DetectionOutputLayer, Forward);
STUB_GPU_FORWARD_CONST(DetectionOutputLayer,Forward_const);
#endif

INSTANTIATE_CLASS(DetectionOutputLayer);
REGISTER_LAYER_CLASS(DetectionOutput);

}  // namespace caffe
