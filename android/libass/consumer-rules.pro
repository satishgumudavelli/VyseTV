# JNI exports bind by name (Java_com_vyse_libass_*); keep the names stable.
-keepclasseswithmembernames class com.vyse.libass.* {
    native <methods>;
}
