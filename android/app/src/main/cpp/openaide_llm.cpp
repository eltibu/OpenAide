// Runs a GGUF model on the phone with llama.cpp, for LocalLlm.kt.
//
// One model is loaded at a time. Each reply re-reads only what changed since
// the last one: the tokens both prompts share stay in the model's memory, so
// a long chat doesn't re-read the whole conversation on every turn.

#include <android/log.h>
#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

#include "chat.h"
#include "ggml-backend.h"
#include "llama.h"

#define TAG "OpenAideLlm"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

llama_model * g_model = nullptr;
llama_context * g_ctx = nullptr;
common_chat_templates_ptr g_tmpls;
std::vector<llama_token> g_cached;  // what the model's memory holds now
std::atomic<bool> g_stop{false};

void log_to_android(ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_WARN) {
        __android_log_print(level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN,
                            TAG, "%s", text);
    }
}

void free_all() {
    g_tmpls.reset();
    if (g_ctx) llama_free(g_ctx);
    if (g_model) llama_model_free(g_model);
    g_ctx = nullptr;
    g_model = nullptr;
    g_cached.clear();
}

std::string to_string(JNIEnv * env, jstring s) {
    if (!s) return "";
    const char * chars = env->GetStringUTFChars(s, nullptr);
    std::string out(chars);
    env->ReleaseStringUTFChars(s, chars);
    return out;
}

// Strings from Kotlin arrive as UTF-8 bytes: JNI's own string conversion
// mangles emoji.
std::string to_string(JNIEnv * env, jbyteArray bytes) {
    if (!bytes) return "";
    const jsize n = env->GetArrayLength(bytes);
    std::string out(n, '\0');
    env->GetByteArrayRegion(bytes, 0, n, reinterpret_cast<jbyte *>(out.data()));
    return out;
}

jstring json_result(JNIEnv * env, const std::string & json) {
    return env->NewStringUTF(json.c_str());
}

std::string json_escape(const std::string & s) {
    std::string out;
    for (const char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

jstring error(JNIEnv * env, const std::string & message) {
    return json_result(env, "{\"error\":\"" + json_escape(message) + "\"}");
}

// How many leading bytes of [s] are whole UTF-8 characters; a token can end
// in the middle of one, and the rest comes with the next token.
size_t complete_utf8(const std::string & s) {
    const size_t n = s.size();
    for (size_t back = 1; back <= std::min<size_t>(4, n); back++) {
        const auto c = static_cast<unsigned char>(s[n - back]);
        if ((c & 0xC0) == 0x80) continue;  // continuation byte
        size_t len = 1;
        if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        return len > back ? n - back : n;
    }
    return n;
}

bool tokenize(const std::string & text, bool add_special, bool parse_special,
              std::vector<llama_token> & out) {
    const llama_vocab * vocab = llama_model_get_vocab(g_model);
    int n = -llama_tokenize(vocab, text.data(), (int32_t) text.size(), nullptr, 0,
                            add_special, parse_special);
    if (n <= 0) return n == 0;
    const size_t at = out.size();
    out.resize(at + n);
    return llama_tokenize(vocab, text.data(), (int32_t) text.size(), out.data() + at, n,
                          add_special, parse_special) >= 0;
}

// The chat as the model expects it, in tokens. The model's own chat template
// (Jinja) is used; text people typed is never read as control tokens.
bool chat_tokens(const std::vector<common_chat_msg> & messages, bool think,
                 std::vector<llama_token> & out, std::string & err) {
    try {
        common_chat_templates_inputs inputs;
        inputs.messages = messages;
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = think;
        const auto params = common_chat_templates_apply(g_tmpls.get(), inputs);
        bool first = true;
        for (const auto & part : params.prompt.parts) {
            if (!tokenize(part.text, first, !part.is_input, out)) {
                err = "Couldn't read the conversation.";
                return false;
            }
            first = false;
        }
        return true;
    } catch (const std::exception & e) {
        LOGE("chat template: %s", e.what());
    }
    // A template the Jinja reader can't handle: llama.cpp's built-in ones.
    std::vector<llama_chat_message> chat;
    for (const auto & m : messages) chat.push_back({m.role.c_str(), m.content.c_str()});
    size_t total = 0;
    for (const auto & m : messages) total += m.content.size();
    std::vector<char> buf(total * 2 + 1024);
    const char * tmpl = llama_model_chat_template(g_model, nullptr);
    int n = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true, buf.data(),
                                      (int32_t) buf.size());
    if (n > (int) buf.size()) {
        buf.resize(n);
        n = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true, buf.data(), n);
    }
    if (n < 0) {
        err = "This model's chat format isn't supported.";
        return false;
    }
    if (!tokenize(std::string(buf.data(), n), true, true, out)) {
        err = "Couldn't read the conversation.";
        return false;
    }
    return true;
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_com_nexus_nexus_1assistant_LocalLlm_nativeInit(JNIEnv * env, jobject, jstring lib_dir) {
    llama_log_set(log_to_android, nullptr);
    // Loads the CPU code variant that fits this phone's chip.
    ggml_backend_load_all_from_path(to_string(env, lib_dir).c_str());
    llama_backend_init();
}

// Loads the model at [path]; JSON with "error", or with what was loaded.
extern "C" JNIEXPORT jstring JNICALL
Java_com_nexus_nexus_1assistant_LocalLlm_nativeLoad(JNIEnv * env, jobject, jstring jpath,
                                                    jint n_ctx, jint n_threads) {
    free_all();
    const std::string path = to_string(env, jpath);
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;
    g_model = llama_model_load_from_file(path.c_str(), mparams);
    if (!g_model) return error(env, "Couldn't open the model. The file may be damaged or not a GGUF model.");

    llama_context_params cparams = llama_context_default_params();
    const int trained = llama_model_n_ctx_train(g_model);
    cparams.n_ctx = (uint32_t) (trained > 0 ? std::min<int>(n_ctx, trained) : n_ctx);
    cparams.n_batch = 512;
    cparams.n_ubatch = 512;
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        free_all();
        return error(env, "Not enough memory for this model. Try a smaller one.");
    }
    try {
        g_tmpls = common_chat_templates_init(g_model, "");
    } catch (const std::exception & e) {
        LOGE("templates: %s", e.what());
        g_tmpls = common_chat_templates_init(g_model, "chatml");
    }
    char desc[256];
    llama_model_desc(g_model, desc, sizeof desc);
    LOGI("loaded %s, context %u, %d threads", desc, llama_n_ctx(g_ctx), n_threads);
    return json_result(env, "{\"context\":" + std::to_string(llama_n_ctx(g_ctx)) +
                                ",\"description\":\"" + json_escape(desc) + "\"}");
}

extern "C" JNIEXPORT void JNICALL
Java_com_nexus_nexus_1assistant_LocalLlm_nativeUnload(JNIEnv *, jobject) {
    free_all();
}

extern "C" JNIEXPORT void JNICALL
Java_com_nexus_nexus_1assistant_LocalLlm_nativeStop(JNIEnv *, jobject) {
    g_stop = true;
}

// Writes the reply to [roles]/[contents] piece by piece to sink.onBytes(byte[]);
// JSON with "error", or with counts and speed.
extern "C" JNIEXPORT jstring JNICALL
Java_com_nexus_nexus_1assistant_LocalLlm_nativeGenerate(
        JNIEnv * env, jobject, jobjectArray roles, jobjectArray contents, jfloat temp,
        jfloat top_p, jint max_tokens, jboolean think, jobject sink) {
    if (!g_model || !g_ctx) return error(env, "No model is loaded.");
    g_stop = false;

    std::vector<common_chat_msg> messages;
    const jsize count = env->GetArrayLength(roles);
    for (jsize i = 0; i < count; i++) {
        common_chat_msg m;
        m.role = to_string(env, (jstring) env->GetObjectArrayElement(roles, i));
        m.content = to_string(env, (jbyteArray) env->GetObjectArrayElement(contents, i));
        messages.push_back(std::move(m));
    }

    std::vector<llama_token> tokens;
    std::string err;
    if (!chat_tokens(messages, think, tokens, err)) return error(env, err);
    const int n_ctx = (int) llama_n_ctx(g_ctx);
    if ((int) tokens.size() + 8 >= n_ctx) {
        return error(env, "This conversation is too long for the model's memory. Start a new chat.");
    }

    // Keep what the model already read; read only the rest.
    size_t keep = 0;
    while (keep < g_cached.size() && keep < tokens.size() && g_cached[keep] == tokens[keep]) keep++;
    if (keep == tokens.size()) keep--;  // the last token must be read again for a reply
    llama_memory_t mem = llama_get_memory(g_ctx);
    if (!llama_memory_seq_rm(mem, 0, (llama_pos) keep, -1)) {
        llama_memory_clear(mem, true);
        keep = 0;
    }
    g_cached.assign(tokens.begin(), tokens.begin() + keep);

    const auto start = std::chrono::steady_clock::now();
    const int n_batch = (int) llama_n_batch(g_ctx);
    for (size_t i = keep; i < tokens.size(); i += n_batch) {
        if (g_stop) {
            return json_result(env, "{\"stopped\":true,\"tokens\":0}");
        }
        const int n = (int) std::min<size_t>(n_batch, tokens.size() - i);
        if (llama_decode(g_ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
            llama_memory_clear(mem, true);
            g_cached.clear();
            return error(env, "The model couldn't read the conversation.");
        }
        g_cached.insert(g_cached.end(), tokens.begin() + i, tokens.begin() + i + n);
    }
    const auto read = std::chrono::steady_clock::now();

    const llama_vocab * vocab = llama_model_get_vocab(g_model);
    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.05f, 0.0f, 0.0f));
    if (temp <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_min_p(0.05f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temp));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    jclass sink_class = env->GetObjectClass(sink);
    jmethodID on_bytes = env->GetMethodID(sink_class, "onBytes", "([B)V");
    auto emit = [&](const std::string & text) {
        jbyteArray arr = env->NewByteArray((jsize) text.size());
        env->SetByteArrayRegion(arr, 0, (jsize) text.size(), reinterpret_cast<const jbyte *>(text.data()));
        env->CallVoidMethod(sink, on_bytes, arr);
        env->DeleteLocalRef(arr);
    };

    std::string pending;
    int made = 0;
    bool full = false;
    std::string failure;
    while (made < max_tokens && !g_stop) {
        llama_token tok = llama_sampler_sample(smpl, g_ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        char buf[256];
        const int n = llama_token_to_piece(vocab, tok, buf, sizeof buf, 0, false);
        if (n > 0) pending.append(buf, n);
        const size_t whole = complete_utf8(pending);
        if (whole > 0) {
            emit(pending.substr(0, whole));
            pending.erase(0, whole);
        }
        made++;
        if ((int) g_cached.size() + 1 >= n_ctx) {
            full = true;
            break;
        }
        if (llama_decode(g_ctx, llama_batch_get_one(&tok, 1)) != 0) {
            failure = "The model stopped unexpectedly.";
            break;
        }
        g_cached.push_back(tok);
    }
    if (!pending.empty()) emit(pending);
    llama_sampler_free(smpl);
    env->DeleteLocalRef(sink_class);
    if (!failure.empty()) {
        llama_memory_clear(mem, true);
        g_cached.clear();
        return error(env, failure);
    }

    const auto end = std::chrono::steady_clock::now();
    const double read_s = std::chrono::duration<double>(read - start).count();
    const double gen_s = std::chrono::duration<double>(end - read).count();
    char stats[256];
    snprintf(stats, sizeof stats,
             "{\"prompt_tokens\":%d,\"read_tokens\":%d,\"read_seconds\":%.2f,"
             "\"tokens\":%d,\"tokens_per_second\":%.2f,\"stopped\":%s,\"full\":%s}",
             (int) tokens.size(), (int) (tokens.size() - keep), read_s, made,
             gen_s > 0 ? made / gen_s : 0.0, g_stop ? "true" : "false", full ? "true" : "false");
    return json_result(env, stats);
}
