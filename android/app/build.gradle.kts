import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.luis.movieapp.movie_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        @Suppress("DEPRECATION")
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.luis.movieapp.movie_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions("store")
    productFlavors {
        create("googleplay") {
            dimension = "store"
            resValue("string", "app_name", "K7 Movie")
            buildConfigField("boolean", "HAS_UNITY_ADS", "true")
        }
        create("amazon") {
            dimension = "store"
            resValue("string", "app_name", "K7 Movie")
            buildConfigField("boolean", "HAS_UNITY_ADS", "false")
        }
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")

    if (keystorePropertiesFile.exists()) {
        println("--- [SIGNING] Cargando key.properties desde: ${keystorePropertiesFile.absolutePath} ---")
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    } else {
        println("--- [SIGNING] ERROR: No se encontró key.properties en ${keystorePropertiesFile.absolutePath} ---")
    }

    signingConfigs {
        create("release") {
            val alias = keystoreProperties.getProperty("keyAlias")
            val pass = keystoreProperties.getProperty("keyPassword")
            val sFile = keystoreProperties.getProperty("storeFile")
            val sPass = keystoreProperties.getProperty("storePassword")

            if (alias != null && pass != null && sFile != null && sPass != null) {
                keyAlias = alias
                keyPassword = pass
                storeFile = file(sFile)
                storePassword = sPass
                println("--- [SIGNING] Configuración de firma cargada para alias: $alias ---")
            } else {
                println("--- [SIGNING] ADVERTENCIA: Datos de firma incompletos en key.properties ---")
            }
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
            isShrinkResources = false
        }
        getByName("release") {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
