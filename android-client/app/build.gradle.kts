import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jlleitschuh.gradle.ktlint")
    id("dev.detekt")
}
android {
    namespace = "dev.mirri.client"
    compileSdk = 35
    defaultConfig {
        applicationId = "dev.mirri.client"
        minSdk = 30
        targetSdk = 31
        versionCode = 3
        versionName = "0.2.0-network"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = true }
    lint {
        warningsAsErrors = true
        // Version-refresh advisories conflict with intentionally pinned SDK/Gradle/dependencies.
        // Sideloaded USB/network client stays on target 31 to retain established tablet immersive/landscape behavior.
        // The Play Store target-age advisory does not apply; all other Android lint issues remain fatal.
        disable += setOf("AndroidGradlePluginVersion", "GradleDependency", "NewerVersionAvailable", "ExpiredTargetSdkVersion")
    }
}
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}
detekt {
    config.setFrom(files("$rootDir/detekt.yml"))
    buildUponDefaultConfig = true
}
dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}
