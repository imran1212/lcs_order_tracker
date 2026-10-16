plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val aqasUploadStoreFile = providers.gradleProperty("AQAS_UPLOAD_STORE_FILE").orNull
    ?: System.getenv("AQAS_UPLOAD_STORE_FILE")
val aqasUploadStorePassword = providers.gradleProperty("AQAS_UPLOAD_STORE_PASSWORD").orNull
    ?: System.getenv("AQAS_UPLOAD_STORE_PASSWORD")
val aqasUploadKeyAlias = providers.gradleProperty("AQAS_UPLOAD_KEY_ALIAS").orNull
    ?: System.getenv("AQAS_UPLOAD_KEY_ALIAS")
val aqasUploadKeyPassword = providers.gradleProperty("AQAS_UPLOAD_KEY_PASSWORD").orNull
    ?: System.getenv("AQAS_UPLOAD_KEY_PASSWORD")
val hasAqasUploadSigning = listOf(
    aqasUploadStoreFile,
    aqasUploadStorePassword,
    aqasUploadKeyAlias,
    aqasUploadKeyPassword,
).all { !it.isNullOrBlank() }

if (gradle.startParameter.taskNames.any { it.contains("bundleRelease", ignoreCase = true) } &&
    !hasAqasUploadSigning
) {
    throw GradleException(
        "Google Play AAB builds require AQAS_UPLOAD_STORE_FILE, AQAS_UPLOAD_STORE_PASSWORD, " +
            "AQAS_UPLOAD_KEY_ALIAS, and AQAS_UPLOAD_KEY_PASSWORD. QA APKs may use debug signing."
    )
}

android {
    namespace = "pk.aqas.lcstracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "pk.aqas.lcstracker"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("aqasRelease") {
            if (hasAqasUploadSigning) {
                storeFile = file(aqasUploadStoreFile!!)
                storePassword = aqasUploadStorePassword
                keyAlias = aqasUploadKeyAlias
                keyPassword = aqasUploadKeyPassword
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Debug signing is permitted only for QA APK builds. bundleRelease
            // fails closed unless a private AQAS upload key is configured.
            signingConfig = if (hasAqasUploadSigning) {
                signingConfigs.getByName("aqasRelease")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}
