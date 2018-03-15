from .pycaffe import Net
from ._caffe import init_log, log, set_mode_cpu, set_mode_gpu, set_device, Layer, layer_type_list, set_multiprocess
from ._caffe import __version__
from .proto.caffe_pb2 import TRAIN, TEST
from .classifier import Classifier
from .detector import Detector
from . import io
from .net_spec import layers, params, NetSpec, to_proto
