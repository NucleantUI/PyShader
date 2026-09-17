// Foundation on wasm links ICU with its ~35 MB data blob (`icudt76_dat`, its own
// archive member). Defining the symbol here keeps that member out of the link;
// nothing PyShader does needs ICU tables, and lookups fail cleanly without them.
// The header is a valid, empty ICU common-data header so udata_setCommonData
// accepts it instead of treating memory past the array as data.
#include <stdint.h>

__attribute__((used, visibility("default")))
const uint8_t icudt76_dat[] __attribute__((aligned(16))) = {
    // DataHeader: MappedData { headerSize=0x20, magic1=0xda, magic2=0x27 }
    0x20, 0x00, 0xda, 0x27,
    // UDataInfo: size=0x14, reserved, isBigEndian=0, charsetFamily=0, sizeofUChar=2, reserved
    0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00,
    // dataFormat "CmnD", formatVersion 1.0.0.0, dataVersion 0.0.0.0
    0x43, 0x6d, 0x6e, 0x44, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // padding to headerSize
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // UDataOffsetTOC: count = 0
    0x00, 0x00, 0x00, 0x00,
};
