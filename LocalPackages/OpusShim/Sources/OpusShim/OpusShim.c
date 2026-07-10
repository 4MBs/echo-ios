#include "include/OpusShim.h"
#include <opus.h>

void *moss_opus_encoder_create(int sample_rate_hz, int channels, int *error_out) {
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(sample_rate_hz, channels,
                                           OPUS_APPLICATION_VOIP, &err);
    if (error_out) {
        *error_out = err;
    }
    return (err == OPUS_OK) ? (void *)enc : NULL;
}

int moss_opus_encoder_configure(void *encoder,
                                int bitrate_bps,
                                int complexity,
                                int enable_fec,
                                int expected_loss_pct) {
    OpusEncoder *enc = (OpusEncoder *)encoder;
    int err;
    err = opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate_bps));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(enable_fec ? 1 : 0));
    if (err != OPUS_OK) return err;
    err = opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(expected_loss_pct));
    return err;
}

int moss_opus_encode(void *encoder,
                     const short *pcm,
                     int frame_size,
                     unsigned char *out,
                     int out_capacity) {
    return opus_encode((OpusEncoder *)encoder, pcm, frame_size, out, out_capacity);
}

void moss_opus_encoder_destroy(void *encoder) {
    if (encoder) {
        opus_encoder_destroy((OpusEncoder *)encoder);
    }
}

const char *moss_opus_strerror(int error) {
    return opus_strerror(error);
}
