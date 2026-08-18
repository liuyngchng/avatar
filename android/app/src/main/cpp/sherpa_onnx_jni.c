#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <android/log.h>

#include "sherpa-onnx/c-api/c-api.h"

#define TAG "SiriJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Per-recognizer state (offline SenseVoice ASR) ──────────────────────────

typedef struct {
    const SherpaOnnxOfflineRecognizer *recognizer;
    float *buffer;
    int32_t buffer_len;
    int32_t buffer_cap;
} RecognizerState;

// ── ASR: Create Recognizer ─────────────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_rd_avatar_asr_SherpaAsrEngine_nativeCreateRecognizer(
    JNIEnv *env, jclass clazz, jstring modelPath, jstring tokensPath) {

    const char *c_model = (*env)->GetStringUTFChars(env, modelPath, NULL);
    const char *c_tokens = (*env)->GetStringUTFChars(env, tokensPath, NULL);

    if (!c_model || !c_tokens) {
        LOGE("ASR: Failed to get path strings");
        if (c_model) (*env)->ReleaseStringUTFChars(env, modelPath, c_model);
        if (c_tokens) (*env)->ReleaseStringUTFChars(env, tokensPath, c_tokens);
        return 0;
    }

    LOGI("ASR: Creating recognizer: model=%s, tokens=%s", c_model, c_tokens);

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.sense_voice.model = c_model;
    config.model_config.sense_voice.language = "auto";
    config.model_config.sense_voice.use_itn = 1;

    config.model_config.tokens = c_tokens;
    config.model_config.num_threads = 2;  // adaptive: low-end devices use 2, avoid contention
    config.model_config.provider = "xnnpack";  // XNNPACK: 2-4x faster than plain CPU on ARM
    config.model_config.debug = 0;

    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *recognizer =
        SherpaOnnxCreateOfflineRecognizer(&config);

    (*env)->ReleaseStringUTFChars(env, modelPath, c_model);
    (*env)->ReleaseStringUTFChars(env, tokensPath, c_tokens);

    if (!recognizer) {
        LOGE("ASR: Failed to create recognizer");
        return 0;
    }

    RecognizerState *state = malloc(sizeof(RecognizerState));
    memset(state, 0, sizeof(RecognizerState));
    state->recognizer = recognizer;

    LOGI("ASR: Recognizer created successfully");
    return (jlong)(intptr_t)state;
}

// ── ASR: Accept Waveform (buffer samples) ──────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_asr_SherpaAsrEngine_nativeAcceptWaveform(
    JNIEnv *env, jclass clazz, jlong ptr, jfloatArray samples) {

    if (ptr == 0) return;
    RecognizerState *state = (RecognizerState *)(intptr_t)ptr;

    jsize n = (*env)->GetArrayLength(env, samples);
    if (n <= 0) return;

    // Grow buffer if needed
    int32_t needed = state->buffer_len + n;
    if (needed > state->buffer_cap) {
        int32_t new_cap = state->buffer_cap > 0 ? state->buffer_cap * 2 : 16000 * 10; // 10s default (typical utterance 2-3s)
        if (new_cap < needed) new_cap = needed;
        state->buffer = realloc(state->buffer, new_cap * sizeof(float));
        state->buffer_cap = new_cap;
    }

    jfloat *c_samples = (*env)->GetFloatArrayElements(env, samples, NULL);
    if (!c_samples) {
        LOGE("ASR: Failed to get sample array");
        return;
    }

    memcpy(state->buffer + state->buffer_len, c_samples, n * sizeof(float));
    state->buffer_len += n;

    (*env)->ReleaseFloatArrayElements(env, samples, c_samples, JNI_ABORT);
}

// ── ASR: Get Pending Text (none for offline) ───────────────────────────────

JNIEXPORT jstring JNICALL
Java_com_rd_avatar_asr_SherpaAsrEngine_nativeGetText(
    JNIEnv *env, jclass clazz, jlong ptr) {
    // Offline recognizer doesn't produce partial results
    return (*env)->NewStringUTF(env, "");
}

// ── ASR: Input Finished (decode all buffered samples) ──────────────────────

JNIEXPORT jstring JNICALL
Java_com_rd_avatar_asr_SherpaAsrEngine_nativeInputFinished(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return (*env)->NewStringUTF(env, "");

    RecognizerState *state = (RecognizerState *)(intptr_t)ptr;

    if (state->buffer_len == 0) {
        LOGI("ASR: Input finished with no samples");
        return (*env)->NewStringUTF(env, "");
    }

    LOGI("ASR: Decoding %d samples", state->buffer_len);

    const SherpaOnnxOfflineStream *stream =
        SherpaOnnxCreateOfflineStream(state->recognizer);

    if (!stream) {
        LOGE("ASR: Failed to create offline stream");
        state->buffer_len = 0;
        return (*env)->NewStringUTF(env, "");
    }

    SherpaOnnxAcceptWaveformOffline(stream, 16000, state->buffer, state->buffer_len);
    SherpaOnnxDecodeOfflineStream(state->recognizer, stream);

    const SherpaOnnxOfflineRecognizerResult *result =
        SherpaOnnxGetOfflineStreamResult(stream);

    jstring j_text = NULL;
    if (result && result->text) {
        j_text = (*env)->NewStringUTF(env, result->text);
        LOGI("ASR: Result: %s", result->text);
    } else {
        j_text = (*env)->NewStringUTF(env, "");
        LOGI("ASR: No result text");
    }

    if (result) SherpaOnnxDestroyOfflineRecognizerResult(result);
    SherpaOnnxDestroyOfflineStream(stream);

    // Clear buffer
    state->buffer_len = 0;

    return j_text;
}

// ── ASR: Destroy Recognizer ────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_asr_SherpaAsrEngine_nativeDestroyRecognizer(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return;

    RecognizerState *state = (RecognizerState *)(intptr_t)ptr;

    if (state->recognizer) {
        SherpaOnnxDestroyOfflineRecognizer(state->recognizer);
    }
    free(state->buffer);
    free(state);
    LOGI("ASR: Recognizer destroyed");
}

// ═══════════════════════════════════════════════════════════════════════════
// TTS: Matcha-TTS
// ═══════════════════════════════════════════════════════════════════════════

typedef struct {
    const SherpaOnnxOfflineTts *tts;
} TtsState;

// ── TTS: Create ────────────────────────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_rd_avatar_tts_SherpaTtsEngine_nativeCreateTts(
    JNIEnv *env, jclass clazz,
    jstring acousticModel, jstring vocoder,
    jstring tokens, jstring lexicon, jint numThreads) {

    const char *c_acoustic = (*env)->GetStringUTFChars(env, acousticModel, NULL);
    const char *c_vocoder = (*env)->GetStringUTFChars(env, vocoder, NULL);
    const char *c_tokens = (*env)->GetStringUTFChars(env, tokens, NULL);
    const char *c_lexicon = (*env)->GetStringUTFChars(env, lexicon, NULL);

    LOGI("TTS: Creating with acoustic=%s, vocoder=%s, numThreads=%d",
         c_acoustic, c_vocoder, (int)numThreads);

    SherpaOnnxOfflineTtsConfig config;
    memset(&config, 0, sizeof(config));

    config.model.matcha.acoustic_model = c_acoustic;
    config.model.matcha.vocoder = c_vocoder;
    config.model.matcha.tokens = c_tokens;
    config.model.matcha.lexicon = c_lexicon;
    config.model.matcha.noise_scale = 0.667f;
    config.model.matcha.length_scale = 1.0f;
    config.model.num_threads = (int32_t)numThreads;
    config.model.provider = "cpu";
    config.model.debug = 0;
    config.max_num_sentences = 1;
    config.silence_scale = 0.2f;

    const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);

    (*env)->ReleaseStringUTFChars(env, acousticModel, c_acoustic);
    (*env)->ReleaseStringUTFChars(env, vocoder, c_vocoder);
    (*env)->ReleaseStringUTFChars(env, tokens, c_tokens);
    (*env)->ReleaseStringUTFChars(env, lexicon, c_lexicon);

    if (!tts) {
        LOGE("TTS: Failed to create");
        return 0;
    }

    TtsState *state = malloc(sizeof(TtsState));
    state->tts = tts;

    int32_t sr = SherpaOnnxOfflineTtsSampleRate(tts);
    LOGI("TTS: Created successfully, sample_rate=%d", sr);
    return (jlong)(intptr_t)state;
}

// ── TTS: Synthesize ────────────────────────────────────────────────────────

JNIEXPORT jfloatArray JNICALL
Java_com_rd_avatar_tts_SherpaTtsEngine_nativeSynthesize(
    JNIEnv *env, jclass clazz, jlong ptr, jstring text, jfloat speed, jint sid) {

    if (ptr == 0) return NULL;

    TtsState *state = (TtsState *)(intptr_t)ptr;
    const char *c_text = (*env)->GetStringUTFChars(env, text, NULL);

    if (!c_text) {
        LOGE("TTS: Failed to get text string");
        return NULL;
    }

    LOGI("TTS: Synthesizing %d chars, speed=%.2f, sid=%d", (int)strlen(c_text), (double)speed, (int)sid);

    SherpaOnnxGenerationConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.sid = (int32_t)sid;
    cfg.speed = speed;

    const SherpaOnnxGeneratedAudio *audio =
        SherpaOnnxOfflineTtsGenerateWithConfig(state->tts, c_text, &cfg, NULL, NULL);

    (*env)->ReleaseStringUTFChars(env, text, c_text);

    if (!audio || !audio->samples || audio->n <= 0) {
        LOGE("TTS: Synthesis produced no audio");
        if (audio) SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        return NULL;
    }

    jfloatArray result = (*env)->NewFloatArray(env, audio->n);
    (*env)->SetFloatArrayRegion(env, result, 0, audio->n, audio->samples);

    LOGI("TTS: Synthesized %d samples at %d Hz", audio->n, audio->sample_rate);

    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    return result;
}

// ── TTS: Get Sample Rate ───────────────────────────────────────────────────

JNIEXPORT jint JNICALL
Java_com_rd_avatar_tts_SherpaTtsEngine_nativeGetSampleRate(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return 22050;
    TtsState *state = (TtsState *)(intptr_t)ptr;
    return SherpaOnnxOfflineTtsSampleRate(state->tts);
}

// ── TTS: Destroy ───────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_tts_SherpaTtsEngine_nativeDestroyTts(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return;
    TtsState *state = (TtsState *)(intptr_t)ptr;
    if (state->tts) {
        SherpaOnnxDestroyOfflineTts(state->tts);
    }
    free(state);
    LOGI("TTS: Destroyed");
}

// ═══════════════════════════════════════════════════════════════════════════
// KWS: Keyword Spotting (wake word detection)
// ═══════════════════════════════════════════════════════════════════════════

#include <dirent.h>

typedef struct {
    const SherpaOnnxKeywordSpotter *spotter;
} KwsState;

// Try standard short name first, then fall back to scanning the directory
// for a file whose name contains `keyword` and ends with `suffix`.
static void find_model_file(const char *dir, const char *keyword,
                            const char *suffix, char *out, size_t out_size) {
    out[0] = '\0';

    // First try the standard short name
    char std_name[256];
    snprintf(std_name, sizeof(std_name), "%s/%s%s", dir, keyword, suffix);
    FILE *f = fopen(std_name, "rb");
    if (f) {
        fclose(f);
        snprintf(out, out_size, "%s", std_name);
        return;
    }

    // Fallback: scan directory for a file containing the keyword
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *entry;
    while ((entry = readdir(d)) != NULL) {
        const char *name = entry->d_name;
        if (strstr(name, keyword) == NULL) continue;
        size_t name_len = strlen(name);
        size_t suf_len = strlen(suffix);
        if (name_len >= suf_len
            && strcmp(name + name_len - suf_len, suffix) == 0) {
            snprintf(out, out_size, "%s/%s", dir, name);
            break;
        }
    }
    closedir(d);
}

// ── KWS: Create Spotter ────────────────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeCreateSpotter(
    JNIEnv *env, jclass clazz, jstring modelDir, jstring keywords, jint numThreads) {

    const char *c_dir = (*env)->GetStringUTFChars(env, modelDir, NULL);
    const char *c_kw = (*env)->GetStringUTFChars(env, keywords, NULL);
    if (!c_dir || !c_kw) {
        LOGE("KWS: Failed to get path string");
        if (c_dir) (*env)->ReleaseStringUTFChars(env, modelDir, c_dir);
        if (c_kw) (*env)->ReleaseStringUTFChars(env, keywords, c_kw);
        return 0;
    }

    char encoder_path[1024];
    char decoder_path[1024];
    char joiner_path[1024];
    char tokens_path[1024];

    find_model_file(c_dir, "encoder", ".onnx", encoder_path, sizeof(encoder_path));
    find_model_file(c_dir, "decoder", ".onnx", decoder_path, sizeof(decoder_path));
    find_model_file(c_dir, "joiner", ".onnx", joiner_path, sizeof(joiner_path));
    find_model_file(c_dir, "tokens", ".txt", tokens_path, sizeof(tokens_path));

    LOGI("KWS: encoder=%s, decoder=%s, joiner=%s, tokens=%s",
         encoder_path, decoder_path, joiner_path, tokens_path);

    if (!encoder_path[0] || !decoder_path[0] || !joiner_path[0] || !tokens_path[0]) {
        LOGE("KWS: Missing model files in %s", c_dir);
        (*env)->ReleaseStringUTFChars(env, modelDir, c_dir);
        (*env)->ReleaseStringUTFChars(env, keywords, c_kw);
        return 0;
    }

    SherpaOnnxKeywordSpotterConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.transducer.encoder = encoder_path;
    config.model_config.transducer.decoder = decoder_path;
    config.model_config.transducer.joiner = joiner_path;
    config.model_config.tokens = tokens_path;
    config.model_config.num_threads = (int32_t)numThreads;
    config.model_config.provider = "xnnpack";  // XNNPACK: faster KWS inference
    config.model_config.debug = 0;

    config.max_active_paths = 2;  // reduced from 4: wake word detection needs fewer paths
    config.keywords_score = 3.0f;
    config.keywords_threshold = 0.05f;
    config.keywords_buf = c_kw;
    config.keywords_buf_size = (int32_t)strlen(c_kw);

    const SherpaOnnxKeywordSpotter *spotter = SherpaOnnxCreateKeywordSpotter(&config);

    (*env)->ReleaseStringUTFChars(env, modelDir, c_dir);
    (*env)->ReleaseStringUTFChars(env, keywords, c_kw);

    if (!spotter) {
        LOGE("KWS: Failed to create spotter");
        return 0;
    }

    KwsState *state = malloc(sizeof(KwsState));
    memset(state, 0, sizeof(KwsState));
    state->spotter = spotter;

    LOGI("KWS: Spotter created successfully");
    return (jlong)(intptr_t)state;
}

// ── KWS: Destroy Spotter ───────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeDestroySpotter(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return;
    KwsState *state = (KwsState *)(intptr_t)ptr;
    if (state->spotter) {
        SherpaOnnxDestroyKeywordSpotter(state->spotter);
    }
    free(state);
    LOGI("KWS: Spotter destroyed");
}

// ── KWS: Create Stream ──────────────────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeCreateStream(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return 0;
    KwsState *state = (KwsState *)(intptr_t)ptr;

    const SherpaOnnxOnlineStream *stream =
        SherpaOnnxCreateKeywordStream(state->spotter);

    if (!stream) {
        LOGE("KWS: Failed to create keyword stream");
        return 0;
    }
    LOGI("KWS: Stream created");
    return (jlong)(intptr_t)stream;
}

// ── KWS: Destroy Stream ────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeDestroyStream(
    JNIEnv *env, jclass clazz, jlong streamPtr) {

    if (streamPtr == 0) return;
    SherpaOnnxDestroyOnlineStream((const SherpaOnnxOnlineStream *)(intptr_t)streamPtr);
}

// ── KWS: Accept Waveform ───────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeAcceptWaveform(
    JNIEnv *env, jclass clazz, jlong streamPtr, jfloatArray samples, jint sampleRate) {

    if (streamPtr == 0) return;
    const SherpaOnnxOnlineStream *stream = (const SherpaOnnxOnlineStream *)(intptr_t)streamPtr;

    jsize n = (*env)->GetArrayLength(env, samples);
    if (n <= 0) return;

    jfloat *c_samples = (*env)->GetFloatArrayElements(env, samples, NULL);
    if (!c_samples) return;

    SherpaOnnxOnlineStreamAcceptWaveform(stream, (int32_t)sampleRate, c_samples, (int32_t)n);

    (*env)->ReleaseFloatArrayElements(env, samples, c_samples, JNI_ABORT);
}

// ── KWS: Is Stream Ready ───────────────────────────────────────────────────

JNIEXPORT jboolean JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeIsStreamReady(
    JNIEnv *env, jclass clazz, jlong ptr, jlong streamPtr) {

    if (ptr == 0 || streamPtr == 0) return JNI_FALSE;
    KwsState *state = (KwsState *)(intptr_t)ptr;
    const SherpaOnnxOnlineStream *stream = (const SherpaOnnxOnlineStream *)(intptr_t)streamPtr;
    return SherpaOnnxIsKeywordStreamReady(state->spotter, stream) ? JNI_TRUE : JNI_FALSE;
}

// ── KWS: Decode Stream ─────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeDecodeStream(
    JNIEnv *env, jclass clazz, jlong ptr, jlong streamPtr) {

    if (ptr == 0 || streamPtr == 0) return;
    KwsState *state = (KwsState *)(intptr_t)ptr;
    const SherpaOnnxOnlineStream *stream = (const SherpaOnnxOnlineStream *)(intptr_t)streamPtr;
    SherpaOnnxDecodeKeywordStream(state->spotter, stream);
}

// ── KWS: Get Result ────────────────────────────────────────────────────────

JNIEXPORT jstring JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeGetResult(
    JNIEnv *env, jclass clazz, jlong ptr, jlong streamPtr) {

    if (ptr == 0 || streamPtr == 0) return (*env)->NewStringUTF(env, "");
    KwsState *state = (KwsState *)(intptr_t)ptr;
    const SherpaOnnxOnlineStream *stream = (const SherpaOnnxOnlineStream *)(intptr_t)streamPtr;

    const SherpaOnnxKeywordResult *result = SherpaOnnxGetKeywordResult(state->spotter, stream);
    if (!result) return (*env)->NewStringUTF(env, "");

    jstring j_keyword = (*env)->NewStringUTF(env,
        (result->keyword && result->keyword[0]) ? result->keyword : "");
    SherpaOnnxDestroyKeywordResult(result);
    return j_keyword;
}

// ── KWS: Reset Stream ──────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_avatar_audio_WakeWordEngine_nativeResetStream(
    JNIEnv *env, jclass clazz, jlong ptr, jlong streamPtr) {

    if (ptr == 0 || streamPtr == 0) return;
    KwsState *state = (KwsState *)(intptr_t)ptr;
    const SherpaOnnxOnlineStream *stream = (const SherpaOnnxOnlineStream *)(intptr_t)streamPtr;
    SherpaOnnxResetKeywordStream(state->spotter, stream);
}
