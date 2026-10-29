# llama.cpp's bridge (openaide_llm.cpp) finds these by name.
-keep class com.nexus.nexus_assistant.LocalLlm { native <methods>; }
-keep interface com.nexus.nexus_assistant.LocalLlm$Sink { *; }
-keep class * implements com.nexus.nexus_assistant.LocalLlm$Sink { *; }

# Vosk (hands-free listening) reaches its library through JNA by name.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.vosk.** { *; }
-dontwarn java.awt.**
