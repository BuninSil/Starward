// Minimal Godot Android plugin (v2) used by the in-game updater.
// Versions follow Godot 4.7.2 (platform/android/java/app/config.gradle).
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library") version "8.6.1"
    id("org.jetbrains.kotlin.android") version "2.1.21"
}

val godotLibVersion = "4.7.2.stable"

android {
    namespace = "com.buninsil.starward.updater"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // Provided at runtime by the Godot app template / export plugin dependencies.
    compileOnly("org.godotengine:godot:$godotLibVersion")
    compileOnly("androidx.core:core:1.13.1")
}
