allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 禁用不兼容的 Android 原生插件编译
allprojects {
    if (name in listOf(
            "desktop_drop",
            "flutter_background_service_android",
            "sqflite_android",
        )) {
        project.tasks.configureEach {
            if (name.contains("compile") || name.contains("Compile")) {
                enabled = false
            }
        }
    }
}

// 统一 JVM 目标，修复第三方 plugin 不一致
allprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

gradle.taskGraph.whenReady {
    allprojects {
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = "17"
            targetCompatibility = "17"
            options.release.set(17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
