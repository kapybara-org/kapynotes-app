# Writes test/identity.onnx: DPDFNet-2's inputs, outputs and metadata around
# a graph that hands both straight back, so the signal path can be tested
# without the 10 MB model.
import sys
import onnx
from onnx import TensorProto, helper

src = onnx.load(sys.argv[1], load_external_data=False)
meta = {p.key: p.value for p in src.metadata_props}
state = int(meta['erb_norm_state_size']) + int(meta['spec_norm_state_size'])
meta['state_size'] = str(state)
graph = helper.make_graph(
    [helper.make_node('Identity', ['spec'], ['spec_e']),
     helper.make_node('Identity', ['state_in'], ['state_out'])],
    'identity',
    [helper.make_tensor_value_info('spec', TensorProto.FLOAT, [1, 1, 161, 2]),
     helper.make_tensor_value_info('state_in', TensorProto.FLOAT, [state])],
    [helper.make_tensor_value_info('spec_e', TensorProto.FLOAT, [1, 1, 161, 2]),
     helper.make_tensor_value_info('state_out', TensorProto.FLOAT, [state])])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)], producer_name='kapy_denoise test')
model.ir_version = 8
helper.set_model_props(model, meta)
onnx.checker.check_model(model)
onnx.save(model, sys.argv[2])
