#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include "lzfse.h"

JNIEXPORT jbyteArray JNICALL
Java_com_seraphi_sito_LzfseCodec_nativeDecode(JNIEnv *env, jobject self,
                                              jbyteArray input, jint expected) {
  (void)self;
  if (expected <= 0 || expected > 20000000 || !input) return NULL;
  jsize size = (*env)->GetArrayLength(env, input);
  if (size <= 0 || size > 20000000) return NULL;
  jbyte *src = (*env)->GetByteArrayElements(env, input, NULL);
  if (!src) return NULL;
  uint8_t *dst = (uint8_t *)malloc((size_t)expected);
  if (!dst) { (*env)->ReleaseByteArrayElements(env, input, src, JNI_ABORT); return NULL; }
  size_t result = lzfse_decode_buffer(dst, (size_t)expected, (const uint8_t *)src,
                                      (size_t)size, NULL);
  (*env)->ReleaseByteArrayElements(env, input, src, JNI_ABORT);
  jbyteArray output = NULL;
  if (result == (size_t)expected) {
    output = (*env)->NewByteArray(env, expected);
    if (output) (*env)->SetByteArrayRegion(env, output, 0, expected, (const jbyte *)dst);
  }
  free(dst);
  return output;
}

JNIEXPORT jbyteArray JNICALL
Java_com_seraphi_sito_LzfseCodec_nativeEncode(JNIEnv *env, jobject self, jbyteArray input) {
  (void)self;
  if (!input) return NULL;
  jsize size = (*env)->GetArrayLength(env, input);
  if (size <= 0 || size > 20000000) return NULL;
  jbyte *src = (*env)->GetByteArrayElements(env, input, NULL);
  if (!src) return NULL;
  size_t capacity = (size_t)size + (size_t)size / 2 + 64;
  uint8_t *dst = (uint8_t *)malloc(capacity);
  if (!dst) { (*env)->ReleaseByteArrayElements(env, input, src, JNI_ABORT); return NULL; }
  size_t result = lzfse_encode_buffer(dst, capacity, (const uint8_t *)src, (size_t)size, NULL);
  (*env)->ReleaseByteArrayElements(env, input, src, JNI_ABORT);
  jbyteArray output = NULL;
  if (result > 0 && result + 5 < (size_t)size) {
    output = (*env)->NewByteArray(env, (jsize)result);
    if (output) (*env)->SetByteArrayRegion(env, output, 0, (jsize)result, (const jbyte *)dst);
  }
  free(dst);
  return output;
}
