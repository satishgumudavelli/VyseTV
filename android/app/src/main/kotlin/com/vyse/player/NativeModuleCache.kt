package com.vyse.player

/**
 * VyseTV stand-in. Upstream uses this to drop Sentry's cached native-library list
 * once libmpv is loaded, so crash reports symbolicate. VyseTV has no Sentry, so
 * there is nothing to invalidate.
 */
internal object NativeModuleCache {
  fun invalidate() {}
}
