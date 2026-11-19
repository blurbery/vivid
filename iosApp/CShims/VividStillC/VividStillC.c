#include "VividStillC.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>

unsigned vivid_still_avformat_version(void) {
    return avformat_version();
}
