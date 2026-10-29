// Minimal C entry point around jpegli's encoder. libjpeg-style error handling
// uses longjmp, which must not cross Rust frames, so it is contained here.

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lib/jpegli/encode.h"

namespace {

struct ErrorManager {
  jpeg_error_mgr pub;
  jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
};

void OnError(j_common_ptr cinfo) {
  ErrorManager* err = reinterpret_cast<ErrorManager*>(cinfo->err);
  (*cinfo->err->format_message)(cinfo, err->message);
  longjmp(err->jump, 1);
}

void OnMessage(j_common_ptr, int) {}

}  // namespace

extern "C" int krimp_jpegli_encode(const uint8_t* rgb, uint32_t width, uint32_t height,
                                   int quality, int progressive, uint8_t** out,
                                   size_t* out_len, char* error, size_t error_len) {
  jpeg_compress_struct cinfo;
  ErrorManager err;
  memset(&cinfo, 0, sizeof(cinfo));
  memset(&err, 0, sizeof(err));
  cinfo.err = jpegli_std_error(&err.pub);
  err.pub.error_exit = OnError;
  err.pub.emit_message = OnMessage;

  // Volatile so the values survive longjmp.
  unsigned char* volatile buffer = nullptr;
  unsigned long volatile size = 0;

  if (setjmp(err.jump)) {
    snprintf(error, error_len, "jpegli: %s", err.message);
    jpegli_destroy_compress(&cinfo);
    free(buffer);
    return -1;
  }

  jpegli_create_compress(&cinfo);
  jpegli_mem_dest(&cinfo, const_cast<unsigned char**>(&buffer),
                  const_cast<unsigned long*>(&size));
  cinfo.image_width = width;
  cinfo.image_height = height;
  cinfo.input_components = 3;
  cinfo.in_color_space = JCS_RGB;
  jpegli_set_defaults(&cinfo);
  jpegli_set_quality(&cinfo, quality, TRUE);
  jpegli_set_progressive_level(&cinfo, progressive ? 2 : 0);
  jpegli_start_compress(&cinfo, TRUE);

  const size_t stride = static_cast<size_t>(width) * 3;
  while (cinfo.next_scanline < cinfo.image_height) {
    JSAMPROW row = const_cast<JSAMPROW>(rgb + cinfo.next_scanline * stride);
    jpegli_write_scanlines(&cinfo, &row, 1);
  }
  jpegli_finish_compress(&cinfo);
  jpegli_destroy_compress(&cinfo);

  *out = buffer;
  *out_len = size;
  return 0;
}

extern "C" void krimp_jpegli_free(uint8_t* buffer) { free(buffer); }
