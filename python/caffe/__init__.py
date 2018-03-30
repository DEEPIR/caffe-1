from .pycaffe import Net
from ._caffe import init_log, log, set_mode_cpu, set_mode_gpu, set_device, Layer, layer_type_list
from ._caffe import __version__
from .proto.caffe_pb2 import TRAIN, TEST
from . import io
from .net_spec import layers, params, NetSpec, to_proto
