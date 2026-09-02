allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

// ✅ flutter_bluetooth_serial 에러 해결
gradle.projectsEvaluated {
    subprojects {
        val androidExtension = extensions.findByType(com.android.build.gradle.BaseExtension::class.java)
        if (androidExtension != null && androidExtension.namespace == null) {
            androidExtension.namespace = project.group.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}