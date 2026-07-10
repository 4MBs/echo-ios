#ifndef OPUS_SHIM_H
#define OPUS_SHIM_H

// Plain-C, non-variadic wrappers over libopus for Swift.
// Handles are opaque; Swift never needs opus.h types.

#ifdef __cplusplus
extern "C" {
#endif

/// Create a VOIP-application Opus encoder. Returns NULL on failure.
void *moss_opus_encoder_create(int sample_rate_hz, int channels, int *error_out);

/// Apply speech-streaming settings (bitrate b/s, complexity 0-10, in-band FEC
/// on/off, expected packet loss percent). Returns 0 on success.
int moss_opus_encoder_configure(void *encoder,
                                int bitrate_bps,
                                int complexity,
                                int enable_fec,
                                int expected_loss_pct);

/// Encode one frame of interleaved int16 PCM (frame_size samples per channel).
/// Returns encoded byte count, or a negative opus error code.
int moss_opus_encode(void *encoder,
                     const short *pcm,
                     int frame_size,
                     unsigned char *out,
                     int out_capacity);

void moss_opus_encoder_destroy(void *encoder);

/// Human-readable message for a negative opus error code.
const char *moss_opus_strerror(int error);

#ifdef __cplusplus
}
#endif

#endif /* OPUS_SHIM_H */
