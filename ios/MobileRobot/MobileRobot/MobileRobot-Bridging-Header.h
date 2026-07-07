//
//  SiriApp-Bridging-Header.h
//  SiriApp
//
//  Bridging header for C libraries: sherpa-onnx and libbz2
//

// sherpa-onnx C API
#include "sherpa-onnx/c-api/c-api.h"

// libbz2 for tar.bz2 decompression (system library)
#include <bzlib.h>
#import "Helpers/Bzip2Helper.h"
