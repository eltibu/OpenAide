# llama.cpp's bridge (openaide_llm.cpp) finds these by name.
-keep class com.nexus.nexus_assistant.LocalLlm { native <methods>; }
-keep interface com.nexus.nexus_assistant.LocalLlm$Sink { *; }
-keep class * implements com.nexus.nexus_assistant.LocalLlm$Sink { *; }
